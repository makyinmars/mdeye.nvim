-- Native Mermaid benchmark: 100 nodes and 100 edges, one warmup + five measured runs.
-- Run: nvim --headless -l tests/bench/mermaid.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local document, layout, render =
  require("mdeye.document"), require("mdeye.layout"), require("mdeye.render")
local src, preview = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
local lines = { "```mermaid", "flowchart LR" }
for i = 1, 100 do
  lines[#lines + 1] = ("N%d[Node %d] -->|next| N%d"):format(i, i, i % 100 + 1)
end
lines[#lines + 1] = "```"
vim.api.nvim_buf_set_lines(src, 0, -1, false, lines)
local parse_times, layout_times, render_times = {}, {}, {}
local last
for i = 1, 6 do
  local start = vim.uv.hrtime()
  local doc = assert(document.parse(src))
  local parsed = vim.uv.hrtime()
  last = layout.plan(doc, { usable_width = 100, max_width = 88, min_margin = 3 })
  local planned = vim.uv.hrtime()
  render.apply(preview, last)
  local done = vim.uv.hrtime()
  if i > 1 then
    parse_times[#parse_times + 1] = (parsed - start) / 1e6
    layout_times[#layout_times + 1] = (planned - parsed) / 1e6
    render_times[#render_times + 1] = (done - planned) / 1e6
  end
end
for _, values in ipairs({ parse_times, layout_times, render_times }) do
  table.sort(values)
end
print(
  ("100-node/100-edge cycle: %d preview lines; parse %.2f ms, layout %.2f ms, render %.2f ms"):format(
    #last.lines,
    parse_times[3],
    layout_times[3],
    render_times[3]
  )
)
