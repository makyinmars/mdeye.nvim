-- Minimal test environment: only this plugin on the runtimepath.
local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.o.hidden = true
vim.o.more = false
-- Under `nvim -l` the plugin-load phase already ran before this file.
dofile(root .. "/plugin/mdeye.lua")
return root
