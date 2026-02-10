# zig-xtc-reader

Small Zig + WASI app built with the Paper Portal Zig SDK. The app scans `/sdcard/books` for `.xtc` / `.xtch` files and shows them in a simple UI.

## Build

- `zig build`

## Unit tests

This repo includes unit tests that can be run with comand `zig build test`. The
unit tests are run on the host computer.

## Host CLI tool (`xtci`)

This repo also includes a small host (native) command line tool target named `xtci`.

- Build/install: `zig build xtci`
- Run via build system: `zig build run-xtci`
- Run directly after install: `./zig-out/bin/xtci`

## Naming conventions (Zig)

Use `lowerCamelCase` for all functions, except functions that return a type (Zig), which use `PascalCase`.
