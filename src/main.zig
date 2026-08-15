const r4os = @import("r4os");

const MAX_TCP_PAYLOAD: usize = r4os.abi.net_service_tcp_read_max;
const DEFAULT_PORT: u16 = 8080;
const DEFAULT_PAYLOAD = "R4TCPECHO";

const Options = struct {
    target_text: []const u8,
    target_ip: [4]u8,
    port: u16,
    payload: []const u8,
    resolved: bool,
    used_gateway_default: bool,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.Network,
    net_low: r4os.r4net.Context,

    fn init(app: *r4os.App) ?App {
        return .{
            .sys = app.system(),
            .net = app.network() orelse return null,
            .net_low = app.networkLowLevel() orelse return null,
        };
    }

    fn write(self: *const App, value: []const u8) void {
        self.sys.write(value);
    }

    fn putc(self: *const App, ch: u8) void {
        self.sys.putc(ch);
    }

    fn printU64(self: *const App, value: u64) void {
        self.sys.printU64(value);
    }

    fn netConfigGet(self: *const App, out: *r4os.abi.NetConfigSnapshot) i32 {
        return self.net_low.netConfigGet(out);
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = App.init(app) orelse return r4os.abi.err_no_group;
    const args = trim(app.args());
    if (parseListenPort(args)) |port| {
        return listenOnce(&ctx, port);
    }

    const options = parseOptions(&ctx, args) orelse {
        usage(&ctx);
        return 1;
    };

    if (options.payload.len > MAX_TCP_PAYLOAD) {
        ctx.write("TCPECHO: payload too large\r\n");
        return 1;
    }

    if (options.used_gateway_default) {
        ctx.write("TCPECHO target: default gateway ");
        writeIpv4(&ctx, options.target_ip);
        ctx.write("\r\n");
    } else if (options.resolved) {
        ctx.write("TCPECHO resolved ");
        ctx.write(options.target_text);
        ctx.write(" to ");
        writeIpv4(&ctx, options.target_ip);
        ctx.write("\r\n");
    }

    ctx.write("TCPECHO connect ");
    writeIpv4(&ctx, options.target_ip);
    ctx.write(":");
    ctx.printU64(options.port);
    ctx.write(": ");

    const remote = r4os.SocketAddress{ .address = r4os.Ipv4Address.fromBytes(options.target_ip), .port = options.port };
    var socket = switch (ctx.net.connectTcp(remote, networkTimeout())) {
        .socket => |value| value,
        .would_block => {
            ctx.write("would block\r\n");
            return 1;
        },
        .timed_out => {
            ctx.write("timeout\r\n");
            return 1;
        },
        .reset => {
            ctx.write("reset\r\n");
            return 1;
        },
        .peer_closed => {
            ctx.write("peer closed\r\n");
            return 1;
        },
        .no_service => {
            ctx.write("TCPSVC unavailable\r\n");
            return 1;
        },
        .failure => {
            ctx.write("failed\r\n");
            return 1;
        },
    };
    ctx.write("ok\r\n");

    const written = switch (socket.write(options.payload, networkTimeout())) {
        .bytes => |value| value,
        else => 0,
    };
    if (written != options.payload.len) {
        ctx.write("TCPECHO write: failed\r\n");
        _ = socket.close(networkTimeout());
        return 1;
    }
    ctx.write("TCPECHO sent: ");
    ctx.printU64(@intCast(written));
    ctx.write("\r\n");

    var reply: [MAX_TCP_PAYLOAD]u8 = undefined;
    const got = switch (socket.read(reply[0..], networkTimeout())) {
        .bytes => |value| value,
        .would_block => {
            ctx.write("TCPECHO read: would block\r\n");
            return 1;
        },
        .timed_out => {
            ctx.write("TCPECHO read: timeout\r\n");
            return 1;
        },
        .reset => {
            ctx.write("TCPECHO read: reset\r\n");
            return 1;
        },
        .peer_closed => {
            ctx.write("TCPECHO read: peer closed\r\n");
            return 1;
        },
        else => {
            ctx.write("TCPECHO read: failed\r\n");
            return 1;
        },
    };
    _ = socket.close(networkTimeout());
    if (got == 0) {
        ctx.write("TCPECHO read: closed\r\n");
        return 1;
    }
    const reply_bytes = reply[0..got];
    ctx.write("TCPECHO received: ");
    ctx.printU64(@intCast(got));
    ctx.write("\r\n");
    ctx.write("TCPECHO reply: ");
    ctx.write(reply_bytes);
    ctx.write("\r\n");

    const ok = bytesEqual(reply_bytes, options.payload);
    ctx.write("TCPECHO result: ");
    ctx.write(if (ok) "ok" else "mismatch");
    ctx.write("\r\n");
    return if (ok) 0 else 1;
}

fn listenOnce(ctx: *const App, port: u16) i32 {
    var payload: [MAX_TCP_PAYLOAD]u8 = undefined;
    ctx.write("TCPECHO listen ");
    ctx.printU64(port);
    ctx.write(": waiting\r\n");

    var listener = switch (ctx.net.listenTcp(port, networkTimeout())) {
        .listener => |value| value,
        .timed_out => {
            ctx.write("TCPECHO listen: timeout\r\n");
            return 1;
        },
        .no_service => {
            ctx.write("TCPECHO listen: TCPSVC unavailable\r\n");
            return 1;
        },
        .failure => {
            ctx.write("TCPECHO listen: failed\r\n");
            return 1;
        },
    };
    var socket = switch (listener.accept(networkTimeout())) {
        .socket => |value| value,
        .would_block, .timed_out => {
            _ = listener.close(networkTimeout());
            ctx.write("timeout\r\n");
            return 1;
        },
        else => {
            _ = listener.close(networkTimeout());
            ctx.write("failed\r\n");
            return 1;
        },
    };
    const got = switch (socket.read(payload[0..], networkTimeout())) {
        .bytes => |value| value,
        else => 0,
    };
    ctx.write("TCPECHO listen ");
    ctx.printU64(port);
    ctx.write(": ");
    if (got != 0) {
        const bytes = payload[0..got];
        const written = switch (socket.write(bytes, networkTimeout())) {
            .bytes => |value| value,
            else => 0,
        };
        _ = socket.close(networkTimeout());
        _ = listener.close(networkTimeout());
        if (written != got) {
            ctx.write("failed\r\n");
            return 1;
        }
        ctx.write("ok bytes=");
        ctx.printU64(got);
        ctx.write(" payload=");
        ctx.write(bytes);
        ctx.write("\r\n");
        return 0;
    }
    _ = socket.close(networkTimeout());
    _ = listener.close(networkTimeout());
    ctx.write("closed\r\n");
    return 1;
}

fn parseListenPort(args: []const u8) ?u16 {
    var rest = trim(args);
    const first = takeToken(rest) orelse return null;
    if (!equalsIgnoreCase(first.token, "/LISTEN") and !equalsIgnoreCase(first.token, "-LISTEN") and !equalsIgnoreCase(first.token, "LISTEN")) return null;
    rest = first.rest;
    if (rest.len == 0) return DEFAULT_PORT;
    const port_token = takeToken(rest) orelse return DEFAULT_PORT;
    if (port_token.rest.len != 0) return null;
    return parsePort(port_token.token);
}

fn parseOptions(ctx: *const App, args: []const u8) ?Options {
    var rest = trim(args);
    var target_text: []const u8 = "gateway";
    var target_ip: [4]u8 = .{0} ** 4;
    var port: u16 = DEFAULT_PORT;
    var resolved = false;
    var used_gateway_default = false;

    if (takeToken(rest)) |first| {
        if (parseIpv4(first.token)) |ip| {
            target_text = first.token;
            target_ip = ip;
            rest = first.rest;
        } else if (parsePort(first.token)) |parsed_port| {
            used_gateway_default = true;
            target_ip = gatewayIp(ctx) orelse return null;
            port = parsed_port;
            rest = first.rest;
        } else {
            target_text = first.token;
            var resolver = ctx.net.resolver();
            const result = resolver.resolveA(first.token, null, networkTimeout());
            const resolved_address = switch (result) {
                .address => |value| value,
                else => {
                    ctx.write("TCPECHO resolve failed for ");
                    ctx.write(first.token);
                    ctx.write("\r\n");
                    return null;
                },
            };
            target_ip = resolved_address.octets;
            resolved = true;
            rest = first.rest;
        }
    } else {
        used_gateway_default = true;
        target_ip = gatewayIp(ctx) orelse return null;
    }

    if (!used_gateway_default) {
        if (takeToken(rest)) |second| {
            port = parsePort(second.token) orelse return null;
            rest = second.rest;
        }
    }

    return .{
        .target_text = target_text,
        .target_ip = target_ip,
        .port = port,
        .payload = if (rest.len == 0) DEFAULT_PAYLOAD else rest,
        .resolved = resolved,
        .used_gateway_default = used_gateway_default,
    };
}

fn gatewayIp(ctx: *const App) ?[4]u8 {
    var snapshot: r4os.abi.NetConfigSnapshot = .{};
    if (ctx.netConfigGet(&snapshot) != r4os.abi.net_config_ok) {
        ctx.write("TCPECHO: no network config\r\n");
        return null;
    }
    if (isZeroIp(snapshot.gateway_ip)) {
        ctx.write("TCPECHO: no default gateway\r\n");
        return null;
    }
    return snapshot.gateway_ip;
}

fn networkTimeout() r4os.time_contract.Timeout {
    return r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(10_000_000_000));
}

