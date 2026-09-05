---Reading anchors and native folds, owned by a preview session.
local M = {}
local ns = vim.api.nvim_create_namespace("mdeye-source-anchors")

local function block_at(plan, row)
  local best
  for _, block in ipairs(plan.blocks) do
    if block.row_start <= row and row <= block.row_end then
      if not best or block.row_end - block.row_start < best.row_end - best.row_start then
        best = block
      end
    end
  end
  return best
end

local function tracked_byte(session, block)
  local id = session.source_marks and session.source_marks[block.source.start_byte]
  local pos = id and vim.api.nvim_buf_get_extmark_by_id(session.src_buf, ns, id, {}) or {}
  if #pos == 2 then
    return vim.api.nvim_buf_get_offset(session.src_buf, pos[1]) + pos[2]
  end
  return block.source.start_byte
end

local function content(plan, row)
  return (plan.text and plan.text[row + 1] or plan.lines[row + 1] or ""):gsub("%s", "")
end

local function position(session, row, col)
  local plan = session.plan
  local block = block_at(plan, row)
  if not block then
    return { row = row, col = col }
  end
  local offset = 0
  for r = block.row_start, row - 1 do
    offset = offset + #content(plan, r)
  end
  return {
    byte = tracked_byte(session, block),
    offset = offset,
    excerpt = content(plan, row):sub(1, 48),
    -- Diagram rows carry semantic identities independent of box geometry.
    key = plan.row_keys and plan.row_keys[row + 1],
    col = col,
    row = row,
  }
end

---Capture view and fold choices before replacing a render plan.
---@param session MDEyeSession
---@return table|nil
function M.capture(session)
  if not session.plan then
    return nil
  end
  return vim.api.nvim_win_call(session.owner_win, function()
    local view = vim.fn.winsaveview()
    local closed = {}
    for _, fold in ipairs(session.folds or {}) do
      local outer = vim.fn.foldclosed(fold.first + 1)
      local is_closed = outer == fold.first + 1
      if outer ~= -1 and outer < fold.first + 1 then
        is_closed = fold.closed -- retain invisible nested choices
      end
      if is_closed then
        closed[fold.kind .. ":" .. tracked_byte(session, fold)] = true
      end
    end
    return {
      top = position(session, view.topline - 1, 0),
      cursor = position(session, view.lnum - 1, view.col),
      leftcol = view.leftcol,
      closed = closed,
    }
  end)
end

