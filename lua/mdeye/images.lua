---Optional local image.nvim adapter. Layout only receives measured reservations.
local M = {}

local function clear(entry)
  if entry.image then
    pcall(entry.image.clear, entry.image)
  end
end

---@param session MDEyeSession
function M.clear(session)
  for _, entry in pairs(session.image_cache or {}) do
    clear(entry)
  end
  session.image_cache = {}
end

---@return table|nil backend, string|nil reason
function M.available()
  local ok, api = pcall(require, "image")
  if not ok or type(api.from_file) ~= "function" then
    return nil, "image.nvim is unavailable"
  end
  if api.is_enabled then
    local enabled, value = pcall(api.is_enabled)
    if not enabled or not value then
      return nil, "image.nvim is not enabled"
    end
  end
  return api
end

local function local_path(target, base)
  if not target then
    return nil
  end
  target = target:gsub("^<", ""):gsub(">$", "")
  if target:match("^file:///") then
    target = vim.uri_to_fname(target)
  elseif target:match("^[%a][%w+.-]*:") or target:match("^//") or target:find("#", 1, true) then
    return nil
  else
    target = target:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end
  if target:find("[%c]") then
    return nil
  end
  if target:sub(1, 1) ~= "/" then
    target = base .. "/" .. target
  end
  return vim.fs.normalize(target)
end

local function walk(blocks, visit)
  for _, block in ipairs(blocks) do
    visit(block)
    if block.blocks then
      walk(block.blocks, visit)
    end
    for _, item in ipairs(block.items or {}) do
      walk(item.blocks, visit)
    end
  end
end

---@class MDEyeImageSpec
---@field key string
---@field aspect number image pixel height / width
---@field max_width integer
---@field max_height integer

---Prepare local standalone images, caching decoded handles by path and occurrence.
---@param session MDEyeSession
---@param doc MDEyeDocument
---@param opts table
---@return table<integer, MDEyeImageSpec>
function M.prepare(session, doc, opts)
  local specs = {}
  session.image_status = nil
  if not opts.enabled then
    M.clear(session)
    return specs
  end
  local api, reason = M.available()
  session.image_status = reason
  if not api then
    M.clear(session)
    return specs
  end
  session.image_cache = session.image_cache or {}
  local seen, occurrences, count = {}, {}, 0
  local source = vim.api.nvim_buf_get_name(session.src_buf)
  local base = source ~= "" and vim.fs.dirname(source) or vim.fn.getcwd()
  walk(doc.blocks, function(block)
    if block.kind ~= "paragraph" or #(block.runs or {}) ~= 1 or block.runs[1].kind ~= "image" then
      return
    end
    local path = local_path(block.runs[1].target, base)
    local stat = path and vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" or stat.size > opts.max_file_size then
      return
    end
    count = count + 1
    if count > opts.max_images then
      return
    end
    occurrences[path] = (occurrences[path] or 0) + 1
    local key = path .. ":" .. occurrences[path]
    local signature = ("%d:%d:%d"):format(stat.size, stat.mtime.sec, stat.mtime.nsec)
    local entry = session.image_cache[key]
    if entry and (entry.signature ~= signature or entry.window ~= session.owner_win) then
      clear(entry)
      entry = nil
    end
    if not entry then
      -- Supplying no ID avoids retrieving a stale backend object for changed files.
      local ok, img = pcall(api.from_file, path, {
        window = session.owner_win,
        buffer = session.preview_buf,
        with_virtual_padding = false,
        inline = true,
        render_offset_top = -1,
        overlap = opts.max_height,
      })
      entry = { image = ok and img or nil, signature = signature, window = session.owner_win }
      if not ok then
        session.image_status = "image backend could not decode a local image"
      end
      session.image_cache[key] = entry
    end
    seen[key] = true
    local img = entry.image
    if entry.failed then
      session.image_status = "image rendering failed; retaining alt text"
    elseif not img then
      session.image_status = "image backend could not decode a local image"
    end
    if
      img
      and not entry.failed
      and type(img.image_width) == "number"
      and img.image_width > 0
      and type(img.image_height) == "number"
      and img.image_height > 0
    then
      specs[block.source.start_byte] = {
        key = key,
        aspect = img.image_height / img.image_width,
        max_width = opts.max_width,
        max_height = opts.max_height,
      }
    end
  end)
  for key, entry in pairs(session.image_cache) do
    if not seen[key] then
      clear(entry)
      session.image_cache[key] = nil
    end
  end
  return specs
end

---Refresh visibility after scrolling/folding. Returns true on a new backend failure.
---@param session MDEyeSession
---@return boolean failed
function M.refresh(session)
  if session.closed or not session.plan or not vim.api.nvim_win_is_valid(session.owner_win) then
    return false
  end
  local failed = false
  local visible = vim.api.nvim_win_get_buf(session.owner_win) == session.preview_buf
    and vim.api.nvim_win_get_tabpage(session.owner_win) == vim.api.nvim_get_current_tabpage()
  vim.api.nvim_win_call(session.owner_win, function()
    local top, bottom = vim.fn.line("w0") - 1, vim.fn.line("w$") - 1
    for _, image in ipairs(session.plan.images or {}) do
      local entry = session.image_cache[image.key]
      if entry and entry.image and not entry.failed then
        if
          visible
          and image.row_end >= top
          and image.row_start <= bottom
          and vim.fn.foldclosed(image.row_start + 1) == -1
        then
          entry.image.overlap = image.height
          local ok = pcall(
            entry.image.render,
            entry.image,
            { x = image.col, y = image.row_start, width = image.width, height = image.height }
          )
          if not ok then
            clear(entry)
            entry.failed, failed = true, true
            session.image_status = "image rendering failed; retaining alt text"
          end
        else
          clear(entry)
        end
      end
    end
  end)
  return failed
end

return M