fn usage(ctx: *const App) void {
    ctx.write("Usage: TCPECHO [host] [port] [text]\r\n");
    ctx.write("       TCPECHO /LISTEN [port]\r\n");
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

fn takeToken(value: []const u8) ?Token {
    const trimmed = trim(value);
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and !isSpace(trimmed[end])) : (end += 1) {}
    return .{
        .token = trimmed[0..end],
        .rest = if (end >= trimmed.len) "" else trim(trimmed[end..]),
    };
}

fn parsePort(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    var out: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        out = out * 10 + @as(u32, ch - '0');
        if (out == 0 or out > 65535) return null;
    }
    return @intCast(out);
}

fn parseIpv4(value: []const u8) ?[4]u8 {
    var out: [4]u8 = .{0} ** 4;
    var part: usize = 0;
    var accum: u16 = 0;
    var digits: usize = 0;

    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const ch = value[index];
        if (ch >= '0' and ch <= '9') {
            accum = accum * 10 + @as(u16, ch - '0');
            if (accum > 255) return null;
            digits += 1;
            if (digits > 3) return null;
        } else if (ch == '.') {
            if (digits == 0 or part >= 3) return null;
            out[part] = @intCast(accum);
            part += 1;
            accum = 0;
            digits = 0;
        } else {
            return null;
        }
    }
    if (digits == 0 or part != 3) return null;
    out[part] = @intCast(accum);
    return out;
}

fn writeIpv4(ctx: *const App, ip: [4]u8) void {
    ctx.printU64(ip[0]);
    ctx.putc('.');
    ctx.printU64(ip[1]);
    ctx.putc('.');
    ctx.printU64(ip[2]);
    ctx.putc('.');
    ctx.printU64(ip[3]);
}

fn isZeroIp(ip: [4]u8) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (a[index] != b[index]) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}
