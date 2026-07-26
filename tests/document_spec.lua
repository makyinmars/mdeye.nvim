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

  it("assigns stable GitHub-style anchors to headings", function()
    local bufnr = make_buf("# Hello, *World*!\n\n## Hello, World!\n\n# 日本 語\n")
    local d = assert(document.parse(bufnr))
    local headings = find_blocks(d.blocks, "heading")
    eq(3, #headings)
    eq("hello-world", headings[1].attrs.anchor)
    eq("hello-world-1", headings[2].attrs.anchor)
    eq("日本-語", headings[3].attrs.anchor)
    eq("Hello, World!", headings[1].attrs.title)
    eq(headings[2].source, d.anchors["hello-world-1"])
    vim.api.nvim_buf_delete(bufnr, { force = true })
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

  it("captures Tree-sitter highlights and falls back when a code parser is unavailable", function()
    local bufnr = make_buf(table.concat({
      "```lua",
      "local answer = 42",
      "```",
      "",
      "```definitely_missing",
      "plain text",
      "```",
    }, "\n"))
    local d = assert(document.parse(bufnr))
    local codes = find_blocks(d.blocks, "code")
    ok(#codes[1].attrs.highlights > 0, "Lua parser should provide syntax captures")
    local keyword
    for _, mark in ipairs(codes[1].attrs.highlights) do
      if mark.capture == "keyword" then
        keyword = mark
      end
    end
    ok(keyword, "Lua `local` keyword is highlighted")
    eq(0, keyword.row)
    eq(0, keyword.start_col)
    eq(5, keyword.end_col)
    eq("lua", codes[1].attrs.highlight_lang)
    eq({}, codes[2].attrs.highlights)
    eq(nil, codes[2].attrs.highlight_lang)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("normalizes footnote references and definitions", function()
    local bufnr = make_buf(table.concat({
      "Text with a note[^long-note], the same note[^long-note], and missing[^missing].",
      "",
      "[^long-note]: Footnote with *styled text*.",
      "    Continued on another source line.",
    }, "\n"))
    local d = assert(document.parse(bufnr))
    local para = find_blocks(d.blocks, "paragraph")[1]
    local refs = find_runs(para.runs, "footnote")
    eq(2, #refs)
    eq("[1]", refs[1].text)
    eq("#fn-long-note", refs[1].target)
    ok(text_of(para.runs):find("[^missing]", 1, true), "unresolved footnote stays readable")
    local notes = find_blocks(d.blocks, "footnote")
    eq(1, #notes)
    eq(1, notes[1].attrs.ordinal)
    eq("fn-long-note", notes[1].attrs.anchor)
    eq(notes[1].source, d.anchors["fn-long-note"])
    eq("Footnote with styled text.\n    Continued on another source line.", text_of(notes[1].runs))
    eq("styled text", text_of(find_runs(notes[1].runs, "emphasis")))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("recognizes compact footnotes before their references", function()
    local bufnr = make_buf(table.concat({
      "[^n]: note",
      "",
      "Text after the definition[^n].",
    }, "\n"))
    local parsed = assert(document.parse(bufnr))
    local notes = find_blocks(parsed.blocks, "footnote")
    eq(1, #notes)
    eq("note", text_of(notes[1].runs))
    eq(1, notes[1].attrs.ordinal)
    local para = find_blocks(parsed.blocks, "paragraph")[1]
    local ref = find_runs(para.runs, "footnote")[1]
    eq("[1]", ref.text)
    eq("#fn-n", ref.target)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("keeps indented continuation paragraphs inside a footnote", function()
    local bufnr = make_buf(table.concat({
      "Text[^n].",
      "",
      "[^n]: first paragraph",
      "",
      "    second paragraph",
      "",
      "outside",
    }, "\n"))
    local parsed = assert(document.parse(bufnr))
    local note = find_blocks(parsed.blocks, "footnote")[1]
    local continuation = find_blocks(note.blocks, "paragraph")[1]
    eq("second paragraph", text_of(continuation.runs))
    eq(0, #find_blocks(parsed.blocks, "code"))
    eq("outside", text_of(find_blocks(parsed.blocks, "paragraph")[2].runs))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("preserves Markdown blocks inside footnote continuations", function()
    local bufnr = make_buf(table.concat({
      "Text[^n].",
      "",
      "[^n]: first paragraph",
      "",
      "    second *styled* paragraph with [a reference][ref].",
      "",
      "    - list item with `code`",
      "",
      "    ```lua",
      "    local value = 42",
      "    ```",
      "",
      "[ref]: https://example.com/reference",
    }, "\n"))
    local parsed = assert(document.parse(bufnr))
    local note = find_blocks(parsed.blocks, "footnote")[1]
    ok(note.blocks and #note.blocks >= 2, "continuation is parsed into semantic blocks")

    local continuation = find_blocks(note.blocks, "paragraph")[1]
    eq(4, continuation.source.start_row)
    eq("styled", text_of(find_runs(continuation.runs, "emphasis")))
    local link = find_runs(continuation.runs, "link")[1]
    eq("a reference", text_of(link.children))
    eq("https://example.com/reference", link.target)

    local list = find_blocks(note.blocks, "list")[1]
    ok(list, "continued list remains a list")
    eq(6, list.source.start_row)
    local item = find_blocks(list.items[1].blocks, "paragraph")[1]
    eq("code", find_runs(item.runs, "code")[1].text)
    local code = find_blocks(note.blocks, "code")[1]
    eq("lua", code.attrs.lang)
    eq({ "local value = 42" }, code.attrs.lines)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("keeps heading and footnote anchors distinct", function()
    local bufnr = make_buf("# fn-n\n\nText[^n].\n\n[^n]: note\n")
    local parsed = assert(document.parse(bufnr))
    local heading = find_blocks(parsed.blocks, "heading")[1]
    local note = find_blocks(parsed.blocks, "footnote")[1]
    local ref = find_runs(find_blocks(parsed.blocks, "paragraph")[1].runs, "footnote")[1]
    eq("fn-n", heading.attrs.anchor)
    eq("fn-n-1", note.attrs.anchor)
    eq("#fn-n-1", ref.target)
    ok(parsed.anchors["fn-n"])
    ok(parsed.anchors["fn-n-1"])
    vim.api.nvim_buf_delete(bufnr, { force = true })
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
