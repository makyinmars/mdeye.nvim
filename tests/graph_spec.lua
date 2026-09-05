local mermaid = require("mdeye.mermaid")
local measure = vim.fn.strdisplaywidth
local function parse(source)
  return assert(mermaid.parse(vim.split(source, "\n")))
end

describe("shared Mermaid graphs", function()
  it(
    "draws each node once with distinct routes for branches, cycles, and parallel edges",
    function()
      local graph =
        parse("flowchart TD; A -->|one| B; A -.->|two| B; B ==> C; C --> A; C --> C; D[Alone]")
      local before = vim.deepcopy(graph)
      local lines, keys, mode = mermaid.layout(graph, 80, measure)
      eq("graph", mode)
      local text = table.concat(lines, "\n")
      for _, id in ipairs({ "A", "B", "C" }) do
        local count = 0
        for _ in text:gmatch("| " .. id .. "%s+|") do
          count = count + 1
        end
        eq(1, count, id)
      end
      ok(text:find("1: A --> B — one", 1, true))
      ok(text:find("2: A -.-> B — two", 1, true))
      ok(text:find("5: C --> C", 1, true))
      ok(text:find("<", 1, true))
      ok(vim.tbl_contains(vim.tbl_values(keys), "node:C"))
      for _, line in ipairs(lines) do
        ok(measure(line) <= 80, line)
      end
      eq(before, graph)
    end
  )

  it("orders nodes by direction and falls back without losing relationships", function()
    for _, direction in ipairs({ "LR", "RL", "TD", "TB", "BT" }) do
      local graph = parse("flowchart " .. direction .. "; A --> B")
      local lines, _, mode = mermaid.layout(graph, 60, measure)
      eq("graph", mode)
      local text = table.concat(lines, "\n")
      local reverse = direction == "RL" or direction == "BT"
      ok((text:find("| A", 1, true) < text:find("| B", 1, true)) ~= reverse)
      local narrow, _, fallback = mermaid.layout(graph, 10, measure)
      eq("connections", fallback)
      ok(narrow)
    end
  end)

  it("draws nested subgraph containers and cross-group routes", function()
    local graph = parse(
      "flowchart TD\nsubgraph outer[Service]\nsubgraph inner[Storage]\nA[Cache]\nend\nB[API]\nend\nC[Client] --> B\nB --> A"
    )
    eq(2, #graph.groups)
    eq("inner", graph.nodes[1].group)
    local lines, _, mode = mermaid.layout(graph, 70, measure)
    eq("graph", mode)
    local text = table.concat(lines, "\n")
    for _, label in ipairs({
      "Service",
      "Storage",
      "A: Cache",
      "B: API",
      "C: Client",
      "C --> B",
      "B --> A",
    }) do
      ok(text:find(label, 1, true), label)
    end
    eq(nil, mermaid.layout(graph, 8, measure))
    for _, line in ipairs(lines) do
      ok(measure(line) <= 70, line)
    end
  end)

  it("rejects malformed groups instead of dropping their meaning", function()
    for _, source in ipairs({
      "flowchart TD; end; A",
      "flowchart TD; subgraph X; A",
      "flowchart TD; subgraph X; A; end; X --> B",
      "flowchart TD; subgraph X; A; end; subgraph X; B; end",
    }) do
      eq(nil, mermaid.parse(vim.split(source, "\n")))
    end
  end)
end)
