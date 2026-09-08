# TCPECHO.R4X

`TCPECHO.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.2`
- Image target: `/R4OS/SOFTWARE/TERMINAL/TCPECHO.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


The client accumulates positive partial writes and reads until the complete
expected echo is received. Connect, writes and reads share one ten-second
deadline. A zero-progress or terminal result fails; would-block retries stay
inside that deadline. The listener also completes a partially accepted write
of its first received chunk. Socket cleanup runs on every client exit; an
unconfirmed close is reported instead of being described as successful.
