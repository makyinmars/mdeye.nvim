-- Explicitly regenerate terminal layouts for inspection before committing.
-- Run: nvim --headless -l tests/spike/update_snapshots.lua
local root = dofile("tests/minimal_init.lua")
local document, layout = require("mdeye.document"), require("mdeye.layout")
vim.fn.mkdir(root .. "/tests/fixtures/snapshots", "p")
for _, case in ipairs(dofile(root .. "/tests/snapshot_cases.lua")) do
  local buf = vim.fn.bufadd(root .. "/tests/fixtures/" .. case.fixture)
  vim.fn.bufload(buf)
  local plan = layout.plan(
    assert(document.parse(buf)),
    { usable_width = case.width, max_width = 88, min_margin = 3 }
  )
  local lines = {}
  for _, line in ipairs(plan.lines) do
    lines[#lines + 1] = line:gsub("%s+$", "")
  end
  local path = root .. "/tests/fixtures/snapshots/" .. case.name .. ".txt"
  vim.fn.writefile(lines, path)
  print(path)
end
