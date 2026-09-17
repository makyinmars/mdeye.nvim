---Optional mermaid-cli PNG adapter. Layout receives ready paths; jobs stay async.
local M = {}

local MAX_SOURCE_BYTES = 64 * 1024
local DEFAULT_SCALE = 3
local DEFAULT_WIDTH = 1920

---@class MDEyeMermaidImageState
---@field status "ready"|"pending"|"failed"
---@field hash string
---@field path string|nil
---@field reason string|nil

---@class MDEyeMermaidImageOpts
---@field enabled boolean
---@field image MDEyeMermaidImageConfig
---@field cache_dir string|nil
---@field max_images integer|nil
---@field on_ready fun()|nil

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

---@param opts MDEyeMermaidImageConfig
---@return string
function M.theme(opts)
  if opts.theme == "dark" or opts.theme == "default" then
    return opts.theme
  end
  return vim.o.background == "dark" and "dark" or "default"
end

---@param opts MDEyeMermaidImageConfig
---@return integer
function M.scale(opts)
  return opts.scale or DEFAULT_SCALE
end

---@param opts MDEyeMermaidImageConfig
---@return integer
function M.width(opts)
  return opts.width or DEFAULT_WIDTH
end

---@param source string
---@param theme string
---@param background string
---@param scale integer|nil
---@param width integer|nil
---@return string
function M.hash(source, theme, background, scale, width)
  return vim.fn.sha256(
    source
      .. "\0"
      .. theme
      .. "\0"
      .. background
      .. "\0"
      .. tostring(scale or DEFAULT_SCALE)
      .. "\0"
      .. tostring(width or DEFAULT_WIDTH)
  )
end

---@param opts { cache_dir: string|nil }
---@return string
function M.cache_dir(opts)
  return opts.cache_dir or (vim.fn.stdpath("cache") .. "/mdeye/mermaid")
end

---@param dir string
---@param hash string
---@return string
function M.cache_path(dir, hash)
  return dir .. "/" .. hash .. ".png"
end

---@param opts MDEyeMermaidImageConfig
---@return { bin: string }|nil, string|nil
function M.available(opts)
  local cmd = opts.command
  if type(cmd) == "string" and cmd ~= "" then
    if vim.fn.executable(cmd) == 1 then
      return { bin = cmd }
    end
    return nil, "mermaid command is not executable: " .. cmd
  end
  if vim.fn.executable("mmdc") == 1 then
    return { bin = "mmdc" }
  end
  return nil, "mmdc is not on PATH"
end

local function write_private(path, contents)
  local fd, err = vim.uv.fs_open(path, "w", 384)
  if not fd then
    return err or "could not create mermaid source file"
  end
  local ok, werr = vim.uv.fs_write(fd, contents)
  vim.uv.fs_close(fd)
  if not ok then
    return werr or "could not write mermaid source file"
  end
  return nil
end

