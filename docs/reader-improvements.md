# Reader improvements: implementation and verification

All six planned areas are implemented. The core text renderer still needs only
Neovim and its bundled Markdown parsers. Optional images require a separately
configured image.nvim backend and processor.

## Changes

| Area | Result | Main implementation |
| --- | --- | --- |
| Reading position | Tracks source edits and the passage inside a block; diagrams retain node/event identity where possible | `lua/mdeye/view.lua` |
| Folding | Native manual section/code folds, initially open; nested choices survive edits and resize | `lua/mdeye/view.lua`, `session.lua` |
| Mermaid | Shared-node routed graphs, nested subgraph containers, and sequence lifelines/messages | `graph.lua`, `sequence.lua`, `mermaid.lua` |
| Images | Local standalone image paragraphs, bounded real-row reservations, handle caching, alt-text fallback, visibility and cleanup | `images.lua`, `layout.lua` |
| Editing performance | Retains unchanged buffer ranges and extmark IDs; highlight-only updates do not change text | `render.lua` |
| Visual regression | Reviewed expected terminal layouts at 30 and 80 columns, checked by the normal suite | `tests/visual_spec.lua` |

The public Lua API remains in init.lua. Tree-sitter access remains in document.lua.
The new view module owns window state; the image module owns backend effects. Layout
receives a semantic document and measured image reservations, without reading files
or accessing the image backend.

## Terminal captures

The reviewed captures are checked into the repository:

- [30-column preview](../tests/fixtures/snapshots/visual-30.txt)
- [80-column preview](../tests/fixtures/snapshots/visual-80.txt)
- [Markdown fixture](../tests/fixtures/visual.md)

The snapshots cover prose, nested lists, tables, quotes, Unicode, code, Mermaid
branches/cycles, subgraphs, and sequences. Before captures for the earlier Mermaid
connection renderer are retained in [mermaid-evidence.md](mermaid-evidence.md).

Regenerate expected layouts only when intentionally accepting a visual change:

```sh
nvim --headless -l tests/spike/update_snapshots.lua
```

Tests compare the stored output; they never overwrite expected snapshots. Existing
semantic tests independently check source mappings, byte columns, Unicode widths,
copying, and navigation, so a plausible-looking snapshot cannot replace those checks.

## Verification

On Neovim 0.12.5:

- 106 tests passed, including real-window fold/reading-position regressions.
- StyLua and Luacheck checks passed.
- Incremental and full renders produce identical text/extmarks after insertion,
  deletion, Unicode edits, blank-line edits, and URL/highlight changes. Unchanged
  extmark IDs survive edits, including shifted suffixes.
- Reading tests cover resize, insertion above the current block, and replacement of
  the source line containing a long paragraph. Source-tracking marks are removed on close.
- Fold tests cover closed children inside closed parents, earlier source edits,
  resize, native fold-range invalidation, and restoration of source folding options.
- Image tests cover local/remote/missing files, size limits, caching, reservations,
  folded visibility, removal, disabled backends, and synchronous decode/render errors.

A separate smoke test used the locally installed image.nvim with its real
`magick_cli` processor and Kitty backend in an isolated Neovim terminal session.
An 80×40 PNG decoded and rendered into a 30×8-cell reservation at column 3, row 5;
the backend reported `is_rendered = true` and zero remaining image handles after
preview close. The test emitted the graphics protocol and checked backend state;
it did not verify how pixels look in every terminal emulator.

That smoke test caught two integration details: blank rows need real padding for
correct horizontal screen coordinates, and the backend's below-anchor placement
needs a vertical offset when occupying preallocated buffer rows. Both are handled
by the adapter. Text captions remain visible independently of image rendering.

## Performance

The existing 1,010-line benchmark measured 60.19 ms median parse + layout + render,
below its 100 ms target. Five measured iterations followed the benchmark's existing
procedure.

The new editing fixture contains 10,000 source lines and 15,000 preview lines. After
one warmup, five one-paragraph edits measured:

| Stage | Median |
| --- | ---: |
| Parse | 211.02 ms |
| Layout | 65.24 ms |
| Complete buffer application | 27.26 ms |
| Incremental buffer application | 7.26 ms |
| Parse + layout + incremental application | 283.51 ms |

The final edit replaced one preview line and created two marks. These measurements
are local pipeline timings, not latency guarantees, and exclude session fold/anchor
work. Unchanged fold ranges are reused when native fold levels remain valid.

```sh
nvim --headless -l tests/bench/bench.lua
nvim --headless -l tests/bench/updates.lua
```

## Boundaries

- Graphs use deterministic declaration ordering and orthogonal lanes, not Mermaid's
  browser layout algorithm. Shared routing falls back to connected pairs for narrow
  ungrouped graphs. Groups that cannot fit retain complete source.
- Native diagram support remains a documented syntax subset. Unsupported constructs
  do not get partially rendered. Sequences have a separate semantic model and limits.
- Images within prose and remote URLs remain alt text. Raster display is optional;
  terminal/backend support still matters. The adapter reserves bounding rows using a
  conventional cell-aspect estimate, and the backend fits the image within them.
- Parsing and layout still process the whole document. Incremental buffer application
  reduces Neovim writes; it is not an incremental Markdown parser.
- Reading anchors use source positions and nearby normalized text. If a passage is
  deleted or rewritten beyond recognition, restoration chooses a nearby block position.

API references checked during implementation:
[Neovim buffer/extmark API](https://neovim.io/doc/user/api/),
[Mermaid flowcharts](https://mermaid.js.org/syntax/flowchart.html),
[Mermaid sequences](https://mermaid.js.org/syntax/sequenceDiagram.html), and
[image.nvim API](https://github.com/3rd/image.nvim#api).
