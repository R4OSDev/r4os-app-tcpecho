const std = @import("std");
const r4os = @import("r4os");

const MAX_TCP_PAYLOAD: usize = r4os.abi.net_service_tcp_read_max;
const DEFAULT_PORT: u16 = 8080;
const DEFAULT_PAYLOAD = "R4TCPECHO";

const Options = struct {
    target_text: []const u8,
    target: r4os.abi.NetworkEndpoint,
    port: u16,
    payload: []const u8,
    resolved: bool,
    used_gateway_default: bool,
};

const App = struct {
    app: *r4os.App2,
    sys: r4os.r4sys.Context,
    output: *r4os.launch_io.Output,
    network: *r4os.network_stream.Session,
    budget: *r4os.rpc_budget.Budget,
    args: []const u8,
    family: u32,

    fn write(self: *const App, value: []const u8) void {
        self.output.write(value);
    }
    fn printU64(self: *const App, value: u64) void {
        self.output.number(value);
    }
};

pub fn r4_app_main(app: *r4os.App2) i32 {
    var output: r4os.launch_io.Output = undefined;
    if (r4os.launch_io.Output.init(app, &output) != 0) return 1;
    var selected_family: u32 = 0;
    const args = r4os.network_stream.arguments(app.args(), &selected_family) orelse {
        output.write("TCPECHO: invalid argument grammar\r\n");
        _ = output.close();
        return 1;
    };
    var budget = r4os.rpc_budget.Budget.fromTimeout(output.clock.read, .{ .kind = 1, .nanoseconds = 10_000_000_000 }) catch {
        _ = output.close();
        return 1;
    };
    var network: r4os.network_stream.Session = undefined;
    const opened = r4os.network_stream.Session.open(app, &budget, &network);
    if (opened != 0) {
        output.write("TCPECHO: TCPSVC unavailable or invalid\r\n");
        _ = output.close();
        return 1;
    }
    const ctx: App = .{ .app = app, .sys = app.system(), .output = &output, .network = &network, .budget = &budget, .args = args, .family = selected_family };
    const result = run(&ctx);
    const closed = network.close();
    if (closed != 0) output.write("TCPECHO close: not confirmed\r\n");
    const io_closed = output.close();
    return if (output.failed or closed != 0 or io_closed != 0) 1 else result;
}

