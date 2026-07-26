-- Pipeline smoke check: parse the fixture and print the laid-out lines.
-- Run: nvim --headless -l tests/spike/render_demo.lua [usable_width]
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local usable = tonumber(_G.arg and _G.arg[1]) or 100

local bufnr = vim.fn.bufadd("tests/fixtures/comprehensive.md")
vim.fn.bufload(bufnr)

local document = require("mdeye.document")
local layout = require("mdeye.layout")

local doc, err = document.parse(bufnr)
assert(doc, err)

local plan = layout.plan(doc, { usable_width = usable, max_width = 88, min_margin = 3 })
io.write(
  ("width=%d margin=%d lines=%d marks=%d blocks=%d\n"):format(
    plan.width,
    plan.margin,
    #plan.lines,
    #plan.marks,
    #plan.blocks
  )
)
io.write(("┈"):rep(usable) .. "\n")
for _, line in ipairs(plan.lines) do
  io.write(line .. "\n")
end
