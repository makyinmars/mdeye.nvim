---Preview session lifecycle: ownership, updates, synchronization, cleanup.
---
---One session per Markdown source buffer. The session owns exactly one
---preview buffer and one owner window; the owner window alone determines
---layout width. All teardown funnels through `close()`, which is idempotent.
local config = require("mdeye.config")
local document = require("mdeye.document")
local layout = require("mdeye.layout")
local render = require("mdeye.render")

local M = {}

---@class MDEyeSession
---@field src_buf integer
---@field preview_buf integer
---@field mode "current"|"split"|"tab"
---@field owner_win integer
---@field src_win integer window that held the source when opening
---@field saved_view table|nil winsaveview() of the source (current mode)
---@field augroup integer
---@field timer uv.uv_timer_t|nil
---@field generation integer
---@field closed boolean
---@field doc MDEyeDocument|nil
---@field parsed_tick integer|nil
---@field plan MDEyeRenderPlan|nil
---@field rendered_tick integer|nil
---@field rendered_usable integer|nil
---@field last_sync_row integer|nil

---@type table<integer, MDEyeSession> keyed by source bufnr
local sessions = {}

---@type table<integer, MDEyeSession> keyed by preview bufnr
local by_preview = {}

local function notify(msg, level)
  vim.notify("mdeye: " .. msg, level or vim.log.levels.INFO)
end

---@param bufnr integer
---@return boolean
local function is_markdown(bufnr)
  return vim.bo[bufnr].filetype == "markdown"
end

-- Session registry accessors used by init/tests -----------------------------

function M.get(src_buf)
  return sessions[src_buf]
end

function M.get_by_preview(preview_buf)
  return by_preview[preview_buf]
end

function M.count()
  return vim.tbl_count(sessions)
end

-- Block mapping --------------------------------------------------------------

