local document, layout = require("mdeye.document"), require("mdeye.layout")
local root = vim.g.mdeye_test_root

describe("terminal layout snapshots", function()
  for _, case in ipairs(dofile(root .. "/tests/snapshot_cases.lua")) do
    it("matches the reviewed " .. case.width .. "-column fixture", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.fn.readfile(root .. "/tests/fixtures/" .. case.fixture)
      )
      local plan = layout.plan(
        assert(document.parse(buf)),
        { usable_width = case.width, max_width = 88, min_margin = 3 }
      )
      local lines = {}
      for _, line in ipairs(plan.lines) do
        lines[#lines + 1] = line:gsub("%s+$", "")
        ok(vim.fn.strdisplaywidth(line) <= case.width, line)
      end
      eq(vim.fn.readfile(root .. "/tests/fixtures/snapshots/" .. case.name .. ".txt"), lines)
      for _, mark in ipairs(plan.marks) do
        ok(mark.start_col >= 0 and mark.end_col <= #plan.lines[mark.row + 1])
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end
end)
