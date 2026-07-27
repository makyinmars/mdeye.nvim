# Changelog

All notable changes to mdeye.nvim will be documented in this file.

## Unreleased

### Added

- Tree-sitter syntax highlighting for fenced code, with language aliases and a plain-text
  fallback when a parser or highlight query is unavailable.
- `:MDEye copy-code` and preview-local `yc` for copying original fenced content, plus
  optional display-cell wrapping through `code.wrap`.
- GitHub-style heading anchors, next/previous heading mappings, and a `gO` heading outline.
- Numbered GFM-style footnotes with in-preview navigation and semantic continuation blocks.
- Fenced-code parser reporting in `:checkhealth mdeye` for loaded Markdown documents.
- A terminal/image compatibility matrix and a structured bug-report issue template.
- GitHub-style `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION` alerts with semantic,
  theme-friendly titles and gutters.
- Active preview session diagnostics in `:checkhealth mdeye`.

## 0.1.0 — 2026-07-26

Initial public release.

### What it does

mdeye.nvim turns a Markdown buffer into a separate, read-only document view inside
Neovim. It uses Tree-sitter to reflow prose into a centered reading column and render
headings, emphasis, links, lists, task lists, quotes, code blocks, thematic breaks, and
GitHub-style tables without showing their source markers.

The preview updates from unsaved edits, reflows when its window is resized, preserves
the reader's position, and lets the reader follow links or jump back to the matching
source block. It never modifies the source buffer and has no runtime dependencies
beyond Neovim 0.11 or later and its bundled Markdown Tree-sitter parsers.

### Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "makyinmars/mdeye.nvim",
  ft = "markdown",
  opts = {},
}
```

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ "https://github.com/makyinmars/mdeye.nvim" })
require("mdeye").setup()
```

Open a Markdown file and run `:MDEye`. See the
[README](https://github.com/makyinmars/mdeye.nvim#readme) for commands,
configuration, highlights, and suggested keymaps.

### Included in this release

- Current-window, split, and tab preview modes.
- Live debounced rendering from the source buffer.
- Synchronized source-to-preview scrolling in split mode.
- Theme-friendly highlight groups with no hard-coded colors.
- `:checkhealth mdeye` diagnostics.
- Headless tests across Neovim 0.11, stable, and nightly in CI.
