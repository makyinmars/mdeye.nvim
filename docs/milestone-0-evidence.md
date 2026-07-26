# Milestone 0 evidence

Status: complete
Date: 2026-07-26
Environment: Neovim 0.12.2 (development machine), bundled `markdown` and
`markdown_inline` Tree-sitter parsers.

The parser and layout spike validated every Milestone 0 assumption against real
Tree-sitter output before lifecycle code was written. Artifacts:

- `tests/fixtures/comprehensive.md` — one fixture covering every required construct.
- `tests/spike/dump_tree.lua` — dumps block and injected inline trees with absolute
  ranges. Regenerate with:

  ```sh
  nvim --headless -l tests/spike/dump_tree.lua > tests/spike/tree-dump.txt 2>&1
  ```

- `tests/spike/tree-dump.txt` — the captured node trees (1,850 lines).
- `tests/spike/render_demo.lua` — renders the fixture to stdout at a given width for
  manual visual inspection.

## Verified assumptions

1. **Hidden-buffer injected parsing.** Loading the fixture into a hidden buffer and
   calling `parser:parse(true)` produces the injected `markdown_inline` trees. Lazy
   `parse()` without `true` does not; the plan's requirement to force full injection
   parsing is correct and necessary.

2. **Absolute included ranges.** `child_tree:included_ranges()` returns absolute
   buffer row/byte coordinates. No offset rebasing is needed, confirming the plan's
   "consume included ranges, never reparse extracted strings" strategy.

3. **Nested quote/list marker exclusion.** For emphasis spanning a source line break
   inside a nested block quote, the injected inline tree's included ranges *exclude*
   the `>` continuation markers: the markers appear as gaps between ranges. The same
   holds for list continuation indents. Extraction therefore intersects inline node
   byte spans with the injection ranges, which yields marker-free text while keeping
   absolute source anchors. This is implemented in `document.lua`.

4. **Table-cell injection.** Neovim's bundled runtime injection query injects
   `markdown_inline` into `pipe_table_cell`, so table cells receive full inline
   styling. Because a third-party query installation could shadow the bundled one,
   `:checkhealth mdeye` performs a functional check (parses a sample table and counts
   injected regions) rather than trusting query file contents.

5. **Display cells vs. byte columns.** CJK (2 cells per glyph), emoji, precomposed
   accents, and combining-character sequences all produce display widths that differ
   from byte lengths. `layout.lua` tracks display cells (via `vim.fn.strdisplaywidth()`)
   and byte offsets as separate values end to end; extmark columns are byte-indexed
   into the generated lines.

## Plan correction

**Nested same-kind strikethrough nodes.** `~~strike~~` parses as a `strikethrough`
node *containing another* `strikethrough` node (an artifact of how
`tree-sitter-markdown-inline` matches the double tildes). A naive per-node style
mapping would double-register the strike run. `document.lua` normalizes by flattening
directly-nested same-kind inline nodes into one run.

This is the only deviation discovered by the spike. No architecture change was
required; the module seams from the implementation plan stand as designed.

## Performance record (Milestone 4)

Measured with `nvim --headless -l tests/bench/bench.lua` (median of 5 full
parse + layout + render runs, usable width 100, Apple Silicon, Neovim 0.12.2):

| Fixture | Preview lines | Parse | Layout | Render | Total |
| --- | --- | --- | --- | --- | --- |
| 1,010 lines | 1,156 | 16 ms | 22 ms | 1.4 ms | **41 ms** |
| 9,998 lines | 11,428 | 170 ms | 112 ms | 15 ms | **319 ms** |

The 1,000-line initial render is well under the 100 ms target, so the renderer keeps
the plan's preferred design: complete full-document rerenders per debounced update,
with no incremental-rendering complexity.
