---10,000-line editing benchmark: compare complete and incremental buffer updates.
---Run: nvim --headless -l tests/bench/updates.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local document, layout, render =
  require("mdeye.document"), require("mdeye.layout"), require("mdeye.render")
local lines = {}
for i = 1, 2500 do
  vim.list_extend(lines, {
    "## Section " .. i,
    "",
    "A paragraph with **bold** text and a [link](https://example.com).",
    "",
  })
end
local src, full, partial =
  vim.api.nvim_create_buf(false, true),
  vim.api.nvim_create_buf(false, true),
  vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(src, 0, -1, false, lines)
local opts = { usable_width = 100, max_width = 88, min_margin = 3 }
local previous = layout.plan(assert(document.parse(src)), opts)
render.apply(partial, previous)
local times = { parse = {}, layout = {}, full = {}, partial = {}, total = {} }
local stats
local function measure(fn)
  local start = vim.uv.hrtime()
  local value = fn()
  return (vim.uv.hrtime() - start) / 1e6, value
end
for iteration = 1, 6 do
  vim.api.nvim_buf_set_lines(
    src,
    5002,
    5003,
    false,
    { "Edited paragraph " .. iteration .. " with **bold** text and a [link](https://example.com)." }
  )
  local parse_ms, doc = measure(function()
    return assert(document.parse(src))
  end)
  local layout_ms, plan = measure(function()
    return layout.plan(doc, opts)
  end)
  local full_ms = measure(function()
    render.apply(full, plan)
  end)
  local partial_ms
  partial_ms, stats = measure(function()
    return render.apply(partial, plan, previous)
  end)
  assert(
    vim.deep_equal(
      vim.api.nvim_buf_get_lines(full, 0, -1, false),
      vim.api.nvim_buf_get_lines(partial, 0, -1, false)
    )
  )
  if iteration > 1 then
    for key, value in pairs({
      parse = parse_ms,
      layout = layout_ms,
      full = full_ms,
      partial = partial_ms,
      total = parse_ms + layout_ms + partial_ms,
    }) do
      times[key][#times[key] + 1] = value
    end
  end
  previous = plan
end
print(("%d source lines; %d preview lines; one paragraph edited"):format(#lines, #previous.lines))
for _, key in ipairs({ "parse", "layout", "full", "partial", "total" }) do
  table.sort(times[key])
  print(("%-7s median %.2f ms"):format(key, times[key][3]))
end
print(("incremental update: %d lines replaced, %d marks created"):format(stats.lines, stats.marks))
