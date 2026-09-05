local render = require("mdeye.render")
local function plan(lines, highlights)
  local result = { lines = lines, marks = {} }
  for i, line in ipairs(lines) do
    if #line > 0 then
      result.marks[#result.marks + 1] = {
        row = i - 1,
        start_col = 0,
        end_col = #line,
        hl = highlights and highlights[i] or "Normal",
        priority = 100,
      }
    end
  end
  return result
end
local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
end

describe("incremental rendering", function()
  it("retains unchanged extmarks across insertion and deletion", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local a = plan({ "first", "last" })
    render.apply(buf, a)
    local before = marks(buf)
    local b = plan({ "first", "new", "last" })
    eq({ lines = 1, marks = 1 }, render.apply(buf, b, a))
    local after = marks(buf)
    eq(before[1][1], after[1][1])
    eq(before[2][1], after[3][1])
    eq(2, after[3][2])
    eq(2, after[3][4].end_row)
    eq({ lines = 0, marks = 0 }, render.apply(buf, a, b))
    eq(a.lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq(before, marks(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("updates highlight-only changes without editing the buffer text", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local a, b = plan({ "same" }), plan({ "same" }, { "Comment" })
    render.apply(buf, a)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    eq({ lines = 0, marks = 1 }, render.apply(buf, b, a))
    eq(tick, vim.api.nvim_buf_get_changedtick(buf))
    eq("Comment", marks(buf)[1][4].hl_group)
    eq({ lines = 0, marks = 0 }, render.apply(buf, b, b))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("matches a full render after edits with Unicode, blank lines, and URL marks", function()
    local incremental, full =
      vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
    local previous
    for _, lines in ipairs({
      { "日本語", "", "last" },
      { "new", "日本語", "", "last" },
      { "new", "café", "last" },
      { "" },
      { "again" },
    }) do
      local next_plan = plan(lines)
      if next_plan.marks[1] then
        next_plan.marks[1].target = "https://example.com"
      end
      render.apply(incremental, next_plan, previous)
      render.apply(full, next_plan)
      eq(
        vim.api.nvim_buf_get_lines(full, 0, -1, false),
        vim.api.nvim_buf_get_lines(incremental, 0, -1, false)
      )
      local a, b = marks(incremental), marks(full)
      for _, mark in ipairs(a) do
        mark[1] = 0
      end
      for _, mark in ipairs(b) do
        mark[1] = 0
      end
      eq(b, a)
      previous = next_plan
    end
    vim.api.nvim_buf_delete(incremental, { force = true })
    vim.api.nvim_buf_delete(full, { force = true })
  end)
end)
