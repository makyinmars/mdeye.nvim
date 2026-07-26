---:checkhealth mdeye
local M = {}

function M.check()
  local health = vim.health
  health.start("mdeye")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 is required")
    return
  end

  local parsers_ok = true
  for _, lang in ipairs({ "markdown", "markdown_inline" }) do
    local ok = pcall(vim.treesitter.language.add, lang)
    if ok then
      health.ok(("tree-sitter parser available: %s"):format(lang))
    else
      health.error(("tree-sitter parser missing: %s"):format(lang))
      parsers_ok = false
    end
  end
  if not parsers_ok then
    return
  end

  -- Functional check that the *effective* runtime injection query injects
  -- markdown_inline into pipe_table_cell; a third-party query installation
  -- can shadow Neovim's bundled one.
  local sample = "| a |\n| - |\n| b |\n"
  local ok, parser = pcall(vim.treesitter.get_string_parser, sample, "markdown")
  if not ok or not parser then
    health.error("could not create a markdown string parser")
    return
  end
  parser:parse(true)
  local inline = parser:children()["markdown_inline"]
  local regions = inline and inline:included_regions() or {}
  local count = 0
  for _, region in pairs(regions) do
    count = count + #region
  end
  if count >= 2 then
    health.ok("markdown_inline is injected into pipe_table_cell")
  else
    health.warn(
      "the effective injection query does not inject markdown_inline into pipe_table_cell; "
        .. "table cells will render without inline styling. "
        .. "Check for a plugin shadowing Neovim's bundled markdown queries."
    )
  end
end

return M
