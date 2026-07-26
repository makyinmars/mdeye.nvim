---Apply a render plan to a preview buffer and isolate a preview window.
local M = {}

M.ns = vim.api.nvim_create_namespace("mdeye")

local function is_absolute_url(target)
  return target:match("^https?://") ~= nil
    or target:match("^file://") ~= nil
    or target:match("^mailto:") ~= nil
end

---Replace the preview buffer's contents and extmarks in one controlled update.
---@param bufnr integer
---@param plan MDEyeRenderPlan
function M.apply(bufnr, plan)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, plan.lines)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for _, mark in ipairs(plan.marks) do
    local opts = {
      end_col = mark.end_col,
      hl_group = mark.hl,
      priority = mark.priority,
    }
    if mark.target and is_absolute_url(mark.target) then
      opts.url = mark.target
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, mark.row, mark.start_col, opts)
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
end

---Buffer options that keep the generated view inert and isolated.
---@param bufnr integer
function M.setup_buffer(bufnr)
  local bo = vim.bo[bufnr]
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.undolevels = -1
  -- Not "markdown": Markdown linters, LSP, and formatting autocmds must not
  -- attach to generated lines.
  bo.filetype = "mdeye"
end

---Window-local presentation for the preview: no editor chrome, no second
---wrapping pass (mdeye generates real wrapped lines).
---@param win integer
function M.setup_window(win)
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.foldenable = false
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.list = false
  wo.spell = false
  wo.wrap = false
  wo.linebreak = false
  wo.breakindent = false
  wo.conceallevel = 0
  wo.sidescrolloff = 0
  wo.winbar = ""
end

---Usable text width of a window (excludes any gutter columns).
---@param win integer
---@return integer
function M.usable_width(win)
  local width = vim.api.nvim_win_get_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return width - (info and info.textoff or 0)
end

return M
