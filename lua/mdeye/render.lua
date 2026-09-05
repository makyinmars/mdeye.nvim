---Apply a render plan to a preview buffer and isolate a preview window.
local M = {}

M.ns = vim.api.nvim_create_namespace("mdeye")

local function is_absolute_url(target)
  return target:match("^https?://") ~= nil
    or target:match("^file://") ~= nil
    or target:match("^mailto:") ~= nil
end

local function row_marks(plan)
  local rows = {}
  for _, mark in ipairs(plan and plan.marks or {}) do
    local row = rows[mark.row + 1] or {}
    rows[mark.row + 1] = row
    row[#row + 1] = { mark.start_col, mark.end_col, mark.hl, mark.priority, mark.target }
  end
  return rows
end

---Replace only the differing range, retaining unchanged extmarks and their IDs.
---@param bufnr integer
---@param plan MDEyeRenderPlan
---@param previous MDEyeRenderPlan|nil omit for a complete refresh
---@return table stats changed line/mark counts for performance checks
function M.apply(bufnr, plan, previous)
  local first, old_last, new_last =
    0, previous and #previous.lines or vim.api.nvim_buf_line_count(bufnr), #plan.lines
  local old_marks, new_marks = row_marks(previous), row_marks(plan)
  local function same(old_row, new_row)
    return previous.lines[old_row] == plan.lines[new_row]
      and vim.deep_equal(old_marks[old_row], new_marks[new_row])
  end
  if previous then
    while first < math.min(old_last, new_last) and same(first + 1, first + 1) do
      first = first + 1
    end
    while old_last > first and new_last > first and same(old_last, new_last) do
      old_last, new_last = old_last - 1, new_last - 1
    end
  end
  local stats = { lines = 0, marks = 0 }
  if first == old_last and first == new_last then
    return stats
  end
  local replace = not previous or old_last ~= new_last
  if not replace then
    for i = first + 1, new_last do
      if previous.lines[i] ~= plan.lines[i] then
        replace = true
        break
      end
    end
  end
  if old_last > first then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, first, old_last)
  end
  vim.bo[bufnr].modifiable = true
  if replace then
    vim.api.nvim_buf_set_lines(
      bufnr,
      first,
      old_last,
      false,
      vim.list_slice(plan.lines, first + 1, new_last)
    )
    stats.lines = new_last - first
  end
  for row = first + 1, new_last do
    for _, mark in ipairs(new_marks[row] or {}) do
      local opts = {
        end_col = mark[2],
        hl_group = mark[3],
        priority = mark[4],
        right_gravity = true,
        end_right_gravity = true,
      }
      if mark[5] and is_absolute_url(mark[5]) then
        opts.url = mark[5]
      end
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, row - 1, mark[1], opts)
      stats.marks = stats.marks + 1
    end
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  return stats
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
  wo.foldenable = true
  wo.foldmethod = "manual"
  wo.foldlevel = 99
  wo.foldminlines = 0
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
