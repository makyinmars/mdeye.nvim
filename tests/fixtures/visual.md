# Reading preview

A paragraph with **strong text**, *emphasis*, and 日本語 café é that wraps across the reading column.

## Lists and tables

- Parent item
  - Nested content with `inline code`.
- [x] Finished

| Name | Value |
| :--- | ---: |
| 日本語 | 42 |
| Longer label | café |

> A quotation with a [link](https://example.com).

## Branch and cycle

```mermaid
flowchart LR
A[Draft] --> B{Ready?}
B -->|yes| C[Ship]
B -->|no| A
```

## Subgraphs

```mermaid
flowchart TD
subgraph api[Service]
A[API] --> B[Cache]
end
C[Client] --> A
```

## Sequence

```mermaid
sequenceDiagram
participant A
participant B
autonumber
A->>B: Request
B-->>A: Response
```

## Code

```lua
local answer = 42
print(answer)
```
