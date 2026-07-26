---Public interface: setup/open/close/toggle. Everything else is internal.
local M = {}

---@param opts table|nil see :help mdeye-configuration
function M.setup(opts)
  local err = require("mdeye.config").setup(opts)
  if err then
    vim.notify("mdeye: invalid configuration: " .. err, vim.log.levels.ERROR)
    return
  end
  require("mdeye.config").ensure_highlights()
end

---@param opts { mode: "current"|"split"|"tab" }|nil
---@return boolean ok
function M.open(opts)
  return require("mdeye.session").open(opts)
end

---@return boolean ok
function M.close()
  return require("mdeye.session").close()
end

---@param opts { mode: "current"|"split"|"tab" }|nil
---@return boolean ok
function M.toggle(opts)
  return require("mdeye.session").toggle(opts)
end

---:MDEye [current|split|tab|close] dispatcher.
---@param cmd { args: string }
function M._command(cmd)
  local arg = vim.trim(cmd.args or "")
  if arg == "" then
    M.toggle()
  elseif arg == "close" then
    M.close()
  elseif arg == "current" or arg == "split" or arg == "tab" then
    M.open({ mode = arg })
  else
    vim.notify("mdeye: unknown argument: " .. arg, vim.log.levels.ERROR)
  end
end

return M