---Innermost block containing a preview row (fallback: nearest before).
---@param plan MDEyeRenderPlan
---@param row integer 0-based preview row
---@return MDEyeBlockMap|nil
local function block_at_row(plan, row)
  local blocks = plan.blocks
  if #blocks == 0 then
    return nil
  end
  -- Binary search: last index with row_start <= row.
  local lo, hi = 1, #blocks
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if blocks[mid].row_start <= row then
      lo = mid
    else
      hi = mid - 1
    end
  end
  if blocks[lo].row_start > row then
    return blocks[1]
  end
  -- Walk back for the innermost block containing the row.
  local best = nil
  for i = lo, 1, -1 do
    local b = blocks[i]
    if b.row_start <= row and b.row_end >= row then
      if not best or (b.row_end - b.row_start) < (best.row_end - best.row_start) then
        best = b
      end
    end
    -- Blocks are ordered by row_start; once well before the row and closed,
    -- only enclosing (larger) blocks remain, and the small ones near the row
    -- have already been visited.
    if b.row_end < row and best then
      break
    end
  end
  return best or blocks[math.min(lo, #blocks)]
end

---Innermost block containing a source byte (fallback: nearest before).
---@param plan MDEyeRenderPlan
---@param byte integer
---@return MDEyeBlockMap|nil
local function block_at_byte(plan, byte)
  local best, best_size, nearest = nil, math.huge, nil
  for _, b in ipairs(plan.blocks) do
    if b.source.start_byte <= byte then
      if b.source.end_byte > byte then
        local size = b.source.end_byte - b.source.start_byte
        if size < best_size then
          best, best_size = b, size
        end
      end
      if not nearest or b.source.start_byte >= nearest.source.start_byte then
        nearest = b
      end
    end
  end
  return best or nearest or plan.blocks[1]
end

-- Rendering ------------------------------------------------------------------

---@param session MDEyeSession
---@return integer|nil usable width when the owner window is usable
local function owner_usable_width(session)
  if not vim.api.nvim_win_is_valid(session.owner_win) then
    return nil
  end
  if vim.api.nvim_win_get_buf(session.owner_win) ~= session.preview_buf then
    return nil
  end
  return render.usable_width(session.owner_win)
end

---@param session MDEyeSession
---@return {byte: integer, cursor_byte: integer}|nil
local function capture_anchor(session)
  if not session.plan or not owner_usable_width(session) then
    return nil
  end
  local anchor
  vim.api.nvim_win_call(session.owner_win, function()
    local top = vim.fn.line("w0") - 1
    local cursor = vim.api.nvim_win_get_cursor(0)[1] - 1
    local top_block = block_at_row(session.plan, top)
    local cur_block = block_at_row(session.plan, cursor)
    anchor = {
      byte = top_block and top_block.source.start_byte or 0,
      cursor_byte = cur_block and cur_block.source.start_byte or 0,
    }
  end)
  return anchor
end

---@param session MDEyeSession
---@param anchor {byte: integer, cursor_byte: integer}|nil
local function restore_anchor(session, anchor)
  if not anchor or not session.plan or not owner_usable_width(session) then
    return
  end
  local plan = session.plan
  local top_block = block_at_byte(plan, anchor.byte)
  local cur_block = block_at_byte(plan, anchor.cursor_byte)
  local last = vim.api.nvim_buf_line_count(session.preview_buf)
  local topline = math.min((top_block and top_block.row_start or 0) + 1, last)
  local lnum = math.min((cur_block and cur_block.row_start or 0) + 1, last)
  vim.api.nvim_win_call(session.owner_win, function()
    vim.fn.winrestview({ topline = topline, lnum = math.max(lnum, topline), col = 0 })
  end)
end

---Parse, lay out, and apply in one controlled update.
---@param session MDEyeSession
---@param opts { anchor: boolean }|nil
---@return boolean ok
local function update(session, opts)
  if session.closed or not vim.api.nvim_buf_is_valid(session.src_buf) then
    return false
  end
  local usable = owner_usable_width(session)
  if not usable then
    return false
  end
  local tick = vim.api.nvim_buf_get_changedtick(session.src_buf)
  if tick == session.rendered_tick and usable == session.rendered_usable then
    return true
  end

  local doc = session.doc
  if not doc or tick ~= session.parsed_tick then
    local err
    doc, err = document.parse(session.src_buf)
    if not doc then
      notify(err or "parse failed", vim.log.levels.ERROR)
      return false
    end
    session.doc = doc
    session.parsed_tick = tick
  end

  local cfg = config.options
  local plan = layout.plan(doc, {
    usable_width = usable,
    max_width = cfg.max_width,
    min_margin = cfg.min_margin,
    code_wrap = cfg.code.wrap,
  })

  local anchor = (opts and opts.anchor) and capture_anchor(session) or nil
  render.apply(session.preview_buf, plan)
  session.plan = plan
  session.rendered_tick = tick
  session.rendered_usable = usable
  restore_anchor(session, anchor)
  return true
end

---Debounced update entry: safe to call from textlocked contexts because it
---only starts a timer; the work runs on the main loop.
---@param session MDEyeSession
local function schedule_update(session)
  if session.closed then
    return
  end
  session.generation = session.generation + 1
  local gen = session.generation
  session.timer:stop()
  session.timer:start(
    config.options.debounce_ms,
    0,
    vim.schedule_wrap(function()
      -- Stale generations must not overwrite newer ones.
      if session.closed or gen ~= session.generation then
        return
      end
      update(session, { anchor = true })
    end)
  )
end

-- Closing ---------------------------------------------------------------------

---Idempotent teardown. `restore` re-shows the source in the owner window
---(current mode) or closes the session-created window (split/tab mode).
---`wiped` marks the preview buffer as already being wiped by Neovim.
---@param session MDEyeSession
---@param opts { restore: boolean, wiped: boolean }|nil
function M.close_session(session, opts)
  if session.closed then
    return
  end
  session.closed = true
  sessions[session.src_buf] = nil
  by_preview[session.preview_buf] = nil

  if session.timer then
    session.timer:stop()
    if not session.timer:is_closing() then
      session.timer:close()
    end
    session.timer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)

  local restore = not opts or opts.restore ~= false
  local owner_valid = vim.api.nvim_win_is_valid(session.owner_win)
  local owner_shows_preview = owner_valid
    and vim.api.nvim_win_get_buf(session.owner_win) == session.preview_buf

  if restore and owner_shows_preview then
    if session.mode == "current" then
      if vim.api.nvim_buf_is_valid(session.src_buf) then
        vim.api.nvim_win_set_buf(session.owner_win, session.src_buf)
        if session.saved_view then
          vim.api.nvim_win_call(session.owner_win, function()
            vim.fn.winrestview(session.saved_view)
          end)
        end
      end
    else
      -- Closing the last window of a tab page closes the tab; closing the
      -- last window overall is refused, so fall back to showing the source.
      local ok = pcall(vim.api.nvim_win_close, session.owner_win, false)
      if not ok and vim.api.nvim_buf_is_valid(session.src_buf) then
        pcall(vim.api.nvim_win_set_buf, session.owner_win, session.src_buf)
      end
    end
  end

  -- bufhidden=wipe usually removed the buffer already; force-remove any rest,
  -- but never while Neovim is in the middle of wiping it.
  if not (opts and opts.wiped) and vim.api.nvim_buf_is_valid(session.preview_buf) then
    pcall(vim.api.nvim_buf_delete, session.preview_buf, { force = true })
  end
end

-- Navigation and links ---------------------------------------------------------

---Find a link target under a preview position.
---@param session MDEyeSession
---@param row integer 0-based
---@param col integer byte column
---@return string|nil
local function link_at(session, row, col)
  if not session.plan then
    return nil
  end
  for _, mark in ipairs(session.plan.marks) do
    if mark.target and mark.row == row and mark.start_col <= col and col < mark.end_col then
      return mark.target
    end
  end
  return nil
end

---@param session MDEyeSession
---@param row integer
---@return boolean
local function move_to_preview_row(session, row)
  if not session.plan or not owner_usable_width(session) then
    return false
  end
  local last = vim.api.nvim_buf_line_count(session.preview_buf)
  row = math.max(0, math.min(row, last - 1))
  vim.api.nvim_win_set_cursor(session.owner_win, { row + 1, 0 })
  vim.api.nvim_win_call(session.owner_win, function()
    vim.cmd("normal! zt")
  end)
  return true
end

---@param session MDEyeSession
---@param fragment string
---@return boolean
local function jump_to_anchor(session, fragment)
  if not session.plan then
    return false
  end
  local id = document.anchor_id(session.plan.anchors, fragment)
  local anchor = id and session.plan.anchors[id] or nil
  return anchor ~= nil and move_to_preview_row(session, anchor.row)
end

---@param session MDEyeSession
---@param direction "next"|"previous"
local function move_heading(session, direction)
  if not session.plan or #session.plan.headings == 0 then
    notify("document has no headings")
    return
  end
  local row = vim.api.nvim_win_get_cursor(session.owner_win)[1] - 1
  if direction == "next" then
    for _, heading in ipairs(session.plan.headings) do
      if heading.row > row then
        move_to_preview_row(session, heading.row)
        return
      end
    end
    notify("already at the last heading")
  else
    for i = #session.plan.headings, 1, -1 do
      local heading = session.plan.headings[i]
      if heading.row < row then
        move_to_preview_row(session, heading.row)
        return
      end
    end
    notify("already at the first heading")
  end
end

---@param session MDEyeSession
local function show_outline(session)
  if not session.plan or #session.plan.headings == 0 then
    notify("document has no headings")
    return
  end
  vim.ui.select(session.plan.headings, {
    prompt = "mdeye headings",
    format_item = function(heading)
      return string.rep("  ", heading.level - 1) .. heading.title
    end,
  }, function(heading)
    if heading and not session.closed then
      move_to_preview_row(session, heading.row)
    end
  end)
end

---@param plan MDEyeRenderPlan
---@param row integer
---@return MDEyeCodeBlockMap|nil
local function code_at_preview_row(plan, row)
  for _, code in ipairs(plan.code_blocks) do
    if code.row_start <= row and row <= code.row_end then
      return code
    end
  end
end

---@param plan MDEyeRenderPlan
---@param byte integer
---@return MDEyeCodeBlockMap|nil
local function code_at_source_byte(plan, byte)
  for _, code in ipairs(plan.code_blocks) do
    if code.source.start_byte <= byte and byte < code.source.end_byte then
      return code
    end
  end
end

---Copy the fenced block under the current preview/source cursor.
---@param selected MDEyeSession|nil mapping callbacks pass their own session
---@return boolean ok
function M.copy_code(selected)
  local cur_buf = vim.api.nvim_get_current_buf()
  local active = selected or by_preview[cur_buf] or sessions[cur_buf]
  if not active or active.closed or not active.plan then
    notify("no preview code block to copy")
    return false
  end

  local tick = vim.api.nvim_buf_get_changedtick(active.src_buf)
  if tick ~= active.rendered_tick and not update(active, { anchor = true }) then
    notify("could not refresh fenced code before copying", vim.log.levels.ERROR)
    return false
  end

  local code
  if cur_buf == active.preview_buf then
    code = code_at_preview_row(active.plan, vim.api.nvim_win_get_cursor(0)[1] - 1)
  elseif cur_buf == active.src_buf then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local byte = vim.api.nvim_buf_get_offset(active.src_buf, cursor[1] - 1) + cursor[2]
    code = code_at_source_byte(active.plan, byte)
  end
  if not code then
    notify("cursor is not in a fenced code block")
    return false
  end

  local text = table.concat(code.lines, "\n")
  if #code.lines > 0 then
    text = text .. "\n"
  end
  vim.fn.setreg('"', text)
  if vim.fn.has("clipboard") == 1 then
    pcall(vim.fn.setreg, "+", text)
  end
  notify(("copied %d code line%s"):format(#code.lines, #code.lines == 1 and "" or "s"))
  return true
end

---@param doc MDEyeDocument
---@param fragment string
---@return integer|nil
local function document_anchor_row(doc, fragment)
  local id = document.anchor_id(doc.anchors, fragment)
  local span = id and doc.anchors[id] or nil
  return span and span.start_row or nil
end

---Resolve and open a link target. Relative targets resolve against the
---source buffer's directory at interaction time, never against Neovim's cwd.
---@param session MDEyeSession
---@param target string
local function open_link(session, target)
  target = target:gsub("^<", ""):gsub(">$", "")
  if target:match("^https?://") or target:match("^mailto:") then
    vim.ui.open(target)
    return
  end
  if target:match("^file://") then
    target = target:gsub("^file://", "")
  end

  local path, fragment = target:match("^([^#]*)#(.*)$")
  path = path or target
  if path == "" then
    if not jump_to_anchor(session, fragment or "") then
      notify("anchor not found: #" .. (fragment or ""), vim.log.levels.WARN)
    end
    return
  end

  local src_name = vim.api.nvim_buf_get_name(session.src_buf)
  if not path:match("^/") then
    local base = src_name ~= "" and vim.fs.dirname(src_name) or vim.fn.getcwd()
    path = vim.fs.normalize(base .. "/" .. path)
  else
    path = vim.fs.normalize(path)
  end
  if
    fragment
    and src_name ~= ""
    and vim.fs.normalize(vim.fn.fnamemodify(src_name, ":p"))
      == vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  then
    if not jump_to_anchor(session, fragment) then
      notify("anchor not found: #" .. fragment, vim.log.levels.WARN)
    end
    return
  end

  -- Prefer the source window in split mode so the preview stays open.
  local target_win
  if session.mode ~= "current" then
    if vim.api.nvim_win_is_valid(session.src_win) then
      target_win = session.src_win
    else
      local wins = vim.fn.win_findbuf(session.src_buf)
      target_win = wins[1]
    end
  end
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))

  if fragment then
    local doc = document.parse(vim.api.nvim_get_current_buf())
    local row = doc and document_anchor_row(doc, fragment)
    if row then
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      vim.cmd("normal! ^")
    else
      notify("anchor not found: #" .. fragment, vim.log.levels.WARN)
    end
  end
end

---Return to the source location for the block at the preview cursor.
---@param session MDEyeSession
local function jump_to_source(session)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local block = session.plan and block_at_row(session.plan, cursor[1] - 1)
  local lnum = (block and block.source.start_row or 0) + 1

  local function set_source_cursor(win)
    vim.api.nvim_win_call(win, function()
      -- One intentional jumplist entry for the reading jump.
      vim.cmd("normal! m'")
      local line = vim.api.nvim_buf_get_lines(session.src_buf, lnum - 1, lnum, false)[1] or ""
      local indent = line:match("^%s*")
      vim.api.nvim_win_set_cursor(0, { lnum, #indent })
    end)
  end

  if session.mode == "current" then
    local owner = session.owner_win
    M.close_session(session, { restore = true })
    if vim.api.nvim_win_is_valid(owner) and vim.api.nvim_win_get_buf(owner) == session.src_buf then
      set_source_cursor(owner)
      vim.api.nvim_set_current_win(owner)
    end
    return
  end

  local win
  if
    vim.api.nvim_win_is_valid(session.src_win)
    and vim.api.nvim_win_get_buf(session.src_win) == session.src_buf
  then
    win = session.src_win
  else
    win = vim.fn.win_findbuf(session.src_buf)[1]
  end
  if not win then
    -- No visible source window: show the source in place of the preview.
    vim.api.nvim_win_set_buf(session.owner_win, session.src_buf)
    win = session.owner_win
  end
  set_source_cursor(win)
  vim.api.nvim_set_current_win(win)
end

-- Opening ----------------------------------------------------------------------

---@param session MDEyeSession
local function install_mappings(session)
  local buf = session.preview_buf
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", function()
    M.close_session(session, { restore = true })
  end, vim.tbl_extend("force", opts, { desc = "mdeye: close preview" }))
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local target = link_at(session, cursor[1] - 1, cursor[2])
    if target then
      open_link(session, target)
    else
      jump_to_source(session)
    end
  end, vim.tbl_extend("force", opts, { desc = "mdeye: open link or jump to source" }))
  vim.keymap.set("n", "gx", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local target = link_at(session, cursor[1] - 1, cursor[2])
    if target then
      open_link(session, target)
    else
      notify("no link under cursor")
    end
  end, vim.tbl_extend("force", opts, { desc = "mdeye: open link" }))
  vim.keymap.set("n", "]]", function()
    move_heading(session, "next")
  end, vim.tbl_extend("force", opts, { desc = "mdeye: next heading" }))
  vim.keymap.set("n", "[[", function()
    move_heading(session, "previous")
  end, vim.tbl_extend("force", opts, { desc = "mdeye: previous heading" }))
  vim.keymap.set("n", "gO", function()
    show_outline(session)
  end, vim.tbl_extend("force", opts, { desc = "mdeye: heading outline" }))
  vim.keymap.set("n", "yc", function()
    M.copy_code(session)
  end, vim.tbl_extend("force", opts, { desc = "mdeye: copy fenced code" }))
end

---@param session MDEyeSession
local function install_autocmds(session)
  local group = session.augroup

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = session.preview_buf,
    callback = function()
      -- Any switch away can wipe the preview (bufhidden=wipe); never steal
      -- the window back from whatever replaced it.
      M.close_session(session, { restore = false, wiped = true })
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = session.src_buf,
    callback = function()
      M.close_session(session, { restore = session.mode ~= "current" })
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(session.owner_win),
    callback = function()
      vim.schedule(function()
        if session.closed then
          return
        end
        -- Adopt one remaining window still showing the preview, else end.
        local wins = vim.fn.win_findbuf(session.preview_buf)
        if wins[1] then
          session.owner_win = wins[1]
          session.rendered_usable = nil
          update(session, { anchor = true })
        else
          M.close_session(session, { restore = false })
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if session.closed then
        return
      end
      local usable = owner_usable_width(session)
      if usable and usable ~= session.rendered_usable then
        schedule_update(session)
      end
    end,
  })

  if session.mode == "split" then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = session.src_buf,
      callback = function()
        M.sync_from_source(session)
      end,
    })
  end
