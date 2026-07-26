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

    -- narrow windows shrink margins before content becomes unusable
    local w3, m3 = layout.geometry(24, 88, 3)
    eq(20, w3)
    eq(2, m3)

    local w4 = layout.geometry(12, 88, 3)
    eq(12, w4)
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
