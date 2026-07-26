# mdeye.nvim

Read Markdown as a document, inside Neovim.

mdeye.nvim opens a Markdown buffer as a separate, read-only document view — not decorated
source, not a browser. It parses the document with Tree-sitter, reflows paragraphs
semantically, centers a maximum-width reading column, removes source markers, and applies
theme-friendly highlights, in the spirit of Zed's native Markdown preview.

- Paragraphs reflow to the window width; source hard wraps disappear.
- A centered reading column with symmetric margins (`min(max_width, width - 2 * min_margin)`).
- Headings without `#` markers, with dividers and deliberate vertical rhythm.
- Emphasis, strong, strikethrough, inline code, links (destinations hidden), lists,
  task lists, block quotes, fenced code, thematic breaks, and GitHub-style tables.
- Live, debounced updates from unsaved source edits; reflow on window resize that keeps
  your reading position.
- Jump back to the exact source block with `<CR>`; open links with `gx` or `<CR>`.
- The source buffer is never modified. The preview cleans up completely on close.

## Requirements

- Neovim **0.11+**
- The bundled `markdown` and `markdown_inline` Tree-sitter parsers (included with Neovim)

No other runtime dependencies. Run `:checkhealth mdeye` to verify.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "franklin/mdeye.nvim",
  ft = "markdown",
  opts = {},
}
```

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ "https://github.com/franklin/mdeye.nvim" })
require("mdeye").setup()
```

## Usage

| Command | Behavior |
| --- | --- |
| `:MDEye` | Toggle a preview in the current window. |
| `:MDEye current` | Open or focus the preview in the current window. |
| `:MDEye split` | Open or focus a synchronized preview in a right split. |
| `:MDEye tab` | Open or focus the preview in a new tab page. |
| `:MDEye close` | Close the preview and restore the source view. |

Inside the preview:

| Key | Behavior |
| --- | --- |
| `q` | Close the preview and restore the source view. |
| `<CR>` | Open the link under the cursor, or jump to the block's source location. |
| `gx` | Open the link under the cursor. |

In split mode, moving the source cursor scrolls the preview to the corresponding block.
Preview cursor movement never moves the source cursor; `<CR>` performs that jump
explicitly.

mdeye installs no global keymaps. A suggested mapping:

```lua
vim.keymap.set("n", "<leader>me", "<Cmd>MDEye<CR>", { desc = "Markdown eye" })
```

The equivalent Lua interface:

```lua
require("mdeye").open({ mode = "current" | "split" | "tab" })
require("mdeye").close()
require("mdeye").toggle({ mode = "current" })
```

## Configuration

Defaults shown; calling `setup()` is optional unless you change them.

```lua
require("mdeye").setup({
  open = "current",   -- default placement: "current" | "split" | "tab"
  max_width = 88,     -- maximum reading-column width in display cells
  min_margin = 3,     -- minimum margin on each side
  debounce_ms = 120,  -- live-update debounce
  code = {
    wrap = false,     -- fenced code is clipped, never reflowed, by default
  },
})
```

Renderer internals are deliberately not configurable. Highlight groups are the
customization seam.

## Highlights

Every group uses `default link` semantics, so your colorscheme and explicit
`:highlight` commands always win. No colors are hard-coded.

`MDEyeText`, `MDEyeMuted`, `MDEyeHeading1`–`MDEyeHeading6`, `MDEyeHeadingRule`,
`MDEyeEmphasis`, `MDEyeStrong`, `MDEyeStrike`, `MDEyeCode`, `MDEyeCodeBlock`,
`MDEyeLink`, `MDEyeQuote`, `MDEyeListMarker`, `MDEyeTableBorder`,
`MDEyeTaskChecked`, `MDEyeTaskUnchecked`

Example override:

```lua
vim.api.nvim_set_hl(0, "MDEyeHeading1", { fg = "#c6a0f6", bold = true })
```

## Behavior notes

- The preview buffer is `mdeye://<path>` with `filetype=mdeye`, `buftype=nofile`, and
  `bufhidden=wipe`. Markdown linters, LSP servers, diagnostics, and formatting autocmds
  never attach to it.
- Unsaved source edits are rendered from the live buffer; the file on disk is never
  reread.
- Relative links resolve against the source file's directory, not Neovim's working
  directory. Absolute `http(s)`/`mailto` links also carry OSC 8 extmark `url` metadata
  where the terminal supports it.
- Over-wide tables shrink their widest columns and wrap cell contents rather than
  breaking the layout. Over-wide code lines are clipped (see `code.wrap`).
- Unsupported raw HTML renders as readable plain text; nothing is executed.

## Terminal-grid limitations

Neovim draws on a character-cell grid, so mdeye reproduces Zed's document *structure and
layout*, not its typography. Not possible in a terminal:

- proportional fonts or per-heading font sizes;
- pixel-level line height, kerning, or margins;
- browser-quality table layout;
- inline raster images (a future optional adapter may add these);
- guaranteed bold/italic faces — that depends on your terminal and font.

## Performance

Measured with `nvim --headless -l tests/bench/bench.lua` on an Apple Silicon
development machine (Neovim 0.12.2), full parse + layout + render of a representative
document, median of 5 runs:

| Fixture | Preview lines | Parse | Layout | Render | Total |
| --- | --- | --- | --- | --- | --- |
| 1,010 lines | 1,156 | 16 ms | 22 ms | 1.4 ms | **41 ms** |
| 9,998 lines | 11,428 | 170 ms | 112 ms | 15 ms | **319 ms** |

The 1,000-line initial render is well under the 100 ms target, so mdeye performs
complete full-document rerenders on every debounced update — no incremental-rendering
complexity.

## Development

```sh
# Run all tests (headless, no plugin manager needed)
nvim --headless -l tests/run.lua

# Run one spec
nvim --headless -l tests/run.lua tests/session_spec.lua

# Formatting
stylua --check lua plugin tests

# Benchmark
nvim --headless -l tests/bench/bench.lua

# Render the comprehensive fixture to stdout at a given width
nvim --headless -l tests/spike/render_demo.lua 100
```

Design documentation lives in [docs/implementation-plan.md](docs/implementation-plan.md);
the Tree-sitter research evidence is in [docs/milestone-0-evidence.md](docs/milestone-0-evidence.md).
