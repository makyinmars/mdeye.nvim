local mermaid = require("mdeye.mermaid")
local measure = vim.fn.strdisplaywidth
local function parse(source)
  return mermaid.parse(vim.split(source, "\n"))
end

describe("Mermaid sequences", function()
  it("renders aliases, actors, messages, returns, self-calls, and activations", function()
    local model = assert(
      parse(
        "sequenceDiagram\nautonumber\nactor A as Alice\nparticipant B as Server\nA->>+B: Request\nB->>B: Validate\nB-->>-A: Response"
      )
    )
    eq("sequence", model.kind)
    eq(2, #model.participants)
    eq(3, #model.events)
    local lines, keys, mode = mermaid.layout(model, 60, measure)
    eq("sequence", mode)
    local text = table.concat(lines, "\n")
    for _, label in ipairs({ "A: Alice", "B: Server", "1. Request", "2. Validate", "3. Response" }) do
      ok(text:find(label, 1, true), label)
    end
    ok(text:find("#", 1, true))
    ok(text:find("...", 1, true))
    ok(vim.tbl_contains(vim.tbl_values(keys), model.events[2].key))
  end)

  it("supports notes and nested loop/alt/par regions", function()
    local model = assert(
      parse(
        "sequenceDiagram\nparticipant A\nparticipant B\nNote over A,B: 日本語\nloop attempts\nalt ready\nA->>B: Go\nelse busy\nB-->>A: Wait\nend\nend\npar background\nA->>B: One\nand foreground\nA->>B: Two\nend"
      )
    )
    for _, width in ipairs({ 24, 50, 80 }) do
      local lines = assert(mermaid.layout(model, width, measure))
      for _, line in ipairs(lines) do
        ok(measure(line) <= width, line)
      end
    end
    eq(nil, mermaid.layout(model, 15, measure))
  end)

  it("rejects incomplete or unsupported statements atomically", function()
    for _, source in ipairs({
      "sequenceDiagram\nA->>B",
      "sequenceDiagram\nelse wrong",
      "sequenceDiagram\nloop repeat\nA->>B: Hi",
      "sequenceDiagram\nend",
      "sequenceDiagram\nA->>B: <b>Hi</b>",
      "sequenceDiagram\nrect red\nA->>B: Hi\nend",
      "sequenceDiagram\ndeactivate A",
      "sequenceDiagram\nparticipant A as",
      "sequenceDiagram\nNote nowhere A: hi",
    }) do
      local model, reason = parse(source)
      eq(nil, model, source)
      ok(reason)
    end
  end)
end)

describe("sequence reading identities", function()
  it("keeps an existing event identity when earlier messages are inserted", function()
    local a = assert(parse("sequenceDiagram\nA->>B: First\nB-->>A: Reply"))
    local b = assert(parse("sequenceDiagram\nA->>B: New\nA->>B: First\nB-->>A: Reply"))
    eq(a.events[2].key, b.events[3].key)
  end)
end)
