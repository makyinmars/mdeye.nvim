---Benchmark: initial render of a representative 1,000-line document.
---
---Run with:
---  nvim --headless -l tests/bench/bench.lua
---
---Measures the three pipeline stages (parse, layout, render) plus the full
---end-to-end open path, and prints median/worst times over several runs.
---The plan's Milestone 4 target: initial render within 100 ms.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
vim.opt.runtimepath:prepend(root)

local document = require("mdeye.document")
local layout = require("mdeye.layout")
local render = require("mdeye.render")

local TARGET_LINES = tonumber(_G.arg and _G.arg[1]) or 990

-- Representative fixture: prose-heavy with all required constructs mixed in.
local function generate_fixture()
  local lines = { "# Benchmark document", "" }
  local para = "The quick brown fox jumps over the lazy dog while *emphasis*, "
    .. "**strong text**, `inline code`, and [links](https://example.com) keep "
    .. "the inline parser honest across wrapped source lines that continue"
  local i = 0
  while #lines < TARGET_LINES do
    i = i + 1
    lines[#lines + 1] = ("## Section %d"):format(i)
    lines[#lines + 1] = ""
    lines[#lines + 1] = para
    lines[#lines + 1] = "onto the next physical line without ending the paragraph."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "- first item with a bit of prose"
    lines[#lines + 1] = "  - nested item with `code` and CJK 漢字テスト"
    lines[#lines + 1] = "- [x] a completed task"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "> A block quote that also wraps across physical"
    lines[#lines + 1] = "> source lines with **strong** content inside."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```lua"
    lines[#lines + 1] = 'local x = "code line ' .. i .. '"'
    lines[#lines + 1] = "print(x)"
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "| Column A | Column B | Column C |"
    lines[#lines + 1] = "| :------- | :------: | -------: |"
    lines[#lines + 1] = "| left     | center   | right    |"
    lines[#lines + 1] = ""
  end
  return lines
end

local lines = generate_fixture()
print(("fixture: %d lines"):format(#lines))

local src = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(src, 0, -1, false, lines)
vim.bo[src].filetype = "markdown"

local preview = vim.api.nvim_create_buf(false, true)
render.setup_buffer(preview)

local USABLE = 100

local function time_ms(fn)
  local t0 = vim.uv.hrtime()
  local result = fn()
  return (vim.uv.hrtime() - t0) / 1e6, result
end

local RUNS = 5
local stats = { parse = {}, layout = {}, render = {}, total = {} }

for _ = 1, RUNS do
  -- Force a reparse each run: document.parse reads the live buffer.
  local parse_ms, doc = time_ms(function()
    local d, err = document.parse(src)
    assert(d, err)
    return d
  end)
  local layout_ms, plan = time_ms(function()
    return layout.plan(doc, { usable_width = USABLE, max_width = 88, min_margin = 3 })
  end)
  local render_ms = time_ms(function()
    render.apply(preview, plan)
  end)
  stats.parse[#stats.parse + 1] = parse_ms
  stats.layout[#stats.layout + 1] = layout_ms
  stats.render[#stats.render + 1] = render_ms
  stats.total[#stats.total + 1] = parse_ms + layout_ms + render_ms
end

local function median(t)
  local sorted = vim.deepcopy(t)
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)]
end

local function worst(t)
  local m = 0
  for _, v in ipairs(t) do
    m = math.max(m, v)
  end
  return m
end

print(("preview: %d generated lines"):format(vim.api.nvim_buf_line_count(preview)))
for _, stage in ipairs({ "parse", "layout", "render", "total" }) do
  print(
    ("%-7s median %7.2f ms   worst %7.2f ms"):format(
      stage,
      median(stats[stage]),
      worst(stats[stage])
    )
  )
end

-- The 100 ms Milestone 4 target applies to the 1,000-line document; larger
-- runs are informational data points.
if TARGET_LINES > 1000 then
  return
end
local target = 100
if median(stats.total) <= target then
  print(("PASS: median initial render %.2f ms <= %d ms target"):format(median(stats.total), target))
else
  print(("FAIL: median initial render %.2f ms > %d ms target"):format(median(stats.total), target))
  os.exit(1)
end
