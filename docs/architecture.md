# mdeye.nvim architecture

mdeye opens a Markdown buffer as a separate read-only document view. Tree-sitter
access stays in `document.lua`. The public API stays in `init.lua`. Everything
else is parse, layout, render, or an optional adapter.

## Pipeline

Source never becomes the preview. A session owns one preview buffer, parses a
semantic document, lays out a width-aware plan, and paints that plan.

```mermaid
flowchart TD
  subgraph commands[Commands]
    Plugin["plugin/mdeye.lua"]
    Init[init.lua]
  end
  subgraph session[Session]
    Session[session.lua]
    View[view.lua]
  end
  subgraph parse[Parse]
    Document[document.lua]
    Mermaid[mermaid.lua]
  end
  subgraph adapters[Optional adapters]
    MermaidImage[mermaid_image.lua]
    Images[images.lua]
  end
  subgraph layout[Layout]
    Layout[layout.lua]
    Graph[graph.lua]
    Sequence[sequence.lua]
  end
  subgraph paint[Paint]
    Render[render.lua]
    Preview[preview buffer]
  end
  Plugin --> Init
  Init --> Session
  Session --> Document
  Document --> Mermaid
  Session --> MermaidImage
  Session --> Images
  Session --> Layout
  Layout --> Graph
  Layout --> Sequence
  MermaidImage -->|PNG| Images
  Session --> Render
  Render --> Preview
  Session --> View
```

![Pipeline](architecture-pipeline.png)

- `document.lua` turns the source buffer into blocks, inlines, and source spans.
- `mermaid.lua` parses a conservative flowchart/sequence subset beside the original fence.
- `mermaid_image.lua` optionally shells out to `mmdc` and caches a PNG.
- `layout.lua` builds the preview lines. Ready PNGs reserve image cells; otherwise native ASCII from `graph.lua` / `sequence.lua`; otherwise the original source.
- `render.lua` writes the plan into the preview buffer.
- `view.lua` keeps reading anchors and folds across live updates.

## Mermaid fallback

```mermaid
flowchart TD
  Fence[mermaid fence]
  Fence --> Ready{PNG ready?}
  Ready -->|yes| Image[mermaid image]
  Ready -->|no| Native{ASCII parse?}
  Native -->|yes| Ascii[graph or sequence]
  Native -->|no| Source[source plus reason]
```

![Mermaid fallback](architecture-fallback.png)

`yc` always copies the original fence text. `go` opens a ready PNG in the OS
viewer. Inline graphics still need `images.enabled` and image.nvim.

## Live update

```mermaid
sequenceDiagram
participant User
participant Session
participant Document
participant Layout
participant Render
User->>Session: edit source
Session->>Document: parse
Session->>Layout: plan
Session->>Render: apply
Render-->>User: preview
```

![Live update](architecture-update.png)

Edits are debounced. A finished mermaid PNG schedules another plan without
blocking the first paint.
