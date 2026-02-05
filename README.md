# zig-xtc-reader

Small Zig + WASI app built with the Paper Portal Zig SDK. The app scans `/sdcard/books` for `.xtc` / `.xtch` files and shows them in a simple UI.

## Build

- `zig build`

## Unit tests

This repo includes unit tests that can be run with comand `zig build test`. The
unit tests are run on the host computer.
