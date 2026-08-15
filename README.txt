TCPECHO.R4X
===========

TCPECHO.R4X ist ein Terminalwerkzeug fuer einfache TCP-Echo-Tests ueber
R4NET.

Projektstruktur seit 0.51.19:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports und Contract.

Build:

    cd Code\System\Software\TcpEcho
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\TcpEcho\zig-out\TCPECHO.R4X

Contract:
- R4XStart-Entry: `tcpecho_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4NET`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\TCPECHO.R4X`

