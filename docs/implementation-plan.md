# mdeye.nvim implementation plan

<!-- markdownlint-disable MD013 -->

Status: proposed  
Date: 2026-07-26

## Outcome

Build a Neovim plugin that opens Markdown as a separate, read-only document view with the layout and
reading experience of Zed's native Markdown preview: centered content, semantic paragraph reflow,
clear typographic hierarchy, deliberate vertical spacing, live source updates, and navigation back to
the source—all without opening a browser or OS webview.

The project name is **mdeye.nvim**: “Markdown eye,” referring to the preview-eye affordance. An exact
GitHub repository-name search found no existing `mdeye.nvim` repository when this plan was created.

## Why a new plugin is justified

`render-markdown.nvim` decorates source-shaped lines. Its preview copies those same lines to a scratch
buffer and applies conceal, highlights, and virtual text. The first reference screenshot exposes the
consequences:

- hard source line breaks remain part of the visual layout;
- partially concealed Markdown punctuation remains visible;
- diagnostics interrupt the prose;
- headings and paragraphs retain editor-oriented spacing;
- the content fills the window instead of forming a centered reading column;
- the preview remains coupled to source line geometry.

Zed instead parses the Markdown into a document model and lays out a separate native document. The
second reference screenshot shows the target qualities:

- a centered reading column with a maximum width;
- paragraphs reflowed independently of source line breaks;
- generous margins and stable vertical rhythm;
- headings rendered without Markdown markers and followed by separators;
- distinct emphasis, code, and link styles;
- no source diagnostics, signs, line numbers, or editing artifacts;
- a separate item named as a preview rather than an altered source buffer.

Achieving these qualities requires generated preview text and a source-to-preview map. Adding more
extmarks to a copied source buffer cannot provide semantic reflow, so mdeye.nvim should own the
document view rather than wrap another preview command.

## Definition of Zed-like parity

### Required parity

The first stable release must provide:

1. A distinct, non-modifiable preview buffer that never changes the source buffer.
2. A same-window preview by default, analogous to Zed opening a preview item in the current pane.
3. Optional right-split and new-tab-page presentation.
4. Paragraph reflow based on the preview's content width, not the source's physical lines.
5. A centered reading column, capped at a configurable maximum width.
6. Semantic rendering for headings, paragraphs, emphasis, strong text, inline code, links, lists,
   task lists, block quotes, fenced code, thematic breaks, and GitHub-style tables.
7. Source markers such as `#`, backticks, and link destinations omitted from visible prose.
8. Live preview updates from unsaved source-buffer edits.
9. Source-to-preview synchronization in split mode and anchor preservation after rerendering.
10. A direct way to return to or jump into the corresponding source location.
11. Theme-friendly highlight groups with useful defaults and no hard-coded colors.
12. No diagnostics, inlay hints, spell diagnostics, sign column, fold column, or line numbers in the
    generated view.

### Parity that a normal Neovim UI cannot guarantee

Neovim's standard UI is a row-and-column cell grid. The plugin cannot promise:

- proportional body fonts or per-heading font sizes;
- pixel-level line height, kerning, margins, or scrollbar styling;
- browser-quality CSS table layout;
- portable raster-image layout;
- full TeX typesetting or native Mermaid rendering;
- identical bold and italic font faces in every terminal or GUI frontend.

The plugin will reproduce the **document structure and reading layout** from Zed as closely as the
Neovim grid permits. Optional image or math adapters can be considered after the text renderer is
stable, but they are not part of the first release.

## Product behavior

### Commands

Keep the user-facing interface small:

| Command | Behavior |
| --- | --- |
| `:MDEye` | Toggle a preview in the current window. |
| `:MDEye current` | Open or focus the preview in the current window. |
| `:MDEye split` | Open or focus a synchronized preview in a right split. |
| `:MDEye tab` | Open or focus the preview in a new tab page. |
| `:MDEye close` | Close the preview and restore the source view when appropriate. |

The Lua interface should remain equally small:

```lua
require("mdeye").setup(opts)
require("mdeye").open({ mode = "current" })
require("mdeye").close()
require("mdeye").toggle({ mode = "current" })
```

Commands and functions must reject non-Markdown source buffers with one concise notification. Opening
the same source again must focus or move its existing preview rather than create duplicate sessions.

### Default interaction

- `:MDEye` replaces the source in the current window with its preview buffer.
- The source buffer remains loaded and unmodified. The session records its handle and view explicitly;
  it never relies on Neovim's alternate-buffer behavior for restoration.
