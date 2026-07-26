# Repository Guidelines

## Project Structure & Module Organization

`lua/mdeye/` contains the plugin implementation. Keep the public API in `init.lua`; configuration,
parsing, layout, rendering, session lifecycle, and health checks live in their correspondingly named
modules. `plugin/mdeye.lua` registers user-facing commands. Vim help belongs in `doc/mdeye.txt`, while
design notes and implementation evidence live in `docs/`.

Tests are dependency-free Lua specs under `tests/`. Shared setup and the runner are
`tests/minimal_init.lua` and `tests/run.lua`; Markdown samples belong in `tests/fixtures/`. Keep
exploratory scripts in `tests/spike/` and performance checks in `tests/bench/`.

## Build, Test, and Development Commands

- `nvim --headless -l tests/run.lua` runs every `*_spec.lua` file.
- `nvim --headless -l tests/run.lua tests/layout_spec.lua` runs one spec.
- `stylua --check lua plugin tests` verifies formatting without changing files.
- `luacheck lua plugin tests` runs the configured Lua 5.1/LuaJIT lint checks.
- `nvim --headless -l tests/bench/bench.lua` measures parse, layout, render, and total time.
- `nvim --headless -l tests/spike/render_demo.lua 100` prints the comprehensive fixture at a
  100-cell window width.

There is no build step or runtime dependency installation. Development requires Neovim 0.11+ with
its bundled Markdown Tree-sitter parsers.

## Coding Style & Naming Conventions

Follow `.stylua.toml`: two-space indentation, Unix line endings, a 100-column target, and preferably
double-quoted strings. Use `snake_case` for modules, locals, and functions; use `M` for a module's
export table. Keep public interfaces small and document types and parameters with LuaLS annotations.
Only `document.lua` should access Tree-sitter directly; preserve the parse → layout → render boundary.

## Testing Guidelines

Add focused `describe`/`it` cases with `eq` and `ok` assertions. Name test files
`<module>_spec.lua`, and add reusable Markdown inputs to `tests/fixtures/`. Cover regressions at the
lowest relevant layer, then add session tests when Neovim buffer or window behavior is involved.
CI runs formatting, linting, and tests on Neovim 0.11, stable, and nightly.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative, sentence-case subjects such as `Add initial changelog...`,
with bodies explaining notable behavior and verification. Keep commits focused. Pull requests should
describe user-visible impact, list tests run, link related issues, and include before/after terminal
captures when rendering or layout changes. Update `README.md`, `doc/mdeye.txt`, and `CHANGELOG.md`
when public behavior changes.
