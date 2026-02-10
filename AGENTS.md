# Repository Guidelines

## Project Structure & Module Organization

- `src/`: Zig sources
  - `src/main.zig`: Paper Portal WASI entrypoints (`pp_*`)
  - `src/ui/`: UI views and layout helpers
  - `src/assets/`: bundled assets (fonts, images, etc.)
  - `src/main_xtci.zig`: host (native) CLI tool (`xtci`) for inspecting `.xtc` / `.xtch`
  - `src/main_test.zig`: unit test entrypoint (imports modules under test)
- `doc/`: format notes and references (see `doc/xtc-format.txt`)
- Build outputs: `.zig-cache/` and `zig-out/` (gitignored)

## Build, Test, and Development Commands

- `zig build`: build/install the WASI app into `zig-out/`
- `zig build upload`: upload the generated wasm to the Paper Portal dev server
- `zig build package`: build a Paper Portal `.papp` package
- `zig build test`: run host unit tests
- `zig build xtci`: build/install the `xtci` CLI into `zig-out/bin/xtci`
- `zig build run-xtci -- <args>`: run `xtci` via the build system

## Coding Style & Naming Conventions

- Format before pushing: `zig fmt build.zig src`
- Follow Zig naming conventions:
  - `snake_case` for files and variables
  - `lowerCamelCase` for functions, except functions that return a type (Zig) which use `PascalCase`
  - `PascalCase` for types
  - `SCREAMING_SNAKE_CASE` for constants
- Keep parsing paths conservative with memory; prefer explicit buffers/allocators (not hidden global state).

## Testing Guidelines

- Tests use Zig’s builtin `test {}` blocks and are executed via `zig build test`.
- Add new tests next to the module they cover and ensure they run on the host (no Paper Portal runtime required).
- Keep fixtures small and deterministic (avoid file-system dependencies unless necessary).

## Commit & Pull Request Guidelines

- Commit subjects in this repo are short and descriptive (e.g. “Added unit tests”, “Update book loading flow”).
- PRs should include:
  - what changed and why
  - how to test (at minimum `zig build test`)
  - for UI/behavior changes, brief notes or a screenshot/photo when practical

## SDK & Configuration Tips

- `build.zig` prefers a local Paper Portal Zig SDK checkout at `../zig-sdk`; otherwise it uses the pinned `paper_portal_sdk` dependency in `build.zig.zon`.
