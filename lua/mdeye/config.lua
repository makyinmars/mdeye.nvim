---Configuration defaults, validation, and highlight initialization.
local M = {}

---@class MDEyeConfig
---@field open "current"|"split"|"tab"
---@field max_width integer|false false uses the full available window width
---@field min_margin integer
---@field debounce_ms integer
---@field code { wrap: boolean }
---@field images { enabled: boolean, max_width: integer, max_height: integer, max_file_size: integer, max_images: integer }
---@field mermaid { enabled: boolean, layout: "graph"|"connections" }

---@type MDEyeConfig
local defaults = {
  open = "current",
  max_width = 88,
  min_margin = 3,
  debounce_ms = 120,
  mermaid = { enabled = true, layout = "graph" },
  images = {
    enabled = false,
    max_width = 60,
    max_height = 16,
    max_file_size = 10 * 1024 * 1024,
    max_images = 32,
  },
  code = {
    wrap = false,
  },
}

---@type MDEyeConfig
M.options = vim.deepcopy(defaults)

---@param opts table|nil
---@return string|nil error
local function validate(opts)
  local ok, err = pcall(function()
    vim.validate("open", opts.open, function(v)
      return v == nil or v == "current" or v == "split" or v == "tab"
    end, true, '"current"|"split"|"tab"')
    vim.validate("max_width", opts.max_width, function(v)
      return v == nil or v == false or type(v) == "number"
    end, true, "number|false")
    vim.validate("min_margin", opts.min_margin, "number", true)
    vim.validate("debounce_ms", opts.debounce_ms, "number", true)
    vim.validate("mermaid", opts.mermaid, "table", true)
    if opts.mermaid then
      vim.validate("mermaid.enabled", opts.mermaid.enabled, "boolean", true)
      vim.validate("mermaid.layout", opts.mermaid.layout, function(value)
        return value == nil or value == "graph" or value == "connections"
      end, true, '"graph"|"connections"')
    end
    vim.validate("images", opts.images, "table", true)
    if opts.images then
      vim.validate("images.enabled", opts.images.enabled, "boolean", true)
      for _, key in ipairs({ "max_width", "max_height", "max_file_size", "max_images" }) do
        vim.validate("images." .. key, opts.images[key], function(v)
          return v == nil
            or (type(v) == "number" and v > 0 and v < math.huge and v == math.floor(v))
        end, true, "positive integer")
      end
    end
    vim.validate("code", opts.code, "table", true)
    if opts.code then
      vim.validate("code.wrap", opts.code.wrap, "boolean", true)
    end
    if opts.max_width and opts.max_width < 20 then
      error("max_width must be at least 20")
    end
    if opts.min_margin and opts.min_margin < 0 then
      error("min_margin must not be negative")
    end
    if opts.debounce_ms and opts.debounce_ms < 0 then
      error("debounce_ms must not be negative")
    end
  end)
  if not ok then
    return err
  end
  return nil
end

---@param opts table|nil
---@return string|nil error
function M.setup(opts)
  opts = opts or {}
  local err = validate(opts)
  if err then
    return err
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  return nil
end

---Default highlight links. Each group links to the first existing candidate so
---the plugin follows the active colorscheme and never hard-codes colors.
local hl_defaults = {
  MDEyeText = { "Normal" },
  MDEyeMuted = { "Comment" },
  MDEyeHeading1 = { "@markup.heading.1.markdown", "@markup.heading.1", "Title" },
  MDEyeHeading2 = { "@markup.heading.2.markdown", "@markup.heading.2", "Title" },
  MDEyeHeading3 = { "@markup.heading.3.markdown", "@markup.heading.3", "Title" },
  MDEyeHeading4 = { "@markup.heading.4.markdown", "@markup.heading.4", "Title" },
  MDEyeHeading5 = { "@markup.heading.5.markdown", "@markup.heading.5", "Title" },
  MDEyeHeading6 = { "@markup.heading.6.markdown", "@markup.heading.6", "Title" },
  MDEyeHeadingRule = { "WinSeparator", "Comment" },
  MDEyeEmphasis = { "@markup.italic", "Italic" },
  MDEyeStrong = { "@markup.strong", "Bold" },
  MDEyeStrike = { "@markup.strikethrough" },
  MDEyeCode = { "@markup.raw.markdown_inline", "@markup.raw", "String" },
  MDEyeCodeBlock = { "CursorLine" },
  MDEyeDiagram = { "@markup.raw", "String" },
  MDEyeLink = { "@markup.link.label", "Underlined" },
  MDEyeFootnote = { "@markup.link", "Special" },
  MDEyeQuote = { "@markup.quote", "Comment" },
  MDEyeAlertNote = { "DiagnosticInfo" },
  MDEyeAlertTip = { "DiagnosticOk" },
  MDEyeAlertImportant = { "DiagnosticHint" },
  MDEyeAlertWarning = { "DiagnosticWarn" },
  MDEyeAlertCaution = { "DiagnosticError" },
  MDEyeListMarker = { "@markup.list", "Special" },
  MDEyeTableBorder = { "@punctuation.special", "Delimiter" },
  MDEyeTaskChecked = { "@markup.list.checked", "DiagnosticOk" },
  MDEyeTaskUnchecked = { "@markup.list.unchecked", "Comment" },
}

---Apply missing default highlight links. `default = true` keeps explicit user
---highlights authoritative; reapplying on ColorScheme only restores links a
---colorscheme cleared.
function M.apply_highlights()
  for group, candidates in pairs(hl_defaults) do
    local target = candidates[#candidates]
    for _, candidate in ipairs(candidates) do
      if vim.fn.hlexists(candidate) == 1 then
        target = candidate
        break
      end
    end
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

local hl_installed = false

---Install highlights now and keep default links alive across ColorScheme.
function M.ensure_highlights()
  M.apply_highlights()
  if hl_installed then
    return
  end
  hl_installed = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("MDEyeHighlights", { clear = true }),
    callback = M.apply_highlights,
  })
end

return M