- `q` closes the preview and restores the source buffer and its saved window view.
- `<CR>` on a rendered block returns to the source at that block's first meaningful character.
- `gx` and `<CR>` on a link open its target; a link under the cursor takes precedence over the ordinary
  block-to-source behavior of `<CR>`.
- In split mode, moving the source cursor scrolls the preview to the corresponding rendered block.
- Preview cursor movement does not constantly move the source cursor; explicit `<CR>` performs that
  jump. This avoids surprising edits or jumplist pollution while reading.
- The preview buffer name is `mdeye://<display-path>` and its title is conceptually
  `Preview <filename>`.

No global keymaps should be installed. The README will provide a suggested eye-style mapping, while
preview-buffer-local mappings may implement `q`, `<CR>`, and `gx`.

### Initial configuration

Avoid exposing the renderer's internals as configuration. Begin with:

```lua
require("mdeye").setup({
  open = "current",
  max_width = 88,
  min_margin = 3,
  debounce_ms = 120,
  code = {
    wrap = false,
  },
})
```

Additional options should only be added after a demonstrated need. Highlight groups, rather than a
large style table, are the primary customization seam.

## Visual acceptance criteria

Test at both narrow and wide window sizes.

### Reading column

- The content width is `min(max_width, available_width - 2 * min_margin)`.
- Left and right margins differ by at most one display cell.
- At narrow widths, margins shrink before content becomes unusably narrow.
- Every prose paragraph is wrapped to the calculated content width.
- Single newlines inside a CommonMark paragraph become spaces; blank lines still separate blocks.
- Resizing the owner window recomputes wrapping and centering while retaining the reader's semantic
  position.

### Document hierarchy

- H1 has the strongest highlight, two blank lines of separation where space permits, and a content-width
  divider beneath it.
- H2 has clear top spacing and a subtler content-width divider.
- H3 through H6 use decreasing emphasis without exposing hash markers.
- Paragraphs receive consistent separation from adjacent blocks.
- Metadata-like introductory emphasis is visually subdued when represented by Markdown emphasis, but
  the renderer does not invent document semantics based on position.

### Inline content

- Emphasis, strong text, strikethrough, and inline code preserve their styles after reflow.
- Inline code has a dedicated highlight and background where supported.
- Link labels are visible and highlighted; raw destinations are hidden.
- Absolute HTTP(S) and absolute file link extmarks carry `url` metadata where supported. Relative links
  route through the buffer-local mapping so they can be resolved against the source path rather than
  Neovim's current working directory. The plugin retains target metadata for all links.
- Multibyte text, emoji, combining characters, and wide glyphs wrap by display cells without corrupting
  byte-indexed extmarks.

### Blocks

- Ordered and unordered lists use normalized markers and hanging indentation.
- Nested lists preserve hierarchy within the content width.
- Task items render distinct checked and unchecked glyphs with a plain-ASCII fallback.
- Block quotes use a consistent gutter and reflow their contents within the reduced width.
- Fenced code preserves internal whitespace and language metadata, omits fence markers, and uses a
  background highlight. The default is horizontal clipping/scrolling rather than semantic code reflow.
- Tables calculate terminal-cell column widths, preserve alignment, and degrade predictably when wider
  than the reading column.
- Thematic breaks render as content-width horizontal lines.

### Preview isolation

- `buftype=nofile`, `bufhidden=wipe`, `swapfile=false`, and `modifiable=false` after every update.
- Set buffer-local `undolevels=-1` so generated replacements cannot accumulate useless undo history.
- Preview `filetype=mdeye`, not `markdown`, so Markdown linters and source-formatting autocmds do not
  attach to generated lines.
- Disable number, relativenumber, signcolumn, foldcolumn, cursorline, colorcolumn, list, and spell in the
  preview window.
- Set `wrap=false`: mdeye owns wrapping by generating actual lines. Neovim must not apply a second,
  unmapped wrapping pass.

## Architecture

The plugin's external seam is a deep session module: callers request a preview, while parsing, layout,
buffer ownership, updates, and synchronization remain implementation details.

```diagram
┌──────────────────────┐
│ Markdown source buf  │
└──────────┬───────────┘
           │ Tree-sitter + source spans
           ▼
┌──────────────────────┐
│ Semantic document    │
│ blocks + inline runs │
└──────────┬───────────┘
           │ width + style policy
           ▼
┌──────────────────────┐
│ Render plan          │
│ lines + marks + map  │
└──────────┬───────────┘
           │ one controlled buffer update
           ▼
┌──────────────────────┐
│ Read-only preview    │
│ buffer in owner win  │
└──────────────────────┘
```