end

---@param session MDEyeSession
local function attach_source(session)
  vim.api.nvim_buf_attach(session.src_buf, false, {
    on_lines = function()
      -- Runs under textlock: only mark work and start the debounce timer.
      if session.closed then
        return true -- detach
      end
      schedule_update(session)
    end,
    on_reload = function()
      if session.closed then
        return true
      end
      schedule_update(session)
    end,
    on_detach = function()
      if not session.closed then
        vim.schedule(function()
          M.close_session(session, { restore = false })
        end)
      end
    end,
  })
end

---Scroll the preview to the block containing the source cursor (split mode).
---@param session MDEyeSession
function M.sync_from_source(session)
  if session.closed or not session.plan then
    return
  end
  if not owner_usable_width(session) then
    return
  end
  local src_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(src_win) ~= session.src_buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(src_win)
  local byte = vim.api.nvim_buf_get_offset(session.src_buf, cursor[1] - 1) + cursor[2]
  local block = block_at_byte(session.plan, byte)
  if not block or block.row_start == session.last_sync_row then
    return
  end
  session.last_sync_row = block.row_start
  local last = vim.api.nvim_buf_line_count(session.preview_buf)
  pcall(vim.api.nvim_win_set_cursor, session.owner_win, { math.min(block.row_start + 1, last), 0 })