fn run(ctx: *const App) i32 {
    const args = trim(ctx.args);
    if (parseListenPort(args)) |port| {
        return listenOnce(ctx, port);
    }

    const options = parseOptions(ctx, args) orelse {
        usage(ctx);
        return 1;
    };

    if (options.payload.len > MAX_TCP_PAYLOAD) {
        ctx.write("TCPECHO: payload too large\r\n");
        return 1;
    }

    if (options.used_gateway_default) {
        ctx.write("TCPECHO target: default gateway ");
        writeAddress(ctx, options.target.address);
        ctx.write("\r\n");
    } else if (options.resolved) {
        ctx.write("TCPECHO resolved ");
        ctx.write(options.target_text);
        ctx.write(" to ");
        writeAddress(ctx, options.target.address);
        ctx.write("\r\n");
    }

    ctx.write("TCPECHO connect ");
    writeAddress(ctx, options.target.address);
    ctx.write(":");
    ctx.printU64(options.port);
    ctx.write(": ");

    var socket: r4os.network_stream.Socket = undefined;
    if (ctx.network.create(options.target, false, ctx.budget, &socket) != 0) {
        ctx.write("failed\r\n");
        return 1;
    }
    ctx.write("ok\r\n");
    defer socket.close();
    const sent = socket.writeAll(options.payload, ctx.budget) catch return 1;
    if (!r4os.network_stream.complete(sent)) {
        ctx.write("TCPECHO write: incomplete prefix=");
        ctx.printU64(sent.bytes);
        ctx.write("\r\n");
        return 1;
    }
    ctx.write("TCPECHO sent: ");
    ctx.printU64(options.payload.len);
    ctx.write("\r\n");

    var reply: [MAX_TCP_PAYLOAD]u8 = undefined;
    const got = options.payload.len;
    var reader: r4os.network_stream.Reader = .{ .socket = &socket };
    const received = reader.read(reply[0..got], true, ctx.budget) catch return 1;
    if (!r4os.network_stream.complete(received)) {
        ctx.write("TCPECHO read: ");
        ctx.write(@tagName(@as(r4os.stream_transfer.Outcome, @enumFromInt(received.outcome))));
        ctx.write(" prefix=");
        ctx.printU64(received.bytes);
        ctx.write("\r\n");
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
    ctx.write("TCPECHO listen ");
    ctx.printU64(port);
    ctx.write(": waiting\r\n");
    const endpoint: r4os.abi.NetworkEndpoint = .{ .address = .{ .family = if (ctx.family == 6) 6 else 4 }, .port = port };
    var listener: r4os.network_stream.Socket = undefined;
    if (ctx.network.create(endpoint, true, ctx.budget, &listener) != 0) {
        ctx.write("TCPECHO listen: failed\r\n");
        return 1;
    }
    defer listener.close();
    var socket: r4os.network_stream.Socket = undefined;
    if (listener.accept(ctx.budget, &socket) != 0) {
        ctx.write("TCPECHO listen: accept failed\r\n");
        return 1;
    }
    defer socket.close();
    var payload: [MAX_TCP_PAYLOAD]u8 = undefined;
    var reader: r4os.network_stream.Reader = .{ .socket = &socket };
    const got = reader.read(&payload, false, ctx.budget) catch return 1;
    if (got.bytes == 0 or got.flags & r4os.stream_transfer.core.terminal != 0 and got.outcome != @intFromEnum(r4os.stream_transfer.Outcome.eof) and !r4os.network_stream.complete(got)) {
        ctx.write("TCPECHO listen: closed or failed\r\n");
        return 1;
    }
    const bytes = payload[0..@intCast(got.bytes)];
    const sent = socket.writeAll(bytes, ctx.budget) catch return 1;
    if (!r4os.network_stream.complete(sent)) {
        ctx.write("TCPECHO listen: write failed\r\n");
        return 1;
    }
    ctx.write("TCPECHO listen ");
    ctx.printU64(port);
    ctx.write(": ok bytes=");
    ctx.printU64(got.bytes);
    ctx.write(" payload=");
    ctx.write(bytes);
    ctx.write("\r\n");
    return 0;
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
    var target: r4os.abi.NetworkEndpoint = .{};
    var port: u16 = DEFAULT_PORT;
    var resolved = false;
    var used_gateway_default = false;
    if (takeToken(rest)) |first| {
        if (parsePort(first.token)) |parsed_port| {
            used_gateway_default = true;
            target = r4os.network_family.common.v4Endpoint(gatewayIp(ctx) orelse return null, parsed_port);
            port = parsed_port;
            rest = first.rest;
        } else {
            target_text = first.token;
            rest = first.rest;
            if (takeToken(rest)) |second| {
                port = parsePort(second.token) orelse return null;
                rest = second.rest;
            }
            if (ctx.network.resolve(target_text, port, ctx.family, ctx.budget, &target) != 0) {
                ctx.write("TCPECHO resolve failed for ");
                ctx.write(target_text);
                ctx.write("\r\n");
                return null;
            }
            const numeric = if (target_text.len >= 2 and target_text[0] == '[') target_text[1 .. target_text.len - 1] else target_text;
            resolved = r4os.network_family.parseAddress(numeric) == null;
        }
    } else {
        used_gateway_default = true;
        target = r4os.network_family.common.v4Endpoint(gatewayIp(ctx) orelse return null, port);
    }
    if (used_gateway_default and ctx.family == 6) return null;
    return .{ .target_text = target_text, .target = target, .port = port, .payload = if (rest.len == 0) DEFAULT_PAYLOAD else rest, .resolved = resolved, .used_gateway_default = used_gateway_default };
}

fn gatewayIp(ctx: *const App) ?[4]u8 {
    var snapshot: r4os.abi.NetConfigSnapshot = .{};
    const net = ctx.app.networkLowLevel() orelse return null;
    if (net.netConfigGet(&snapshot) != r4os.abi.net_config_ok) {
        ctx.write("TCPECHO: no network config\r\n");
        return null;
    }
    if (isZeroIp(snapshot.gateway_ip)) {
        ctx.write("TCPECHO: no default gateway\r\n");
        return null;
    }
    return snapshot.gateway_ip;
}

fn usage(ctx: *const App) void {
    ctx.write("Usage: TCPECHO [-4|-6] [host] [port] [text]\r\n");
    ctx.write("       TCPECHO [-4|-6] /LISTEN [port]\r\n");
}

const Token = struct { token: []const u8, rest: []const u8 };
fn takeToken(value: []const u8) ?Token {
    var failure: r4os.arguments.Failure = .{};
    var cursor = r4os.arguments.ArgCursor.init(value, .{}, &failure) catch return null;
    const token = (cursor.next() catch return null) orelse return null;
    return .{ .token = token.bytes(value) catch return null, .rest = cursor.remainingArguments() catch return null };
}

fn parsePort(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    for (value) |byte| if (byte < '0' or byte > '9') return null;
    const number = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (number == 0) null else number;
}

fn writeAddress(ctx: *const App, address: r4os.abi.NetworkAddress) void {
    var buffer: [80]u8 = undefined;
    ctx.write(r4os.network_family.addressText(&buffer, address) catch "unknown");
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