### Planned modules

```text
mdeye.nvim/
├── plugin/
│   └── mdeye.lua              Command registration only
├── lua/mdeye/
│   ├── init.lua               Public interface: setup/open/close/toggle
│   ├── config.lua             Defaults, validation, highlight initialization
│   ├── session.lua            Preview lifecycle, ownership, events, synchronization
│   ├── document.lua           Tree-sitter to normalized semantic document
│   ├── layout.lua             Pure semantic document to width-aware render plan
│   ├── render.lua             Buffer lines, extmarks, and window-local presentation
│   └── health.lua             Neovim/parser checks
├── tests/
│   ├── minimal_init.lua
│   ├── fixtures/
│   ├── document_spec.lua
│   ├── layout_spec.lua
│   └── session_spec.lua
├── doc/
│   └── mdeye.txt              `:help mdeye`
├── docs/
│   └── implementation-plan.md
└── README.md
```

Do not split block-specific renderers into separate files initially. `document.lua` and `layout.lua`
should remain coherent modules until their implementations become difficult to navigate. New modules
must own a real responsibility rather than pass values through.

### Core data model

The semantic document hides Tree-sitter node details from layout:

```lua
---@class MDEyeSourceSpan
---@field start_byte integer
---@field end_byte integer
---@field start_row integer
---@field end_row integer

---@class MDEyeInline
---@field kind "text"|"emphasis"|"strong"|"strike"|"code"|"link"|"image"|"break"
---@field text string
---@field source MDEyeSourceSpan
---@field target? string
---@field children? MDEyeInline[]

---@class MDEyeBlock
---@field kind "heading"|"paragraph"|"list"|"quote"|"code"|"table"|"rule"
---@field source MDEyeSourceSpan
---@field children table[]
---@field attrs table

---@class MDEyeDocument
---@field blocks MDEyeBlock[]
```

`MDEyeSourceSpan` is a navigation anchor, not a promise that every byte between its endpoints belongs
to the rendered text. Injected inline trees inside quotes and lists can have discontiguous included
ranges because source markers occur between text fragments. `document.lua` must extract text from the
injected tree's included ranges during parsing and store the normalized text directly; later modules
must never re-extract display text from a span.

Layout returns one complete, immutable render plan:

```lua
---@class MDEyeRenderPlan
---@field lines string[]
---@field marks MDEyeMark[]       Byte columns in generated lines
---@field blocks MDEyeBlockMap[]  Preview rows to source spans
---@field width integer
---@field margin integer
```

The public interface never exposes these types. They form an internal seam that allows parser and
layout tests to avoid Neovim window side effects.

## Parsing strategy

1. Require Neovim 0.11 or newer and the `markdown` and `markdown_inline` Tree-sitter parsers.
2. Use the source buffer's combined parser and call `parser:parse(true)` to force range-lazy injected
   `markdown_inline` trees to be available even when the source buffer is hidden.
3. Obtain paragraph, heading, and table-cell inline structure from those injected trees. Consume each
   child language tree's `included_ranges()` so nested quote/list markers are excluded while source
   positions remain absolute buffer coordinates. Do not reparse extracted strings and manually rebase
   their offsets.
4. Convert parser-specific node names into the small semantic document model in `document.lua`.
5. Treat ordinary source newlines inside paragraphs as collapsible whitespace. Preserve explicit hard
   breaks and code-block newlines.
6. Resolve relative links against the source buffer's path at interaction time, not during display
   layout.
7. Preserve unsupported constructs as readable plain text rather than dropping content or exposing raw
   parser errors.

Before implementing queries, create a parser-spike fixture covering every required construct and dump
the actual node trees from the minimum supported Neovim/parser versions. Tree-sitter node names must be
verified rather than guessed. The normalized document model insulates the rest of the plugin from node
shape changes. The spike and health check must also verify that the effective runtime injection query
includes `pipe_table_cell`; Neovim's bundled query does, but another parser/query installation can
shadow it.

Raw HTML should be rendered as readable text or omitted only when it is purely structural. mdeye.nvim
will not execute HTML, JavaScript, or remote embedded content.

## Layout strategy

