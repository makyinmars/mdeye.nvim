---Tree-sitter Markdown to a normalized semantic document.
---
---All node-shape knowledge lives here. Node names were verified against the
---bundled tree-sitter-markdown parsers with the Milestone 0 spike
---(tests/spike/dump_tree.lua); no other module may touch Tree-sitter.
---
---Injected `markdown_inline` trees can cover discontiguous source ranges:
---blockquote `> ` markers and list continuation indents sit between the
---included ranges. Display text is therefore always extracted by intersecting
---node byte ranges with the injected tree's included ranges, and the result is
---stored on the inline run. Later modules never re-extract text from spans.
local M = {}

---@class MDEyeSourceSpan
---@field start_byte integer 0-based, inclusive
---@field end_byte integer 0-based, exclusive
---@field start_row integer 0-based
---@field end_row integer 0-based, inclusive

---@class MDEyeInline
---@field kind "text"|"emphasis"|"strong"|"strike"|"code"|"link"|"image"|"break"
---@field text string|nil normalized display text (leaf kinds)
---@field source MDEyeSourceSpan
---@field target string|nil link/image destination as written in the source
---@field children MDEyeInline[]|nil container kinds

---@class MDEyeListItem
---@field task nil|"checked"|"unchecked"
---@field source MDEyeSourceSpan
---@field blocks MDEyeBlock[]

---@class MDEyeTableCell
---@field runs MDEyeInline[]
---@field source MDEyeSourceSpan

---@class MDEyeBlock
---@field kind "heading"|"paragraph"|"list"|"quote"|"code"|"table"|"rule"|"html"
---@field source MDEyeSourceSpan
---@field runs MDEyeInline[]|nil heading, paragraph
---@field items MDEyeListItem[]|nil list
---@field blocks MDEyeBlock[]|nil quote
---@field attrs table

---@class MDEyeDocument
---@field blocks MDEyeBlock[]

---Parse state shared by the conversion walk.
---@class MDEyeParseCtx
---@field src string full source text
---@field line_offsets integer[] byte offset of the start of each 0-based row
---@field inline_index table<string, {root: TSNode, ranges: integer[][]}>
---@field refs table<string, string> normalized reference label -> destination

local function span_from_node(node)
  local sr, _, sb = node:start()
  local er, ec, eb = node:end_()
  if ec == 0 and er > sr then
    er = er - 1
  end
  return { start_byte = sb, end_byte = eb, start_row = sr, end_row = er }
end

---@param ctx MDEyeParseCtx
---@param byte integer
---@return integer row
local function row_of_byte(ctx, byte)
  local offsets = ctx.line_offsets
  local lo, hi = 1, #offsets
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if offsets[mid] <= byte then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1
end

---@param ctx MDEyeParseCtx
local function span_from_bytes(ctx, sb, eb)
  return {
    start_byte = sb,
    end_byte = eb,
    start_row = row_of_byte(ctx, sb),
    end_row = row_of_byte(ctx, math.max(sb, eb - 1)),
  }
end