end

---@param mode "current"|"split"|"tab"
---@param preview_buf integer
---@return integer|nil owner_win
local function place_window(mode, preview_buf)
  if mode == "current" then
    local win = vim.api.nvim_get_current_win()
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, preview_buf)
    if not ok then
      notify(
        "cannot replace the current window (is 'hidden' disabled with unsaved changes?); "
          .. "use :MDEye split instead. "
          .. (err or ""),
        vim.log.levels.ERROR
      )
      return nil
    end
    return win
  elseif mode == "split" then
    local win = vim.api.nvim_open_win(preview_buf, true, {
      split = "right",
      win = vim.api.nvim_get_current_win(),
    })
    return win
  else -- tab
    vim.cmd.tabnew()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, preview_buf)
    return win
  end
end

---@param src_buf integer
---@return string
local function preview_name(src_buf)
  local name = vim.api.nvim_buf_get_name(src_buf)
  local display = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  return "mdeye://" .. display
end

---Open (or focus) a preview for a Markdown source buffer.
---@param opts { mode: "current"|"split"|"tab" }|nil
---@return boolean ok
function M.open(opts)
  opts = opts or {}
  local mode = opts.mode or config.options.open

  local cur_buf = vim.api.nvim_get_current_buf()

  -- Invoked from inside a preview: focus semantics are a no-op.
  local existing_preview = by_preview[cur_buf]
  if existing_preview then
    return true
  end

  local src_buf = cur_buf
  if not is_markdown(src_buf) then
    notify("current buffer is not a Markdown buffer", vim.log.levels.WARN)
    return false
  end

  local existing = sessions[src_buf]
  if existing and not existing.closed then
    -- Same source again: focus or move the existing preview, never duplicate.
    if vim.api.nvim_win_is_valid(existing.owner_win) then
      if existing.mode == mode then
        vim.api.nvim_set_current_win(existing.owner_win)
        return true
      end
      M.close_session(existing, { restore = true })
    else
      M.close_session(existing, { restore = false })
    end
  end

  config.ensure_highlights()

  -- Parse and lay out *before* touching any window, so a failure leaves the
  -- source view untouched and no empty preview flashes.
  local doc, err = document.parse(src_buf)
  if not doc then
    notify(err or "unable to parse buffer", vim.log.levels.ERROR)
    return false
  end

  local src_win = vim.api.nvim_get_current_win()
  local saved_view
  vim.api.nvim_win_call(src_win, function()
    saved_view = vim.fn.winsaveview()
  end)

  local preview_buf = vim.api.nvim_create_buf(false, true)
  render.setup_buffer(preview_buf)
  pcall(vim.api.nvim_buf_set_name, preview_buf, preview_name(src_buf))

  local owner_win = place_window(mode, preview_buf)
  if not owner_win then
    pcall(vim.api.nvim_buf_delete, preview_buf, { force = true })
    return false
  end
  render.setup_window(owner_win)

  ---@type MDEyeSession
  local session = {
    src_buf = src_buf,
    preview_buf = preview_buf,
    mode = mode,
    owner_win = owner_win,
    src_win = src_win,
    saved_view = saved_view,
    augroup = vim.api.nvim_create_augroup("MDEyeSession" .. preview_buf, { clear = true }),
    timer = vim.uv.new_timer(),
    generation = 0,
    closed = false,
    doc = doc,
    parsed_tick = vim.api.nvim_buf_get_changedtick(src_buf),
  }
  sessions[src_buf] = session
  by_preview[preview_buf] = session

  install_mappings(session)
  install_autocmds(session)
  attach_source(session)

  if not update(session) then
    M.close_session(session, { restore = true })
    return false
  end
  vim.api.nvim_win_call(owner_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
  end)
  return true
end

---Close the preview related to the current buffer (source or preview).
---@return boolean ok
function M.close()
  local cur_buf = vim.api.nvim_get_current_buf()
  local session = by_preview[cur_buf] or sessions[cur_buf]
  if not session then
    notify("no preview to close")
    return false
  end
  M.close_session(session, { restore = true })
  return true
end

---@param opts { mode: "current"|"split"|"tab" }|nil
function M.toggle(opts)
  local cur_buf = vim.api.nvim_get_current_buf()
  local session = by_preview[cur_buf] or sessions[cur_buf]
  if session and not session.closed then
    M.close_session(session, { restore = true })
    return true
  end
  return M.open(opts)
end

return M