`layout.lua` is the critical module and should be pure: the same document, width, and style policy must
always return the same render plan.

1. Compute the content width and symmetric margin from the owner window's usable text width.
2. Convert each block into styled inline runs.
3. Collapse paragraph whitespace according to Markdown semantics.
4. Wrap at word boundaries using display-cell widths, never Lua byte length.
5. Split an overlong token only when it cannot fit on an otherwise empty line.
6. Emit real buffer lines prefixed with the calculated margin. Do not use virtual lines for prose.
7. Convert run-local offsets to generated buffer byte columns and emit style marks.
8. Record the source span represented by each emitted line and block.
9. Emit explicit blank lines and dividers as part of the plan so vertical rhythm is deterministic.

Use `vim.fn.strdisplaywidth()` or an equivalent verified cell-width helper. Expand tabs according to an
explicit layout policy before measuring them, and treat relevant display options such as `ambiwidth` as
layout inputs in tests. Keep display-cell offsets and Lua byte offsets as separate values throughout
wrapping; conflating them will break extmarks for Unicode text.

A preview buffer is owned by one session and one layout window. The same generated buffer should not be
displayed concurrently at multiple widths because a single set of lines cannot satisfy both layouts.
The owner window alone determines width. Additional windows created manually with `:split` or `:sbuffer`
are best-effort mirrors. If the owner closes while another window still shows the preview, adopt one
remaining window and rerender for its width; if none remains, end the session.

## Rendering and session lifecycle

### Opening

1. Validate the source filetype and parsers.
2. Capture the source buffer, source window, cursor, and `winsaveview()` state.
3. Reuse the source's existing session if one exists.
4. Parse and lay out before replacing the current buffer, preventing a visible empty preview flash.
5. Create the scratch buffer and owner window placement.
6. Apply lines while modifiable, apply extmarks in one namespace, then restore `modifiable=false`.
7. Install buffer-local mappings and session autocmds.

Current-window replacement must be protected with `pcall`. If Neovim refuses to hide a modified source
because the user has disabled the `hidden` option, opening must fail cleanly, preserve the source and its
view, and explain that `hidden` is required for current-window mode; split mode remains available.

### Updating

- Attach to source changes with `nvim_buf_attach()` and debounce document/layout work by the configured
  interval.
- `on_lines` runs under textlock, so it may only mark the session dirty and schedule/debounce later work;
  it must not mutate preview buffers or windows directly.
- Handle `on_reload`, because whole-buffer reloads do not reliably arrive through `on_lines`, and handle
  `on_detach` as source termination.
- Keep an `alive` flag in every attachment callback. Once cleanup marks the session dead, the next
  callback returns `true` to detach; Lua does not provide a general direct `nvim_buf_detach()` call.
- Use the source buffer's changed tick and the owner window width to skip redundant renders.
- On `WinResized` or `VimResized`, reflow only sessions whose usable width changed.
- Before rerendering, map the preview's top visible block to its source span.
- After rerendering, restore the nearest matching source block at the top of the window.
- Replace lines and extmarks as one scheduled update; stale generations must not overwrite newer ones.
- Keep the source buffer authoritative, including unsaved changes. Do not reread the file from disk.

The first implementation may traverse and lay out the whole document per debounced update. Optimize to
partial layout only after benchmarks show that full rendering misses the performance target.

### Synchronization

Every rendered block carries a source span. Use binary search over ordered block mappings:

- **Source to preview:** map the source cursor byte offset to the containing or nearest block and reveal
  that preview row. In split mode, do this on `CursorMoved` without moving preview focus.
- **Preview to source:** map the preview row to its block, restore/focus the source, set the cursor to the
  block's source start, and add one intentional jumplist entry.
- **After an edit:** anchor by source span, not preview line number, because reflow can change every later
  preview row.

Guard synchronization callbacks by session and generation to prevent feedback loops. Free source
viewport scrolling without cursor movement is not an MVP requirement; cursor/block synchronization is.

### Closing

- Mark the session dead so source attachment callbacks return `true`, then remove only the session's
  autocmds, namespace marks, mappings, and owned preview resources.
- In current-window mode, restore the original source buffer, cursor, and saved view when still valid.
- In split/tab mode, close only the preview window or tab page created by the session.
- Because `bufhidden=wipe`, any switch away from the preview can wipe it. Preview `BufWipeout` therefore
  terminates the session; reopening must recreate a preview rather than focus a stale handle.
