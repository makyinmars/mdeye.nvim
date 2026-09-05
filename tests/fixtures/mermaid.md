# Mermaid flowcharts

## Review cycle

```mermaid
flowchart LR
  A[Draft] -->|review| B{Approved?}
  B -->|yes| C[Publish]
  B -->|no| A
  D[Independent]
```

## Direction and Unicode

> ```mermaid
> graph BT
> A["日本語 café"] -.->|retry| B((Ready))
> ```

## Unsupported diagrams retain source

```mermaid
sequenceDiagram
  Alice->>Bob: Hello
```

## Styling retains the entire source

```mermaid
flowchart LR
  A --> B
  style A fill:red
```
