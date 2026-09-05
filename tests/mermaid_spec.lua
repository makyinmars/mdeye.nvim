local mermaid = require("mdeye.mermaid")
local measure = vim.fn.strdisplaywidth
local function parse(source)
  return mermaid.parse(vim.split(source, "\n"))
end

describe("mermaid", function()
  it("parses directions, chains, shapes, comments, and label updates", function()
    for _, direction in ipairs({ "LR", "RL", "TD", "TB", "BT" }) do
      local graph = assert(
        parse(
          "%% comment\ngraph "
            .. direction
            .. '; A[Start] --> B{Ready?} -->|yes| C((Done)); B["Updated; label"]'
        )
      )
      eq(direction, graph.direction)
      eq(3, #graph.nodes)
      eq(2, #graph.edges)
      eq("Updated; label", graph.edges[1].to.label)
      eq("yes", graph.edges[2].label)
      eq("circle", graph.nodes[3].shape)
    end
  end)

  it("keeps semicolons, brackets, and comment markers in quoted labels", function()
    local graph = assert(parse('flowchart LR\nA["hello ]; %% world"] --> B'))
    eq("hello ]; %% world", graph.nodes[1].label)
  end)

  it("retains all branches, cycles, self-links, and disconnected nodes", function()
    local graph = assert(parse("flowchart LR\nA --> B\nA -.-> C\nC ==> A\nB --- B\nD[Alone]"))
    eq(4, #graph.edges)
    local text = table.concat(assert(mermaid.layout(graph, 80, measure)), "\n")
    ok(text:find("..>", 1, true))
    ok(text:find("==>", 1, true))
    ok(text:find("---", 1, true))
    ok(text:find("D: Alone", 1, true))
    local count = 0
    for _ in text:gmatch("| A%s+|") do
      count = count + 1
    end
    eq(3, count)
  end)

  it("distinguishes nodes with identical labels", function()
    local graph = assert(parse("flowchart LR; A[Same] --> B[Same]"))
    local text = table.concat(mermaid.layout(graph, 80, measure), "\n")
    ok(text:find("A: Same", 1, true))
    ok(text:find("B: Same", 1, true))
  end)

  it("uses the requested direction and stacks narrow horizontal connections", function()
    for _, direction in ipairs({ "LR", "RL", "TD", "TB", "BT" }) do
      local graph = assert(parse("flowchart " .. direction .. "; A --> B"))
      local wide = table.concat(mermaid.layout(graph, 80, measure), "\n")
      local narrow = table.concat(mermaid.layout(graph, 12, measure), "\n")
      local reverse = direction == "RL" or direction == "BT"
      ok(narrow:find(reverse and "^" or "v", 1, true))
      if direction == "LR" or direction == "RL" then
        ok(wide:find(reverse and "<--" or "-->", 1, true))
      end
      local first = reverse and "B" or "A"
      local second = reverse and "A" or "B"
      ok(narrow:find(first, 1, true) < narrow:find(second, 1, true))
    end
  end)

  it("wraps Unicode node and edge labels within available cells", function()
    local graph = assert(
      parse('flowchart LR; A["日本語 café é"] -->|日本語 label| B[Longlonglonglonglabel]')
    )
    for _, width in ipairs({ 8, 12, 20, 40, 80 }) do
      local lines = assert(mermaid.layout(graph, width, measure))
      for _, line in ipairs(lines) do
        ok(measure(line) <= width, vim.inspect({ width, line }))
      end
    end
    eq(nil, mermaid.layout(graph, 7, measure))
  end)

  it("falls back atomically for unsupported or incomplete input", function()
    for _, source in ipairs({
      "",
      "flowchart LR",
      "sequenceDiagram\nAlice->>Bob: Hi",
      "flowchart XX; A --> B",
      "flowchart LR; A -->",
      "flowchart LR; A --> B; subgraph X",
      "flowchart LR; A --> B; style A fill:red",
      "flowchart LR; A --> B; click A callback",
      "flowchart LR; A & B --> C",
      "flowchart LR; A---oB",
      "flowchart LR; A---xB",
      "flowchart LR; A --> B:::red",
      'flowchart LR; A["bad]',
      "flowchart LR; A[<b>HTML</b>]",
      "flowchart LR; A@{ shape: rect }",
      "flowchart LR; A[/Parallelogram/]",
      "%%{init: {}}%%\nflowchart LR; A --> B",
    }) do
      local graph, reason = parse(source)
      eq(nil, graph, source)
      ok(reason, source)
    end
  end)

  it("supports the long form of solid edge labels", function()
    local graph = assert(parse('flowchart LR; A -- hello world --> B -- "next step" --> C'))
    eq("hello world", graph.edges[1].label)
    eq("next step", graph.edges[2].label)
  end)

  it("bounds work for large diagrams", function()
    local lines = { "flowchart LR" }
    for i = 1, 101 do
      lines[#lines + 1] = "N" .. i
    end
    local graph, reason = mermaid.parse(lines)
    eq(nil, graph)
    eq("diagram exceeds native limits", reason)
  end)
end)
