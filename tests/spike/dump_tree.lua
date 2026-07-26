-- Milestone 0 spike: dump real Tree-sitter node trees for the comprehensive fixture.
-- Run: nvim --headless -l tests/spike/dump_tree.lua
local fixture = "tests/fixtures/comprehensive.md"

-- Load the fixture into a HIDDEN buffer (never displayed) to prove parse(true)
-- yields injected trees without a window.
local bufnr = vim.fn.bufadd(fixture)
vim.fn.bufload(bufnr)
assert(vim.fn.bufwinid(bufnr) == -1, "buffer must stay hidden for this spike")

local parser = assert(vim.treesitter.get_parser(bufnr, "markdown"))
parser:parse(true)

local out = {}
local function emit(s)
  out[#out + 1] = s
end

local function dump(node, src, depth)
  local sr, sc, er, ec = node:range()
  local text = vim.treesitter.get_node_text(node, src)
  text = text:gsub("\n", "\\n")
  if #text > 40 then
    text = text:sub(1, 40) .. "…"
  end
  emit(
    ("%s%s [%d,%d]-[%d,%d] %s%s"):format(
      string.rep("  ", depth),
      node:type(),
      sr,
      sc,
      er,
      ec,
      node:named() and "" or "(anon) ",
      "«" .. text .. "»"
    )
  )
  for child in node:iter_children() do
    dump(child, src, depth + 1)
  end
end

emit("=== block tree (markdown) ===")
dump(parser:trees()[1]:root(), bufnr, 0)

emit("")
emit("=== injected inline trees (markdown_inline) ===")
parser:for_each_tree(function(tree, ltree)
  if ltree:lang() == "markdown_inline" then
    emit("--- inline tree; included_ranges (row,col,byte triples):")
    for _, r in ipairs(ltree:included_regions()) do
      local parts = {}
      for _, range in ipairs(r) do
        parts[#parts + 1] = ("(%d,%d,%d)-(%d,%d,%d)"):format(
          range[1],
          range[2],
          range[3],
          range[4],
          range[5],
          range[6]
        )
      end
      emit("    " .. table.concat(parts, " "))
    end
    dump(tree:root(), bufnr, 1)
  end
end)

emit("")
emit("=== display width checks ===")
for _, s in ipairs({ "abc", "日本語", "🚀", "é", "e\204\129", "🎉x" }) do
  emit(("%-12s bytes=%d cells=%d"):format(vim.inspect(s), #s, vim.fn.strdisplaywidth(s)))
end

io.write(table.concat(out, "\n") .. "\n")