---Extract source text for [sb, eb) restricted to the included ranges of the
---injected tree, so block markers between ranges never leak into prose.
---@param ctx MDEyeParseCtx
---@param sb integer
---@param eb integer
---@param ranges integer[][]|nil pairs of {start_byte, end_byte}; nil means contiguous
---@return string
local function extract(ctx, sb, eb, ranges)
  if not ranges then
    return ctx.src:sub(sb + 1, eb)
  end
  local parts = {}
  for _, range in ipairs(ranges) do
    local s = math.max(sb, range[1])
    local e = math.min(eb, range[2])
    if s < e then
      parts[#parts + 1] = ctx.src:sub(s + 1, e)
    end
  end
  return table.concat(parts)
end

---Named entity references worth decoding for prose; anything else stays literal.
local entities = {
  ["&amp;"] = "&",
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&quot;"] = '"',
  ["&apos;"] = "'",
  ["&nbsp;"] = " ",
  ["&mdash;"] = "—",
  ["&ndash;"] = "–",
  ["&hellip;"] = "…",
  ["&copy;"] = "©",
}

---@param label string
---@return string
local function normalize_ref_label(label)
  return (label:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

local inline_converters

---Append a plain text run unless empty.
local function push_text(ctx, out, sb, eb, ranges)
  local text = extract(ctx, sb, eb, ranges)
  if text ~= "" then
    out[#out + 1] = { kind = "text", text = text, source = span_from_bytes(ctx, sb, eb) }
  end
end

---Convert the children of an inline container node, keeping the raw text of
---the gaps between named children. Grammar tokens such as `.` or `(` are
---anonymous nodes inside those gaps and stay part of the prose; only named
---delimiter/marker nodes are consumed silently.
---@param ctx MDEyeParseCtx
---@param node TSNode
---@param ranges integer[][]|nil
---@return MDEyeInline[]
local function convert_inline_children(ctx, node, ranges)
  local out = {}
  local _, _, pos = node:start()
  local _, _, node_eb = node:end_()
  for child in node:iter_children() do
    if child:named() then
      local _, _, csb = child:start()
      local _, _, ceb = child:end_()
      if csb > pos then
        push_text(ctx, out, pos, csb, ranges)
      end
      local converter = inline_converters[child:type()]
      if converter then
        converter(ctx, child, ranges, out)
      else
        -- Unknown constructs stay readable as plain text.
        push_text(ctx, out, csb, ceb, ranges)
      end
      pos = math.max(pos, ceb)
    end
  end
  if node_eb > pos then
    push_text(ctx, out, pos, node_eb, ranges)
  end
  return out
end

local function container(kind)
  ---@param ctx MDEyeParseCtx
  ---@param node TSNode
  return function(ctx, node, ranges, out)
    local children = convert_inline_children(ctx, node, ranges)
    -- `~~x~~` parses as strikethrough directly nesting strikethrough; flatten
    -- same-kind nesting so styles do not double up.
    if #children == 1 and children[1].kind == kind and children[1].children then
      children = children[1].children
    end
    out[#out + 1] = { kind = kind, children = children, source = span_from_node(node) }
  end
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@param field string
---@return TSNode|nil
local function child_of_type(node, ...)
  local wanted = { ... }
  for child in node:iter_children() do
    for _, t in ipairs(wanted) do
      if child:type() == t then
        return child
      end
    end
  end
  return nil
end

local function link_target_from_ref(ctx, node, ranges)
  local label = child_of_type(node, "link_label")
  local key
  if label then
    local _, _, sb = label:start()
    local _, _, eb = label:end_()
    key = normalize_ref_label(extract(ctx, sb, eb, ranges):gsub("^%[", ""):gsub("%]$", ""))
  else
    local text = child_of_type(node, "link_text", "image_description")
    if text then
      local _, _, sb = text:start()
      local _, _, eb = text:end_()
      key = normalize_ref_label(extract(ctx, sb, eb, ranges))
    end
  end
  return key and ctx.refs[key] or nil
end

inline_converters = {
  emphasis = container("emphasis"),
  strong_emphasis = container("strong"),
  strikethrough = container("strike"),

  emphasis_delimiter = function() end,
  code_span_delimiter = function() end,

  code_span = function(ctx, node, ranges, out)
    -- Inline code is verbatim except that CommonMark folds newlines to spaces.
    local inner = convert_inline_children(ctx, node, ranges)
    local parts = {}
    for _, run in ipairs(inner) do
      parts[#parts + 1] = run.text or ""
    end
    local text = table.concat(parts):gsub("\n", " ")
    out[#out + 1] = { kind = "code", text = text, source = span_from_node(node) }
  end,

  inline_link = function(ctx, node, ranges, out)
    local dest = child_of_type(node, "link_destination")
    local text = child_of_type(node, "link_text")
    local target
    if dest then
      local _, _, sb = dest:start()
      local _, _, eb = dest:end_()
      target = extract(ctx, sb, eb, ranges)
    end
    local children = text and convert_inline_children(ctx, text, ranges) or {}
    out[#out + 1] =
      { kind = "link", children = children, target = target, source = span_from_node(node) }
  end,

  full_reference_link = function(ctx, node, ranges, out)
    local text = child_of_type(node, "link_text")
    local children = text and convert_inline_children(ctx, text, ranges) or {}
    out[#out + 1] = {
      kind = "link",
      children = children,
      target = link_target_from_ref(ctx, node, ranges),
      source = span_from_node(node),
    }
  end,

  uri_autolink = function(ctx, node, ranges, out)
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    local uri = extract(ctx, sb, eb, ranges):gsub("^<", ""):gsub(">$", "")
    out[#out + 1] = {
      kind = "link",
      children = { { kind = "text", text = uri, source = span_from_bytes(ctx, sb, eb) } },
      target = uri,
      source = span_from_node(node),
    }
  end,

  email_autolink = function(ctx, node, ranges, out)
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    local addr = extract(ctx, sb, eb, ranges):gsub("^<", ""):gsub(">$", "")
    out[#out + 1] = {
      kind = "link",
      children = { { kind = "text", text = addr, source = span_from_bytes(ctx, sb, eb) } },
      target = "mailto:" .. addr,
      source = span_from_node(node),
    }
  end,

  image = function(ctx, node, ranges, out)
    local desc = child_of_type(node, "image_description")
    local dest = child_of_type(node, "link_destination")
    local target
    if dest then
      local _, _, sb = dest:start()
      local _, _, eb = dest:end_()
      target = extract(ctx, sb, eb, ranges)
    else
      target = link_target_from_ref(ctx, node, ranges)
    end
    local alt = ""
    if desc then
      local _, _, sb = desc:start()
      local _, _, eb = desc:end_()
      alt = extract(ctx, sb, eb, ranges)
    end
    out[#out + 1] = {
      kind = "image",
      text = alt ~= "" and alt or (target or "image"),
      target = target,
      source = span_from_node(node),
    }
  end,

  hard_line_break = function(ctx, node, _, out)
    out[#out + 1] = { kind = "break", source = span_from_node(node) }
  end,

  backslash_escape = function(ctx, node, ranges, out)
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    local text = extract(ctx, sb, eb, ranges):gsub("^\\", "")
    out[#out + 1] = { kind = "text", text = text, source = span_from_bytes(ctx, sb, eb) }
  end,

  entity_reference = function(ctx, node, ranges, out)
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    local raw = extract(ctx, sb, eb, ranges)
    out[#out + 1] =
      { kind = "text", text = entities[raw] or raw, source = span_from_bytes(ctx, sb, eb) }
  end,

  html_tag = function(ctx, node, ranges, out)
    -- Inline HTML stays visible as literal text; mdeye never interprets it.
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    push_text(ctx, out, sb, eb, ranges)
  end,
}
inline_converters.collapsed_reference_link = inline_converters.full_reference_link
inline_converters.shortcut_link = inline_converters.full_reference_link

---Find the injected markdown_inline tree whose root covers this block-tree
---`inline` (or `pipe_table_cell`) node, keyed by exact range.
---@param ctx MDEyeParseCtx
---@param node TSNode
---@return {root: TSNode, ranges: integer[][]}|nil
local function injected_for(ctx, node)
  local sr, sc, er, ec = node:range()
  return ctx.inline_index[("%d:%d:%d:%d"):format(sr, sc, er, ec)]
end

---Convert a block-tree `inline` node through its injected markdown_inline tree.
---@param ctx MDEyeParseCtx
---@param node TSNode|nil
---@return MDEyeInline[]
local function convert_inline(ctx, node)
  if not node then
    return {}
  end
  local injected = injected_for(ctx, node)
  if injected then
    return convert_inline_children(ctx, injected.root, injected.ranges)
  end
  -- No injected tree (parser without inline injection): degrade to raw text.
  local _, _, sb = node:start()
  local _, _, eb = node:end_()
  local out = {}
  push_text(ctx, out, sb, eb, nil)
  return out
end

local convert_blocks

local heading_levels = {
  atx_h1_marker = 1,
  atx_h2_marker = 2,
  atx_h3_marker = 3,
  atx_h4_marker = 4,
  atx_h5_marker = 5,
  atx_h6_marker = 6,
}

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock|nil
local function convert_heading(ctx, node)
  local level = 1
  for child in node:iter_children() do
    local l = heading_levels[child:type()]
    if l then
      level = l
      break
    end
    if child:type() == "setext_h2_underline" then
      level = 2
    end
  end
  local inline = child_of_type(node, "inline")
  if not inline then
    -- setext headings wrap a paragraph
    local para = child_of_type(node, "paragraph")
    inline = para and child_of_type(para, "inline") or nil
  end
  return {
    kind = "heading",
    runs = convert_inline(ctx, inline),
    attrs = { level = level },
    source = span_from_node(node),
  }
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock
local function convert_list(ctx, node)
  local items = {}
  local ordered = false
  local start = 1
  for item in node:iter_children() do
    if item:type() == "list_item" then
      local task = nil
      local blocks = {}
      for child in item:iter_children() do
        local t = child:type()
        if t == "list_marker_dot" or t == "list_marker_parenthesis" then
          if #items == 0 then
            ordered = true
            local _, _, sb = child:start()
            local _, _, eb = child:end_()
            start = tonumber(extract(ctx, sb, eb, nil):match("%d+")) or 1
          end
        elseif t == "task_list_marker_checked" then
          task = "checked"
        elseif t == "task_list_marker_unchecked" then
          task = "unchecked"
        end
      end
      convert_blocks(ctx, item, blocks)
      items[#items + 1] = { task = task, blocks = blocks, source = span_from_node(item) }
    end
  end
  return {
    kind = "list",
    items = items,
    attrs = { ordered = ordered, start = start },
    source = span_from_node(node),
  }
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock
local function convert_code(ctx, node)
  local lang
  local info = child_of_type(node, "info_string")
  if info then
    local language = child_of_type(info, "language")
    if language then
      local _, _, sb = language:start()
      local _, _, eb = language:end_()
      lang = extract(ctx, sb, eb, nil)
    end
  end
  local lines = {}
  local content = child_of_type(node, "code_fence_content")
  if content then
    local _, _, sb = content:start()
    local _, _, eb = content:end_()
    local text = extract(ctx, sb, eb, nil)
    for line in (text .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = line
    end
    -- The content node's trailing newline creates one empty tail entry.
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    -- Inside quotes/lists the content keeps the container's prefix on
    -- continuation lines; strip the common leading prefix using the fence's
    -- own indentation column.
    local _, indent = node:start()
    if indent > 0 then
      for i, line in ipairs(lines) do
        local head = line:sub(1, indent)
        if head:match("^[%s>]*$") then
          lines[i] = line:sub(indent + 1)
        end
      end
    end
  end
  return {
    kind = "code",
    attrs = { lang = lang, lines = lines },
    source = span_from_node(node),
  }
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock
local function convert_indented_code(ctx, node)
  local _, _, sb = node:start()
  local _, _, eb = node:end_()
  local text = extract(ctx, sb, eb, nil)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return {
    kind = "code",
    attrs = { lang = nil, lines = lines },
    source = span_from_node(node),
  }
end

---@class MDEyeTableRow
---@field cells MDEyeTableCell[]
---@field source MDEyeSourceSpan

---@param ctx MDEyeParseCtx
---@param row TSNode
---@return MDEyeTableRow
local function convert_table_row(ctx, row)
  local cells = {}
  for cell in row:iter_children() do
    if cell:type() == "pipe_table_cell" then
      local injected = injected_for(ctx, cell)
      local runs
      if injected then
        runs = convert_inline_children(ctx, injected.root, injected.ranges)
      else
        local _, _, sb = cell:start()
        local _, _, eb = cell:end_()
        runs = {}
        push_text(ctx, runs, sb, eb, nil)
      end
      cells[#cells + 1] = { runs = runs, source = span_from_node(cell) }
    end
  end
  return { cells = cells, source = span_from_node(row) }
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock
local function convert_table(ctx, node)
  local header, rows, aligns = nil, {}, {}
  for child in node:iter_children() do
    local t = child:type()
    if t == "pipe_table_header" then
      header = convert_table_row(ctx, child)
    elseif t == "pipe_table_row" then
      rows[#rows + 1] = convert_table_row(ctx, child)
    elseif t == "pipe_table_delimiter_row" then
      for cell in child:iter_children() do
        if cell:type() == "pipe_table_delimiter_cell" then
          local left = child_of_type(cell, "pipe_table_align_left") ~= nil
          local right = child_of_type(cell, "pipe_table_align_right") ~= nil
          local align = "left"
          if left and right then
            align = "center"
          elseif right then
            align = "right"
          end
          aligns[#aligns + 1] = align
        end
      end
    end
  end
  return {
    kind = "table",
    attrs = { header = header, rows = rows, aligns = aligns },
    source = span_from_node(node),
  }
end

---@param ctx MDEyeParseCtx
---@param node TSNode
---@return MDEyeBlock|nil
local function convert_html_block(ctx, node)
  local _, _, sb = node:start()
  local _, _, eb = node:end_()
  local text = extract(ctx, sb, eb, nil):gsub("%s+$", "")
  -- Purely structural single tags (e.g. <div>, </div>, comments) are omitted;
  -- anything with visible text is kept readable as muted verbatim lines.
  local visible = text:gsub("<[^>]*>", ""):gsub("<!%-%-.-%-%->", ""):match("%S") ~= nil
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if not visible then
    return nil
  end
  return { kind = "html", attrs = { lines = lines }, source = span_from_node(node) }
end

---Collect reference-link definitions up front so reference links resolve
---regardless of definition position.
---@param ctx MDEyeParseCtx
---@param node TSNode
local function collect_refs(ctx, node)
  if node:type() == "link_reference_definition" then
    local label = child_of_type(node, "link_label")
    local dest = child_of_type(node, "link_destination")
    if label and dest then
      local _, _, lsb = label:start()
      local _, _, leb = label:end_()
      local _, _, dsb = dest:start()
      local _, _, deb = dest:end_()
      local key = normalize_ref_label(extract(ctx, lsb, leb, nil):gsub("^%[", ""):gsub("%]$", ""))
      ctx.refs[key] = extract(ctx, dsb, deb, nil)
    end
    return
  end
  for child in node:iter_children() do
    if child:named() then
      collect_refs(ctx, child)
    end
  end
end

---@param ctx MDEyeParseCtx
---@param node TSNode container (document, section, list_item, block_quote)
---@param out MDEyeBlock[]
convert_blocks = function(ctx, node, out)
  for child in node:iter_children() do
    local t = child:type()
    if t == "section" then
      convert_blocks(ctx, child, out)
    elseif t == "atx_heading" or t == "setext_heading" then
      out[#out + 1] = convert_heading(ctx, child)
    elseif t == "paragraph" then
      out[#out + 1] = {
        kind = "paragraph",
        runs = convert_inline(ctx, child_of_type(child, "inline")),
        attrs = {},
        source = span_from_node(child),
      }
    elseif t == "list" then
      out[#out + 1] = convert_list(ctx, child)
    elseif t == "block_quote" then
      local blocks = {}
      convert_blocks(ctx, child, blocks)
      out[#out + 1] =
        { kind = "quote", blocks = blocks, attrs = {}, source = span_from_node(child) }
    elseif t == "fenced_code_block" then
      out[#out + 1] = convert_code(ctx, child)
    elseif t == "indented_code_block" then
      out[#out + 1] = convert_indented_code(ctx, child)
    elseif t == "pipe_table" then
      out[#out + 1] = convert_table(ctx, child)
    elseif t == "thematic_break" then
      out[#out + 1] = { kind = "rule", attrs = {}, source = span_from_node(child) }
    elseif t == "html_block" then
      local block = convert_html_block(ctx, child)
      if block then
        out[#out + 1] = block
      end
    end
    -- link_reference_definition, markers, metadata, continuations: no output.
  end
end

---Parse a Markdown buffer into the semantic document model.
---@param bufnr integer
---@return MDEyeDocument|nil doc
---@return string|nil error
function M.parse(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "invalid buffer"
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then
    return nil, "tree-sitter markdown parser is not available"
  end
  -- parse(true) forces injected markdown_inline trees even for hidden buffers.
  local trees = parser:parse(true)
  if not trees or not trees[1] then
    return nil, "tree-sitter produced no markdown tree"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local src = table.concat(lines, "\n") .. "\n"
  local line_offsets = { 0 }
  do
    local pos = 0
    for _, line in ipairs(lines) do
      pos = pos + #line + 1
      line_offsets[#line_offsets + 1] = pos
    end
  end

  ---@type MDEyeParseCtx
  local ctx = {
    src = src,
    line_offsets = line_offsets,
    inline_index = {},
    refs = {},
  }

  local inline_ltree = parser:children()["markdown_inline"]
  if inline_ltree then
    local regions = inline_ltree:included_regions()
    for i, tree in pairs(inline_ltree:trees()) do
      local ranges = {}
      for _, range in ipairs(regions[i] or {}) do
        -- Range6: {start_row, start_col, start_byte, end_row, end_col, end_byte}
        ranges[#ranges + 1] = { range[3], range[6] }
      end
      local root = tree:root()
      local sr, sc, er, ec = root:range()
      ctx.inline_index[("%d:%d:%d:%d"):format(sr, sc, er, ec)] =
        { root = root, ranges = #ranges > 0 and ranges or nil }
    end
  end

  local root = trees[1]:root()
  collect_refs(ctx, root)

  local blocks = {}
  convert_blocks(ctx, root, blocks)
  return { blocks = blocks }, nil
end

return M