local function png_ready(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat and stat.type == "file" and stat.size > 0
end

---@param session MDEyeSession
function M.clear(session)
  for _, job in pairs(session.mermaid_jobs or {}) do
    pcall(function()
      job:kill()
    end)
  end
  session.mermaid_jobs = {}
  session.mermaid_images = {}
  session.mermaid_cache = {}
  session.mermaid_image_status = nil
end

local function start_job(
  session,
  bin,
  hash,
  source,
  path,
  image_opts,
  theme,
  background,
  scale,
  width,
  on_ready
)
  session.mermaid_jobs = session.mermaid_jobs or {}
  if session.mermaid_jobs[hash] then
    return
  end
  local input = vim.fn.tempname() .. ".mmd"
  local err = write_private(input, source)
  if err then
    session.mermaid_cache[hash] = { status = "failed", hash = hash, reason = err }
    return
  end
  local args = {
    bin,
    "--input",
    input,
    "--output",
    path,
    "--outputFormat",
    "png",
    "--theme",
    theme,
    "--backgroundColor",
    background,
    "--scale",
    tostring(scale),
    "--width",
    tostring(width),
  }
  local job = vim.system(args, { timeout = image_opts.timeout_ms, text = true }, function(obj)
    vim.schedule(function()
      pcall(vim.uv.fs_unlink, input)
      if session.mermaid_jobs then
        session.mermaid_jobs[hash] = nil
      end
      if session.closed then
        return
      end
      local cache = session.mermaid_cache and session.mermaid_cache[hash]
      if not cache then
        return
      end
      if obj.code == 0 and png_ready(path) then
        cache.status = "ready"
        cache.path = path
        cache.reason = nil
      else
        cache.status = "failed"
        cache.path = nil
        if obj.signal and obj.signal ~= 0 then
          cache.reason = "mermaid render timed out"
        else
          cache.reason = "mmdc exited with " .. tostring(obj.code)
        end
      end
      if on_ready then
        on_ready()
      end
    end)
  end)
  session.mermaid_jobs[hash] = job
end

---Start or reuse PNG renders for mermaid fences. Ready paths are returned for layout.
---@param session MDEyeSession
---@param doc MDEyeDocument
---@param opts MDEyeMermaidImageOpts
---@return table<integer, MDEyeMermaidImageState>
function M.prepare(session, doc, opts)
  local states = {}
  session.mermaid_images = states
  if not opts.enabled or opts.image.enabled == "off" then
    session.mermaid_image_status = nil
    return states
  end
  local backend, reason = M.available(opts.image)
  session.mermaid_image_status = reason
  if not backend then
    return states
  end
  session.mermaid_image_status = nil
  session.mermaid_cache = session.mermaid_cache or {}
  session.mermaid_jobs = session.mermaid_jobs or {}
  local dir = M.cache_dir(opts)
  vim.fn.mkdir(dir, "p")
  local theme = M.theme(opts.image)
  local background = opts.image.background or "transparent"
  local scale = M.scale(opts.image)
  local width = M.width(opts.image)
  local wanted, count = {}, 0
  local max_images = opts.max_images or 32
  walk(doc.blocks, function(block)
    if block.kind ~= "code" or not block.attrs.lang or block.attrs.lang:lower() ~= "mermaid" then
      return
    end
    local source = table.concat(block.attrs.lines or {}, "\n")
    if #source > MAX_SOURCE_BYTES then
      return
    end
    count = count + 1
    if count > max_images then
      return
    end
    local hash = M.hash(source, theme, background, scale, width)
    wanted[hash] = true
    local path = M.cache_path(dir, hash)
    local cache = session.mermaid_cache[hash]
    if png_ready(path) then
      cache = { status = "ready", hash = hash, path = path }
      session.mermaid_cache[hash] = cache
    elseif not cache or (cache.status ~= "failed" and cache.status ~= "pending") then
      cache = { status = "pending", hash = hash, path = path }
      session.mermaid_cache[hash] = cache
      start_job(
        session,
        backend.bin,
        hash,
        source,
        path,
        opts.image,
        theme,
        background,
        scale,
        width,
        opts.on_ready
      )
    end
    states[block.source.start_byte] = {
      status = cache.status,
      hash = hash,
      path = cache.status == "ready" and cache.path or nil,
      reason = cache.reason,
    }
  end)
  for hash, job in pairs(session.mermaid_jobs) do
    if not wanted[hash] then
      pcall(function()
        job:kill()
      end)
      session.mermaid_jobs[hash] = nil
    end
  end
  return states
end

---Open the rendered PNG for the mermaid fence covering a preview row.
---@param session MDEyeSession
---@param row integer 0-based preview row
---@return boolean ok
function M.open(session, row)
  if not session.plan then
    return false
  end
  local code
  for _, block in ipairs(session.plan.code_blocks or {}) do
    if block.row_start <= row and row <= block.row_end then
      code = block
      break
    end
  end
  local state = code and session.mermaid_images and session.mermaid_images[code.source.start_byte]
  if not state or not state.path then
    return false
  end
  vim.ui.open(state.path)
  return true
end

return M
