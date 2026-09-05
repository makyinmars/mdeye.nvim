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

  health.info(
    "optional rich-content adapters: none configured (image adapters are not yet integrated)"
  )

  local document = require("mdeye.document")
  local parser_health = document.parser_diagnostics()
  local parsers_ok = true
  for _, lang in ipairs({ "markdown", "markdown_inline" }) do
    if parser_health.parsers[lang] then
      health.ok(("tree-sitter parser available: %s"):format(lang))
    else
      health.error(("tree-sitter parser missing: %s"):format(lang))
      parsers_ok = false
    end
  end
  if not parsers_ok then
    return
  end
  if parser_health.error then
    health.error(parser_health.error)
    return
  elseif parser_health.table_injection then
    health.ok("markdown_inline is injected into pipe_table_cell")
  else
    health.warn(
      "the effective injection query does not inject markdown_inline into pipe_table_cell; "
        .. "table cells will render without inline styling. "
        .. "Check for a plugin shadowing Neovim's bundled markdown queries."
    )
  end

  local active = require("mdeye.session").diagnostics()
  if #active == 0 then
    health.info("no active previews")
  else
    for _, state in ipairs(active) do
      local source = state.source_name ~= "" and vim.fn.fnamemodify(state.source_name, ":~:.")
        or "[No Name]"
      local summary = ("%s (%s; source=%d, preview=%d, window=%d)"):format(
        source,
        state.mode,
        state.src_buf,
        state.preview_buf,
        state.owner_win
      )
      local issues = {}
      if not state.source_valid then
        issues[#issues + 1] = "source buffer is invalid"
      end
      if not state.preview_valid then
        issues[#issues + 1] = "preview buffer is invalid"
      end
      if not state.owner_valid then
        issues[#issues + 1] = "owner window is invalid"
      elseif not state.owner_shows_preview then
        issues[#issues + 1] = "owner window does not show the preview"
      end
      if not state.rendered then
        issues[#issues + 1] = "initial render is incomplete"
      end
      if #issues == 0 then
        health.ok("active preview healthy: " .. summary)
      else
        health.warn(
          "active preview needs attention: " .. summary .. ": " .. table.concat(issues, "; ")
        )
      end
    end
  end

  local code_languages = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "markdown" then
      local doc = document.parse(bufnr)
      if doc then
        for label, status in pairs(doc.code_languages) do
          local current = code_languages[label] or {}
          current.highlight_lang = current.highlight_lang or status.highlight_lang
          code_languages[label] = current
        end
      end
    end
  end
  if vim.tbl_isempty(code_languages) then
    health.info("open a Markdown buffer to check its fenced-code language parsers")
  else
    local labels = vim.tbl_keys(code_languages)
    table.sort(labels)
    for _, label in ipairs(labels) do
      local status = code_languages[label]
      if label:lower() == "mermaid" then
        health.info("Mermaid: native flowchart connections; unsupported syntax stays as source")
      elseif status.highlight_lang then
        health.ok(
          ("fenced-code highlights available: %s -> %s"):format(label, status.highlight_lang)
        )
      else
        health.warn(
          ("no parser/highlight query for fenced-code language %q; code will render as plain text"):format(
            label
          )
        )
      end
    end
  end
end

return M