local function resolve(plan, pos)
  local best, distance = nil, math.huge
  for _, block in ipairs(plan.blocks) do
    local delta = math.abs(block.source.start_byte - (pos.byte or -1))
    if delta < distance or (delta == distance and best and block.row_end < best.row_end) then
      best, distance = block, delta
    end
  end
  if not pos.byte or not best then
    return math.min(pos.row, #plan.lines - 1)
  end
  if pos.key then
    for row = best.row_start, best.row_end do
      if plan.row_keys[row + 1] == pos.key then
        return row
      end
    end
  end
  local wanted = pos.offset
  if pos.excerpt and pos.excerpt ~= "" then
    local parts = {}
    for row = best.row_start, best.row_end do
      parts[#parts + 1] = content(plan, row)
    end
    local text = table.concat(parts)
    local found, closest, from = nil, math.huge, 1
    while true do
      local match = text:find(pos.excerpt, from, true)
      if not match then
        break
      end
      local delta = math.abs(match - 1 - pos.offset)
      if delta < closest then
        found, closest = match - 1, delta
      end
      from = match + 1
    end
    wanted = found or wanted
  end
  local offset = 0
  for row = best.row_start, best.row_end do
    local size = #content(plan, row)
    if size > 0 and offset + size > wanted then
      return row
    end
    offset = offset + size
  end
  return best.row_end
end

---Track source positions with extmarks so edits above a passage do not move it.
---@param session MDEyeSession
function M.track(session)
  vim.api.nvim_buf_clear_namespace(session.src_buf, ns, 0, -1)
  session.source_marks = {}
  session.source_positions = {}
  for _, block in ipairs(session.plan.blocks) do
    local source = block.source
    if not session.source_marks[source.start_byte] then
      local col = source.start_byte - vim.api.nvim_buf_get_offset(session.src_buf, source.start_row)
      local line = vim.api.nvim_buf_get_lines(
        session.src_buf,
        source.start_row,
        source.start_row + 1,
        false
      )[1] or ""
      session.source_positions[source.start_byte] =
        { row = source.start_row, col = math.min(math.max(col, 0), #line) }
      session.source_marks[source.start_byte] = vim.api.nvim_buf_set_extmark(
        session.src_buf,
        ns,
        source.start_row,
        math.min(math.max(col, 0), #line),
        { right_gravity = true }
      )
    end
  end
end

---Rebuild native heading/code folds, restoring choices by tracked source location.
---@param session MDEyeSession
---@param saved table|nil
function M.folds(session, saved)
  local plan, folds = session.plan, {}
  for i, heading in ipairs(plan.headings) do
    local last = #plan.lines - 2
    for j = i + 1, #plan.headings do
      if plan.headings[j].level <= heading.level then
        last = plan.headings[j].row - 1
        break
      end
    end
    while last > heading.row and plan.lines[last + 1]:match("^%s*$") do
      last = last - 1
    end
    if last > heading.row then
      folds[#folds + 1] =
        { first = heading.row, last = last, source = heading.source, kind = "heading" }
    end
  end
  for _, code in ipairs(plan.code_blocks) do
    if code.row_end > code.row_start then
      folds[#folds + 1] =
        { first = code.row_start, last = code.row_end, source = code.source, kind = "code" }
    end
  end
  table.sort(folds, function(a, b)
    return a.first < b.first or (a.first == b.first and a.last > b.last)
  end)
  local unchanged = #(session.folds or {}) == #folds
  for i, fold in ipairs(folds) do
    local previous = (session.folds or {})[i]
    fold.closed = saved and saved.closed[fold.kind .. ":" .. fold.source.start_byte] or false
    if not previous or previous.first ~= fold.first or previous.last ~= fold.last then
      unchanged = false
    end
  end
  if unchanged then
    unchanged = vim.api.nvim_win_call(session.owner_win, function()
      local ends = {}
      for _, fold in ipairs(folds) do
        while ends[#ends] and ends[#ends] < fold.first do
          ends[#ends] = nil
        end
        if vim.fn.foldlevel(fold.first + 1) ~= #ends + 1 then
          return false
        end
        ends[#ends + 1] = fold.last
      end
      return true
    end)
  end
  if unchanged then
    session.folds = folds
    return
  end
  vim.api.nvim_win_call(session.owner_win, function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.cmd("silent! normal! zE")
    for i = #folds, 1, -1 do
      local fold = folds[i]
      vim.cmd(("silent %d,%dfold"):format(fold.first + 1, fold.last + 1))
      fold.closed = saved and saved.closed[fold.kind .. ":" .. fold.source.start_byte] or false
    end
    vim.cmd("silent! normal! zR")
    for i = #folds, 1, -1 do
      if folds[i].closed then
        vim.cmd(("silent! %dfoldclose"):format(folds[i].first + 1))
      end
    end
    vim.api.nvim_win_set_cursor(0, { math.min(cursor[1], #plan.lines), cursor[2] })
  end)
  session.folds = folds
end

---@param session MDEyeSession
---@param saved table|nil
function M.restore(session, saved)
  if not saved then
    return
  end
  local top, cursor = resolve(session.plan, saved.top), resolve(session.plan, saved.cursor)
  local line = session.plan.lines[cursor + 1] or ""
  vim.api.nvim_win_call(session.owner_win, function()
    vim.fn.winrestview({
      topline = top + 1,
      lnum = cursor + 1,
      col = math.min(saved.cursor.col, #line),
      leftcol = saved.leftcol,
    })
  end)
end

---Keep block starts inside replaced source lines; ordinary insertion still follows gravity.
function M.on_lines(session, first, last, new_last)
  for byte, pos in pairs(session.source_positions or {}) do
    if pos.row >= first and pos.row < last then
      pos.row = first + math.min(pos.row - first, math.max(new_last - first - 1, 0))
      pos.row = math.min(pos.row, vim.api.nvim_buf_line_count(session.src_buf) - 1)
      local line = vim.api.nvim_buf_get_lines(session.src_buf, pos.row, pos.row + 1, false)[1] or ""
      pos.col = math.min(pos.col, #line)
      vim.api.nvim_buf_set_extmark(
        session.src_buf,
        ns,
        pos.row,
        pos.col,
        { id = session.source_marks[byte], right_gravity = true }
      )
    elseif pos.row >= last then
      pos.row = pos.row + new_last - last
    end
  end
end

---Record native fold changes made by the preview mappings.
function M.remember_folds(session)
  vim.api.nvim_win_call(session.owner_win, function()
    for _, fold in ipairs(session.folds or {}) do
      local outer = vim.fn.foldclosed(fold.first + 1)
      if outer == -1 or outer == fold.first + 1 then
        fold.closed = outer ~= -1
      end
    end
  end)
end

---@param session MDEyeSession
function M.clear(session)
  if vim.api.nvim_buf_is_valid(session.src_buf) then
    vim.api.nvim_buf_clear_namespace(session.src_buf, ns, 0, -1)
  end
end

return M