- Wiping either source or preview must clean the session without affecting unrelated previews.
- Repeated open/close cycles must not leak autocmds, buffers, windows, or callbacks.

## Styling strategy

Define stable semantic highlight groups and default-link them to standard or Tree-sitter groups:

```text
MDEyeText
MDEyeMuted
MDEyeHeading1 ... MDEyeHeading6
MDEyeHeadingRule
MDEyeEmphasis
MDEyeStrong
MDEyeStrike
MDEyeCode
MDEyeCodeBlock
MDEyeLink
MDEyeQuote
MDEyeListMarker
MDEyeTableBorder
MDEyeTaskChecked
MDEyeTaskUnchecked
```

Use `highlight default link` semantics so colorschemes and users remain in control. Reapply only missing
default links on `ColorScheme`; never overwrite explicit user highlights.

Style marks belong to `render.lua`. Parsing records semantics, and layout records where semantic runs
land; neither module should know concrete highlight-group colors.

## Implementation milestones

Each milestone should end in a working vertical slice and targeted tests.

### Milestone 0: parser and layout spike

- Initialize the repository and test harness.
- Record minimum Neovim and parser requirements.
- Add one comprehensive Markdown fixture and inspect actual block/inline node trees.
- Prototype Unicode-aware wrapping and byte-column mark placement.
- Verify that centered actual buffer lines look correct in the user's terminal and colorscheme.

Exit criteria:

- no guessed Tree-sitter node names remain in the proposed parser mapping;
- injected inline trees are obtained with `parse(true)`, including when the source buffer is hidden;
- emphasis spanning a source line break inside a nested blockquote excludes `>` markers and retains
  correct absolute source anchors;
- the effective runtime query provides `markdown_inline` injection for `pipe_table_cell`;
- a paragraph with source hard wraps becomes correctly reflowed generated lines;
- emphasis spanning a wrap boundary receives correct extmarks;
- emoji and wide-character fixtures do not corrupt marks or exceed the width.

### Milestone 1: first readable document view

- Add `setup`, `:MDEye`, `:MDEye close`, and current-window session lifecycle.
- Render headings, paragraphs, emphasis, strong text, inline code, and thematic breaks.
- Implement centered max-width layout and heading dividers.
- Isolate preview options and restore the source view on close.

Exit criteria:

- the research document can be read in a centered, source-marker-free preview;
- the source buffer and its modified state are untouched;
- no diagnostics or Markdown-filetype autocmd output appears in the preview;
- opening and closing ten times leaves no extra buffers or autocmds.

### Milestone 2: essential Markdown coverage

- Add links and navigation, ordered/unordered/nested lists, tasks, quotes, fenced code, and tables.
- Define graceful behavior for unsupported HTML and images.
- Add block and inline fixture coverage for edge cases.

Exit criteria:

- all required first-release Markdown constructs render legibly;
- links retain targets while hiding destinations;
- wide code and tables degrade according to documented policy rather than breaking the layout.

### Milestone 3: live updates and alternate placements

- Add debounced source-buffer updates and stale-generation protection.
- Add width-change reflow and source-span anchor restoration.
- Add split and tab modes.
- Add source-to-preview and explicit preview-to-source navigation.

Exit criteria:

- unsaved source edits update an open split preview;
- resizing reflows without jumping to an unrelated section;
- cursor synchronization remains within the corresponding semantic block;
- source wipeout, preview wipeout, tab close, and window close all clean up safely.

### Milestone 4: production hardening

- Add `:checkhealth mdeye` checks.
- Benchmark large fixtures and optimize only measured bottlenecks.
- Add README, `:help mdeye`, configuration examples, and limitations.
- Add CI for formatting, tests, and the supported Neovim version matrix.
- Perform manual visual comparison against the Zed reference at narrow and wide widths.

Exit criteria:

- all automated tests pass on supported Neovim versions;
- a 1,000-line representative document initially renders within 100 ms on the reference development
  machine, with the result recorded rather than assumed;
- updates remain responsive during normal typing with the default debounce;
- documentation clearly distinguishes terminal-grid limitations from defects.

### Milestone 5: optional rich-content adapters

Only begin after the text renderer is stable:

- local images through an optional `image.nvim` adapter;
- Unicode math rendering or an optional external math adapter;
- Mermaid fallback blocks or an optional terminal-image renderer;
- a follow mode that tracks whichever Markdown source becomes active.

These adapters must remain optional. Core Markdown reading must have no runtime dependency beyond Neovim
and its Markdown Tree-sitter parsers.

