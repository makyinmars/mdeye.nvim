-- Dependency-free spec runner.
-- Run all specs:   nvim --headless -l tests/run.lua
-- Run one spec:    nvim --headless -l tests/run.lua tests/layout_spec.lua
local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
local tests_dir = vim.fs.dirname(this)
local root = dofile(tests_dir .. "/minimal_init.lua")

local results = { pass = 0, fail = 0, failures = {} }
local current_group = ""

function _G.describe(name, fn)
  local prev = current_group
  current_group = current_group == "" and name or (current_group .. " › " .. name)
  fn()
  current_group = prev
end

function _G.it(name, fn)
  local label = current_group .. " › " .. name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    io.write("ok   " .. label .. "\n")
  else
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = { label = label, err = err }
    io.write("FAIL " .. label .. "\n")
  end
end

function _G.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected:\n%s\ngot:\n%s"):format(
        msg and (msg .. "\n") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function _G.ok(value, msg)
  if not value then
    error(msg or "expected value to be truthy", 2)
  end
end

local specs = {}
if _G.arg and _G.arg[1] then
  specs[#specs + 1] = vim.fs.normalize(vim.fn.fnamemodify(_G.arg[1], ":p"))
else
  for name, kind in vim.fs.dir(tests_dir) do
    if kind == "file" and name:match("_spec%.lua$") then
      specs[#specs + 1] = tests_dir .. "/" .. name
    end
  end
  table.sort(specs)
end

vim.g.mdeye_test_root = root
for _, spec in ipairs(specs) do
  io.write("== " .. vim.fn.fnamemodify(spec, ":t") .. "\n")
  local ok, err = xpcall(dofile, debug.traceback, spec)
  if not ok then
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = { label = spec, err = err }
  end
end

io.write(("\n%d passed, %d failed\n"):format(results.pass, results.fail))
for _, failure in ipairs(results.failures) do
  io.write("\n--- " .. failure.label .. "\n" .. failure.err .. "\n")
end
os.exit(results.fail == 0 and 0 or 1)
