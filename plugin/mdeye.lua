-- Command registration only; all behavior lives in lua/mdeye/.
if vim.g.loaded_mdeye then
  return
end
vim.g.loaded_mdeye = true

vim.api.nvim_create_user_command("MDEye", function(cmd)
  require("mdeye")._command(cmd)
end, {
  nargs = "?",
  complete = function()
    return { "current", "split", "tab", "close" }
  end,
  desc = "Toggle or control the mdeye Markdown document view",
})