## Verification strategy

### Pure module tests

`document.lua` and `layout.lua` should be tested through returned values, not internal helper calls:

- block and inline normalization fixtures;
- whitespace collapse versus explicit hard breaks;
- width calculations at narrow, exact, and wide boundaries;
- nested list hanging indentation;
- style runs crossing wrapped lines;
- source span preservation;
- ASCII, CJK, emoji, combining marks, and tabs;
- overlong words, links, code, and table cells;
- deterministic blank-line and divider placement.

Use readable render-plan snapshots sparingly. Prefer focused assertions for source mappings and mark byte
columns so a visually plausible snapshot cannot hide broken navigation.

### Headless integration tests

Run Neovim with a minimal configuration and real scratch windows:

- command registration and non-Markdown rejection;
- current/split/tab placement;
- preview buffer and window options;
- source immutability and unsaved-edit rendering;
- live-update debounce, reload handling, source detach, and stale generation handling;
- width-change reflow;
- source/preview navigation;
- source and preview wipeout cleanup, including a preview wiped by an ordinary buffer switch;
- duplicate-open behavior;
- ColorScheme default-link preservation;
- no session/autocmd leaks after repeated lifecycle tests.

### Manual visual checks

Automated buffer assertions cannot judge all reading qualities. Before the first release, compare the
same fixture with the Zed reference using:

- approximately 80-column, 120-column, and 200-column windows;
- the user's current terminal, font, and colorscheme;
- at least one light and one dark colorscheme;
- long prose, nested lists, quotes, code, tables, links, and Unicode;
- current-window, split, and tab modes.

The preview passes when it reads as a document at first glance—not as concealed Markdown source.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Tree-sitter Markdown node shapes vary | Isolate them in `document.lua`; verify fixtures on supported versions. |
| Reflow breaks source synchronization | Preserve source spans through inline runs and every rendered block. |
| Unicode produces invalid extmark columns | Track display cells and byte offsets separately; test wide and combining text. |
| Full rerenders feel slow | Debounce first, benchmark, then add partial work only where measured. |
| Resize causes scroll jumps | Anchor the top visible semantic source span before reflow. |
| Tables and code exceed the width | Define deterministic clipping/overflow policies and test them. |
| Other plugins attach to the preview | Use `filetype=mdeye`, `buftype=nofile`, and isolated window options. |
| Multiple sessions leak state | One session owner, one augroup/namespace identity, idempotent cleanup. |
| Colors look good only in one theme | Use semantic default-linked highlight groups, never fixed RGB values. |
| Optional media support destabilizes core | Keep media behind later, optional adapters and outside first-release scope. |

## Decisions locked by this plan

1. mdeye.nvim is a generated document viewer, not a source-decoration plugin.
2. It remains fully inside ordinary Neovim windows; no browser or OS webview is opened.
3. Current-window preview is the default; split and tab are supported placements.
4. Actual preview-buffer lines provide wrapping and vertical rhythm; virtual text is ornamental only.
5. The source buffer is always authoritative and is never rewritten for preview purposes.
6. Tree-sitter parsing is hidden behind a normalized semantic document.
7. Source spans survive the entire parse-layout-render pipeline.
8. The first release prioritizes excellent prose and core Markdown over images, math, diagrams, or HTML.
9. The external interface stays small; renderer internals are not exposed as configuration.
10. Performance optimization follows measurement, not speculative incremental-rendering complexity.

## Open questions to resolve during Milestone 0

These do not block creating the repository, but implementation must verify them before declaring the
architecture stable:

1. Which exact `tree-sitter-markdown` node shapes are present on Neovim 0.11 and 0.12 for tables, task
   items, hard breaks, inline images, and nested emphasis?
2. Does extmark `url` behavior provide a good enough experience across the user's terminal and any GUI
   frontend for absolute URLs, with the buffer-local mapping retained as the portable fallback?
3. Should over-wide tables horizontally clip, proportionally shrink columns with wrapped cells, or
   switch to a stacked representation? The spike should compare all three using real documents.
4. Should same-window mode restore the exact source window after `q` if that window has been repurposed
   by another plugin while the preview is open?
5. What initial-render and update times are observed on 1,000-line and 10,000-line fixtures before any
   optimization?

The first implementation task should be Milestone 0, not command scaffolding. The parser and reflow
spike tests the two highest-risk assumptions before lifecycle code grows around them.
