-- layout.lua: pure width-aware planning, tested through returned plans.
local document = require("mdeye.document")
local layout = require("mdeye.layout")

local function make_doc(markdown)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(markdown, "\n"))
  local doc = assert(document.parse(bufnr))
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return doc
end

local function make_plan(markdown, opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    usable_width = 100,
    max_width = 88,
    min_margin = 3,
  })
  return layout.plan(make_doc(markdown), opts)
end

local function width(s)
  return vim.fn.strdisplaywidth(s)
end

---Visible text of a mark: the exact bytes its columns select.
local function mark_text(plan, mark)
  return plan.lines[mark.row + 1]:sub(mark.start_col + 1, mark.end_col)
end

local function marks_with(plan, hl)
  local found = {}
  for _, mark in ipairs(plan.marks) do
    if mark.hl == hl then
      found[#found + 1] = mark
    end
  end
  return found
end

local function content_lines(plan)
  local found = {}
  for _, line in ipairs(plan.lines) do
    if line ~= "" then
      found[#found + 1] = line
    end
  end
  return found
end

describe("layout", function()
  it("computes a centered reading column", function()
    local w, m = layout.geometry(100, 88, 3)
    eq(88, w)
    eq(6, m)
    -- margins differ by at most one cell
    ok(math.abs((100 - w - m) - m) <= 1)

    -- max_width caps wide windows
    local w2, m2 = layout.geometry(200, 88, 3)
    eq(88, w2)
    eq(56, m2)

    -- false lets the reading column follow the available window width
    local w3, m3 = layout.geometry(200, false, 3)
    eq(194, w3)
    eq(3, m3)

    -- narrow windows shrink margins before content becomes unusable
    local w4, m4 = layout.geometry(24, 88, 3)
    eq(20, w4)
    eq(2, m4)

    local w5 = layout.geometry(12, 88, 3)
    eq(12, w5)
  end)

  it("reflows source hard-wrapped paragraphs into semantic lines", function()
    local plan = make_plan(
      "This paragraph continues\non a second source line\nand ends here.",
      { usable_width = 200 }
    )
    local lines = content_lines(plan)
    eq(1, #lines)
    ok(lines[1]:find("continues on a second source line and ends here", 1, true))
  end)

  it("wraps every prose line within margin + width", function()
    local plan = make_plan(([[
# A Long Document

%s

- item %s
]]):format(("word "):rep(60), ("nested "):rep(30)))
    for _, line in ipairs(plan.lines) do
      ok(
        width(line) <= plan.margin + plan.width,
        ("line too wide (%d > %d): %q"):format(width(line), plan.margin + plan.width, line)
      )
    end
  end)

  it("preserves hard breaks while collapsing soft breaks", function()
    local plan = make_plan("line one\\\nline two soft\nline continues")
    local lines = content_lines(plan)
    eq(2, #lines)
    ok(lines[1]:find("line one$"))
    ok(lines[2]:find("line two soft line continues", 1, true))
  end)

  it("emits correct extmark byte columns when emphasis crosses a wrap", function()
    -- Width forces the emphasized phrase to wrap in the middle.
    local plan = make_plan(
      "aaaa bbbb *styled words that cross the wrap boundary* tail",
      { usable_width = 26, max_width = 24, min_margin = 1 }
    )
    local marks = marks_with(plan, "MDEyeEmphasis")
    ok(#marks >= 2, "emphasis must produce marks on both wrapped lines")
    local rows = {}
    local collected = {}
    for _, mark in ipairs(marks) do
      rows[mark.row] = true
      collected[#collected + 1] = mark_text(plan, mark)
    end
    ok(vim.tbl_count(rows) >= 2, "marks span multiple preview rows")
    local joined = vim.trim(table.concat(collected, " ")):gsub("%s+", " ")
    eq("styled words that cross the wrap boundary", joined)
  end)

  it("places byte-accurate marks after wide and multibyte text", function()
    local plan = make_plan("日本語のテキスト and `code` plus 🚀 **强调** end")
    local code = marks_with(plan, "MDEyeCode")[1]
    eq("code", mark_text(plan, code))
    local strong = marks_with(plan, "MDEyeStrong")[1]
    eq("强调", mark_text(plan, strong))
  end)

  it("wraps by display cells so wide glyphs never exceed the width", function()
    local plan = make_plan(
      ("宽"):rep(30) .. " " .. ("字"):rep(30),
      { usable_width = 30, max_width = 26, min_margin = 2 }
    )
    for _, line in ipairs(plan.lines) do
      ok(width(line) <= plan.margin + plan.width, line)
    end
  end)

  it("splits an overlong token only when it cannot fit on an empty line", function()
    local token = ("x"):rep(60)
    local plan = make_plan("short " .. token, { usable_width = 30, max_width = 26, min_margin = 2 })
    local lines = content_lines(plan)
    ok(#lines >= 3)
    ok(lines[1]:find("short$"), "short word keeps its own line")
    for _, line in ipairs(lines) do
      ok(width(line) <= plan.margin + plan.width)
    end
  end)

  it("keeps link labels visible, destinations hidden, and targets attached", function()
    local plan = make_plan("Read [the manual](https://example.com/manual) now.")
    local text = table.concat(plan.lines, "\n")
    ok(text:find("the manual", 1, true))
    ok(not text:find("https://example.com/manual", 1, true), "destination must be hidden")
    local link = marks_with(plan, "MDEyeLink")[1]
    eq("the manual", mark_text(plan, link))
    eq("https://example.com/manual", link.target)
  end)

  it("uses hanging indentation for nested lists", function()
    local plan = make_plan(
      table.concat({
        "- alpha item that is long enough to wrap onto a continuation line for sure",
        "  - nested beta",
        "1. first",
        "2. second",
      }, "\n"),
      { usable_width = 50, max_width = 44, min_margin = 3 }
    )
    local lines = content_lines(plan)
    local first = lines[1]
    local marker_col = first:find("•")
    ok(marker_col, "bullet marker rendered")
    -- Continuation line aligns under the text, not under the bullet.
    local cont = lines[2]
    ok(not cont:find("•"))
    local text_col = select(2, first:find("• ")) + 1
    eq(first:sub(text_col, text_col):match("%S") ~= nil, true)
    ok(cont:sub(text_col, text_col):match("%S") ~= nil, "hanging indent alignment")
  end)

  it("renders distinct task glyphs with a deterministic ASCII fallback", function()
    local md = "- [ ] todo\n- [x] done"
    local plan = make_plan(md)
    local text = table.concat(plan.lines, "\n")
    ok(text:find("☐ todo", 1, true))
    ok(text:find("☑ done", 1, true))

    -- When the glyphs do not measure one cell (ambiwidth=double), fall back.
    local wide_measure = function(s)
      local total = 0
      for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
        total = total + ((ch == "☐" or ch == "☑") and 2 or vim.fn.strdisplaywidth(ch))
      end
      return total
    end
    local ascii_plan = layout.plan(make_doc(md), {
      usable_width = 100,
      max_width = 88,
      min_margin = 3,
      measure = wide_measure,
    })
    local ascii_text = table.concat(ascii_plan.lines, "\n")
    ok(ascii_text:find("[ ] todo", 1, true))
    ok(ascii_text:find("[x] done", 1, true))
  end)

  it("reflows quotes within the gutter-reduced width", function()
    local plan =
      make_plan("> " .. ("quoted "):rep(20), { usable_width = 40, max_width = 36, min_margin = 2 })
    for _, line in ipairs(content_lines(plan)) do
      ok(line:find("┃", 1, true) ~= nil, "gutter on every quote line")
      ok(width(line) <= plan.margin + plan.width)
    end
  end)

  it("renders GitHub-style alerts with semantic titles and highlights", function()
    local plan = make_plan(
      "> [!WARNING]\n> Be **careful** with this long warning because it must wrap safely.\n>\n> - nested item",
      { usable_width = 42, max_width = 38, min_margin = 2 }
    )
    local text = table.concat(plan.lines, "\n")
    ok(text:find("┃ Warning", 1, true), "semantic alert title is visible")
    ok(not text:find("[!WARNING]", 1, true), "source marker is hidden")
    ok(text:find("• nested item", 1, true), "nested Markdown stays semantic")
    for _, line in ipairs(content_lines(plan)) do
      ok(line:find("┃", 1, true), "alert gutter on every content line")
      ok(width(line) <= plan.margin + plan.width, "alert line exceeds the reading column")
    end
    local marks = marks_with(plan, "MDEyeAlertWarning")
    ok(#marks > 0, "warning title and gutter use the warning highlight")
    ok(mark_text(plan, marks[1]):find("Warning", 1, true))
  end)

  it("keeps code verbatim, padded to a background block, never reflowed", function()
    local plan = make_plan("```lua\nlocal x = 1    -- spacing   kept\nreturn x\n```")
    local code_lines = {}
    for _, line in ipairs(plan.lines) do
      if line:find("local x", 1, true) or line:find("return x", 1, true) then
        code_lines[#code_lines + 1] = line
      end
    end
    eq(2, #code_lines)
    ok(code_lines[1]:find("spacing   kept", 1, true), "internal whitespace preserved")
    -- Padded to the full content width for the background rectangle.
    eq(plan.margin + plan.width, width(code_lines[1]))
    ok(#marks_with(plan, "MDEyeCodeBlock") >= 2)
    ok(table.concat(plan.lines, "\n"):find("lua", 1, true), "language label kept")
    ok(not table.concat(plan.lines, "\n"):find("```", 1, true), "fence markers omitted")
  end)

  it("keeps an empty unlabeled fence available for copying", function()
    local plan = make_plan("```\n```")
    eq(1, #plan.code_blocks)
    eq({}, plan.code_blocks[1].lines)
    eq(1, #marks_with(plan, "MDEyeCodeBlock"))
  end)

  it("maps fenced-code syntax captures onto generated byte columns", function()
    local plan = make_plan("```lua\nlocal answer = 42\n```")
    local keywords = marks_with(plan, "@keyword.lua")
    eq(1, #keywords)
    eq("local", mark_text(plan, keywords[1]))
    eq(1, #plan.code_blocks)
    eq({ "local answer = 42" }, plan.code_blocks[1].lines)
    eq("lua", plan.code_blocks[1].lang)
  end)

  it("keeps unavailable fenced-code languages readable as plain text", function()
    local plan = make_plan("```definitely_missing\nplain <text> stays readable\n```")
    ok(table.concat(plan.lines, "\n"):find("plain <text> stays readable", 1, true))
    eq(0, #marks_with(plan, "@keyword.definitely_missing"))
    eq({ "plain <text> stays readable" }, plan.code_blocks[1].lines)
  end)

  it("optionally wraps code by display cells while preserving syntax marks", function()
    local source = "local answer = '" .. ("宽"):rep(20) .. "'"
    local plan = make_plan("```lua\n" .. source .. "\n```", {
      usable_width = 28,
      max_width = 24,
      min_margin = 2,
      code_wrap = true,
    })
    for _, line in ipairs(plan.lines) do
      ok(width(line) <= plan.margin + plan.width, ("wrapped code is too wide: %q"):format(line))
    end
    ok(#marks_with(plan, "@string.lua") >= 2, "string capture follows wrapped continuations")
    eq({ source }, plan.code_blocks[1].lines)
  end)

  it("aligns table columns by display cells including CJK and emoji", function()
    local plan = make_plan(table.concat({
      "| Column A | B |",
      "| :- | -: |",
      "| 宽字符 | x |",
      "| emoji 🚀 | y |",
    }, "\n"))
    local rows = {}
    for _, line in ipairs(plan.lines) do
      if line:find("│", 1, true) then
        rows[#rows + 1] = line
      end
    end
    ok(#rows >= 3)
    local first_width = width(rows[1])
    for _, row in ipairs(rows) do
      eq(first_width, width(row), "every table row has identical display width:\n" .. row)
    end
  end)

  it("wraps cells of over-wide tables instead of breaking the layout", function()
    local plan = make_plan(
      table.concat({
        "| " .. ("long header words "):rep(4) .. " | " .. ("more cell text "):rep(5) .. " |",
        "| - | - |",
        "| " .. ("body content here "):rep(6) .. " | tail |",
      }, "\n"),
      { usable_width = 60, max_width = 56, min_margin = 2 }
    )
    for _, line in ipairs(plan.lines) do
      ok(width(line) <= plan.margin + plan.width, ("table line exceeds width: %q"):format(line))
    end
  end)

  it("emits deterministic vertical rhythm and heading rules", function()
    local md = "# One\n\npara\n\n## Two\n\npara two\n\n---\n\ntail"
    local plan1 = make_plan(md)
    local plan2 = make_plan(md)
    eq(plan1.lines, plan2.lines)
    eq(vim.inspect(plan1.marks), vim.inspect(plan2.marks))

    local text = table.concat(plan1.lines, "\n")
    ok(text:find("━", 1, true), "H1 divider")
    ok(text:find("─", 1, true), "H2 divider")
    -- H2 gets two blank lines above.
    local rows = {}
    for i, line in ipairs(plan1.lines) do
      if line:find("Two", 1, true) then
        rows[#rows + 1] = i
      end
    end
    local h2_row = rows[#rows]
    eq("", plan1.lines[h2_row - 1])
    eq("", plan1.lines[h2_row - 2])
  end)

  it("publishes heading and footnote anchors for navigation", function()
    local plan = make_plan(table.concat({
      "# Top",
      "",
      "Jump to the [section](#details) or note[^n].",
      "",
      "## Details",
      "",
      "[^n]: Supporting detail.",
    }, "\n"))
    eq(2, #plan.headings)
    eq("top", plan.headings[1].anchor)
    eq("details", plan.headings[2].anchor)
    eq(2, plan.headings[2].level)
    eq("Details", plan.headings[2].title)
    eq(plan.headings[2].row, plan.anchors.details.row)
    ok(plan.anchors["fn-n"], "footnote definition has an anchor")
    local text = table.concat(plan.lines, "\n")
    ok(text:find("[1]", 1, true), "footnote reference is visible")
    ok(text:find("1. Supporting detail.", 1, true), "definition is rendered cleanly")
    ok(not text:find("[^n]:", 1, true), "source footnote marker is hidden")
  end)

  it("renders semantic blocks in continued footnotes", function()
    local plan = make_plan(table.concat({
      "Text[^n].",
      "",
      "[^n]: first paragraph",
      "",
      "    second *styled* paragraph",
      "",
      "    - nested item",
    }, "\n"))
    local text = table.concat(plan.lines, "\n")
    ok(text:find("second styled paragraph", 1, true))
    ok(text:find("• nested item", 1, true))
    local emphasis = marks_with(plan, "MDEyeEmphasis")[1]
    eq("styled", mark_text(plan, emphasis))
  end)

  it("keeps colliding heading and footnote anchors navigable", function()
    local plan = make_plan("# fn-n\n\nText[^n].\n\n[^n]: note")
    ok(plan.anchors["fn-n"], "heading anchor exists")
    ok(plan.anchors["fn-n-1"], "footnote anchor is deconflicted")
    local target
    for _, mark in ipairs(marks_with(plan, "MDEyeFootnote")) do
      target = target or mark.target
    end
    eq("#fn-n-1", target)
  end)

  it("maps every rendered block back to its absolute source span", function()
    local plan = make_plan("# Title\n\nfirst paragraph\n\nsecond paragraph")
    ok(#plan.blocks >= 3)
    for _, block in ipairs(plan.blocks) do
      ok(block.row_start <= block.row_end)
      ok(block.source.start_byte <= block.source.end_byte)
    end
    -- The second paragraph starts on source row 4.
    local last = plan.blocks[#plan.blocks]
    eq(4, last.source.start_row)
    ok(plan.lines[last.row_start + 1]:find("second paragraph", 1, true))
  end)

  it("expands tabs in code blocks by an explicit policy", function()
    local plan = make_plan("```\n\tindented\n```", { tab_width = 4 })
    local code_line
    for _, line in ipairs(plan.lines) do
      if line:find("indented", 1, true) then
        code_line = line
      end
    end
    ok(code_line)
    ok(not code_line:find("\t", 1, true), "tabs expanded")
  end)
end)

describe("Mermaid layout integration", function()
  local source = "```mermaid\nflowchart LR\nA[Start] -->|next| B[Finish]\n```"

  it("renders diagrams with source spans, original copy data, and highlights", function()
    local plan = make_plan(source)
    local text = table.concat(plan.lines, "\n")
    ok(text:find("A: Start", 1, true))
    ok(text:find("next -->", 1, true))
    ok(not text:find("flowchart LR", 1, true))
    eq({ "flowchart LR", "A[Start] -->|next| B[Finish]" }, plan.code_blocks[1].lines)
    eq(0, plan.code_blocks[1].source.start_row)
    ok(#marks_with(plan, "MDEyeDiagram") > 0)
    for _, mark in ipairs(plan.marks) do
      ok(mark.start_col >= 0 and mark.end_col <= #plan.lines[mark.row + 1])
    end
  end)

  it("reflows the same parsed graph and respects nested container widths", function()
    local doc = make_doc(source)
    local original = vim.deepcopy(doc)
    for _, pane_width in ipairs({ 24, 40, 100 }) do
      local plan =
        layout.plan(doc, { usable_width = pane_width, max_width = false, min_margin = 0 })
      for _, line in ipairs(plan.lines) do
        ok(vim.fn.strdisplaywidth(line) <= pane_width, line)
      end
      local nested =
        make_plan("> " .. source:gsub("\n", "\n> "), { usable_width = pane_width, min_margin = 0 })
      for _, line in ipairs(nested.lines) do
        ok(vim.fn.strdisplaywidth(line) <= pane_width, line)
      end
    end
    eq(original, doc)
  end)

  it("keeps original source when disabled, unsupported, or too narrow", function()
    local disabled = make_plan(source, { mermaid_enabled = false })
    ok(table.concat(disabled.lines, "\n"):find("A[Start]", 1, true))
    local narrow = make_plan(source, { usable_width = 6 })
    ok(table.concat(narrow.lines, "\n"):find("flowchart LR", 1, true))
    local unsupported = make_plan("```mermaid\nflowchart LR\nA --> B\nstyle A fill:red\n```")
    local text = table.concat(unsupported.lines, "\n")
    ok(text:find("mermaid (source)", 1, true))
    ok(text:find("A --> B", 1, true))
    ok(text:find("style A fill:red", 1, true))
    eq(0, #marks_with(unsupported, "MDEyeDiagram"))
  end)
end)
