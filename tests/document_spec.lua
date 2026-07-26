-- document.lua: Tree-sitter -> semantic model, verified against real fixtures.
local document = require("mdeye.document")

local root = vim.g.mdeye_test_root

local function load_fixture(name)
  local bufnr = vim.fn.bufadd(root .. "/tests/fixtures/" .. name)
  vim.fn.bufload(bufnr)
  return bufnr
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(lines, "\n"))
  return bufnr
end

---Recursively concatenate visible text of inline runs.
local function text_of(runs)
  local parts = {}
  for _, run in ipairs(runs) do
    if run.text then
      parts[#parts + 1] = run.text
    end
    if run.children then
      parts[#parts + 1] = text_of(run.children)
    end
  end
  return table.concat(parts)
end

local function find_blocks(blocks, kind)
  local found = {}
  for _, block in ipairs(blocks) do
    if block.kind == kind then
      found[#found + 1] = block
    end
  end
  return found
end

local function find_runs(runs, kind, found)
  found = found or {}
  for _, run in ipairs(runs) do
    if run.kind == kind then
      found[#found + 1] = run
    end
    if run.children then
      find_runs(run.children, kind, found)
    end
  end
  return found
end

describe("document", function()
  local doc
  it("parses the comprehensive fixture from a hidden buffer", function()
    local bufnr = load_fixture("comprehensive.md")
    ok(vim.fn.bufwinid(bufnr) == -1, "fixture buffer must stay hidden")
    local err
    doc, err = document.parse(bufnr)
    ok(doc, err)
    ok(#doc.blocks > 10)
  end)

  it("finds all six heading levels without markers", function()
    local headings = find_blocks(doc.blocks, "heading")
    local levels = {}
    for _, h in ipairs(headings) do
      levels[#levels + 1] = h.attrs.level
      ok(not text_of(h.runs):find("#", 1, true), "heading text must not contain '#'")
    end
    eq({ 1, 2, 3, 4, 5, 6 }, levels)
    eq("Heading One", text_of(headings[1].runs))
  end)

  it("collapses nothing at parse time but keeps newlines in paragraph text", function()
    local para = find_blocks(doc.blocks, "paragraph")[1]
    local text = text_of(para.runs)
    ok(text:find("second source line\nand a third", 1, true), text)
  end)

  it("classifies emphasis, strong, strike, and inline code", function()
    local para = find_blocks(doc.blocks, "paragraph")[1]
    eq("emphasis", text_of(find_runs(para.runs, "emphasis")))
    eq("strong text", text_of(find_runs(para.runs, "strong")))
    eq("strikethrough", text_of(find_runs(para.runs, "strike")))
    eq("inline code", find_runs(para.runs, "code")[1].text)
  end)

  it("captures link labels and targets, autolinks, and image alt text", function()
    local para = find_blocks(doc.blocks, "paragraph")[2]
    local links = find_runs(para.runs, "link")
    eq("link label", text_of(links[1].children))
    eq("https://example.com/page", links[1].target)
    eq("./docs/other.md", links[2].target)
    eq("https://autolink.example.com", links[3].target)
    local image = find_runs(para.runs, "image")[1]
    eq("an image", image.text)
    eq("./img/pic.png", image.target)
  end)

  it("preserves hard line breaks", function()
    local para = find_blocks(doc.blocks, "paragraph")[3]
    eq(1, #find_runs(para.runs, "break"))
  end)

  it("excludes quote markers from emphasis spanning quote lines", function()
    local quotes = find_blocks(doc.blocks, "quote")
    eq(1, #quotes)
    local outer_para = find_blocks(quotes[1].blocks, "paragraph")[1]
    local strong = find_runs(outer_para.runs, "strong")[1]
    local strong_text = text_of({ strong })
    eq("strong\ntext spanning the quote line break", strong_text)
    ok(not strong_text:find(">", 1, true), "no quote markers in extracted text")

    local nested = find_blocks(quotes[1].blocks, "quote")[1]
    local nested_para = find_blocks(nested.blocks, "paragraph")[1]
    local em = find_runs(nested_para.runs, "emphasis")[1]
    local em_text = text_of({ em })
    eq("emphasis\nacross nested quote lines", em_text)
    -- Absolute source anchors survive: the emphasis starts on fixture row 42.
    eq(42, em.source.start_row)
  end)

  it("excludes list continuation indents from emphasis spanning item lines", function()
    local list = find_blocks(doc.blocks, "list")[1]
    local item_para = find_blocks(list.items[2].blocks, "paragraph")[1]
    local em = find_runs(item_para.runs, "emphasis")[1]
    eq("emphasis\nspanning a source line break", text_of({ em }))
  end)

  it("normalizes nested lists, ordered starts, and task states", function()
    local lists = find_blocks(doc.blocks, "list")
    eq(false, lists[1].attrs.ordered)
    local nested = find_blocks(lists[1].items[2].blocks, "list")[1]
    eq(2, #nested.items)
    local deep = find_blocks(nested.items[2].blocks, "list")[1]
    eq(true, deep.attrs.ordered)
    eq(1, deep.attrs.start)

    eq(true, lists[2].attrs.ordered)
    local tasks = lists[3]
    eq("unchecked", tasks.items[1].task)
    eq("checked", tasks.items[2].task)
  end)

  it("keeps fenced code verbatim with language metadata", function()
    local codes = find_blocks(doc.blocks, "code")
    eq("lua", codes[1].attrs.lang)
    eq({
      "local function hello(name)",
      '  return ("hello %s"):format(name)',
      "end",
    }, codes[1].attrs.lines)
    eq(nil, codes[2].attrs.lang)
    eq({ "plain fence without language" }, codes[2].attrs.lines)
  end)

  it("parses tables with alignment and inline cell content", function()
    local tbl = find_blocks(doc.blocks, "table")[1]
    eq({ "left", "center", "right" }, tbl.attrs.aligns)
    eq("Column A", vim.trim(text_of(tbl.attrs.header.cells[1].runs)))
    eq(3, #tbl.attrs.rows)
    local styled_row = tbl.attrs.rows[2]
    eq("em", text_of(find_runs(styled_row.cells[1].runs, "emphasis")))
    eq("code", find_runs(styled_row.cells[2].runs, "code")[1].text)
    eq("x.md", find_runs(styled_row.cells[3].runs, "link")[1].target)
    eq("宽字符", vim.trim(text_of(tbl.attrs.rows[3].cells[1].runs)))
  end)

  it("renders thematic breaks and keeps visible HTML as text", function()
    eq(1, #find_blocks(doc.blocks, "rule"))
    local html = find_blocks(doc.blocks, "html")[1]
    ok(table.concat(html.attrs.lines, "\n"):find("raw html block", 1, true))
  end)

  it("resolves reference links against definitions anywhere in the document", function()
    local bufnr = make_buf(table.concat({
      "See [the spec][spec] and [inline].",
      "",
      "[spec]: https://spec.example.com",
      "[inline]: ./inline.md",
    }, "\n"))
    local d = assert(document.parse(bufnr))
    local para = find_blocks(d.blocks, "paragraph")[1]
    local links = find_runs(para.runs, "link")
    eq("https://spec.example.com", links[1].target)
    eq("the spec", text_of(links[1].children))
    eq("./inline.md", links[2].target)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("preserves setext headings", function()
    local bufnr = make_buf("Title\n=====\n\nSub\n---\n\nbody\n")
    local d = assert(document.parse(bufnr))
    local headings = find_blocks(d.blocks, "heading")
    eq(2, #headings)
    eq(1, headings[1].attrs.level)
    eq("Title", text_of(headings[1].runs))
    eq(2, headings[2].attrs.level)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("keeps block source spans in absolute buffer coordinates", function()
    local rules = find_blocks(doc.blocks, "rule")
    eq(61, rules[1].source.start_row)
    local tables = find_blocks(doc.blocks, "table")
    eq(55, tables[1].source.start_row)
  end)
end)
