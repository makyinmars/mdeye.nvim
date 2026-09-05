# Mermaid implementation evidence

The initial native renderer supports a conservative flowchart subset. It parses once
through `document.lua`, stores a graph beside the original fenced lines, and lays out
connected node pairs through `layout.lua`. It uses no external runtime or network.
The public API stays in `init.lua`; Tree-sitter access stays in `document.lua`.

Syntax reference: [Mermaid flowcharts](https://mermaid.js.org/syntax/flowchart.html).
The supported subset and explicit exclusions are documented in README.md and Vim help.

## Terminal captures

Fixture: `tests/fixtures/mermaid.md`. Reproduce the native captures with:

```sh
nvim --headless -l tests/spike/render_demo.lua 100 tests/fixtures/mermaid.md
nvim --headless -l tests/spike/render_demo.lua 30 tests/fixtures/mermaid.md
```

Before (equivalent source view with `mermaid_enabled = false` in layout options):

```text
                                                                                       mermaid
       flowchart LR
         A[Draft] -->|review| B{Approved?}
         B -->|yes| C[Publish]
         B -->|no| A
         D[Independent]
```

After, 100-cell window:

```text
                                                                         mermaid (connections)
       +----------+            <-------------->
       | A: Draft | review --> | B: Approved? |
       +----------+            <-------------->

       <-------------->         +------------+
       | B: Approved? | yes --> | C: Publish |
       <-------------->         +------------+

       <-------------->        +----------+
       | B: Approved? | no --> | A: Draft |
       <-------------->        +----------+

       +----------------+
       | D: Independent |
       +----------------+
```

After, 30-cell window:

```text
      mermaid (connections)
    +----------+
    | A: Draft |
    +----------+
      | review
      v
    <-------------->
    | B: Approved? |
    <-------------->

    <-------------->
    | B: Approved? |
    <-------------->
      | yes
      v
    +------------+
    | C: Publish |
    +------------+

    <-------------->
    | B: Approved? |
    <-------------->
      | no
      v
    +----------+
    | A: Draft |
    +----------+

    +----------------+
    | D: Independent |
    +----------------+
```

The fixture also checks reverse vertical direction, Unicode labels inside a quote,
unsupported sequence diagrams, and styling directives that retain the entire source.
The captures were inspected for arrow direction, label alignment, and pane fit.

## Verification

Full suite: **86 passed, 0 failed** on the development Neovim installation.

- Parser/layout specs cover all five directions, quoted labels, comments, shape
  approximations, both solid edge-label forms, label updates, duplicate labels,
  branches, cycles, self-links, isolated nodes, limits, and atomic fallback.
- Layout integration checks immutable parsed input, nested quote widths, byte-valid
  highlights, original copy data, source spans, disabled rendering, and narrow panes.
- Session integration checks resize reflow, live edits through valid → incomplete →
  valid syntax, copying Mermaid text, and jumping from diagram rows to the fence.
- Formatting: `stylua --check lua plugin tests`.
- Lint: `luacheck --no-cache lua plugin tests` (default cache directory is outside
  the writable sandbox).

On the development machine, the existing 1,010-line benchmark measured a 55.39 ms
median total render, below its 100 ms target. The Mermaid benchmark
(`nvim --headless -l tests/bench/mermaid.lua`) measured a 100-node/100-edge cycle at
402 preview lines: median parse 1.48 ms, layout 2.44 ms, render 5.40 ms after one
warmup and five measured iterations. These are local measurements, not guarantees.

## Improvements identified

Implemented during verification:

- Wrap wide connection pairs vertically instead of clipping them.
- Keep node IDs beside labels so duplicate labels and repeated branch junctions
  cannot imply different graph relationships.
- Reject unsupported constructs atomically, including styling and circle/cross
  links, instead of displaying a partial or misleading graph.
- Show a readable fallback reason, and wrap language tags in narrow panes.
- Bound native parse work and avoid an unnecessary Mermaid Tree-sitter lookup.

Next useful extensions, in priority order:

1. Add a real graph layout with shared junctions and routed edges. The current pair
   view is predictable but repeats nodes and grows tall for dense graphs. It must
   preserve cycles, parallel edges, disconnected components, and width constraints.
2. Add subgraphs and sequence diagrams as separate semantic models with their own
   fixtures. Do not discard directives or flatten grouping into the existing model.
3. Consider an optional official Mermaid SVG/image adapter for full syntax and shape
   fidelity. This requires explicit backend availability, lifecycle cleanup, caching,
   and the same complete-source fallback. It is not part of this implementation.
