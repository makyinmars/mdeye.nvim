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
---@field kind "text"|"emphasis"|"strong"|"strike"|"code"|"link"|"image"|"footnote"|"break"
---@field text string|nil normalized display text (leaf kinds)
---@field source MDEyeSourceSpan
---@field target string|nil link/image/footnote destination
---@field label string|nil normalized footnote label
---@field children MDEyeInline[]|nil container kinds

---@class MDEyeListItem
---@field task nil|"checked"|"unchecked"
---@field source MDEyeSourceSpan
---@field blocks MDEyeBlock[]

---@class MDEyeTableCell
---@field runs MDEyeInline[]
---@field source MDEyeSourceSpan

---@class MDEyeCodeCapture
---@field row integer 0-based row inside the fenced content
---@field start_col integer byte column, inclusive
---@field end_col integer byte column, exclusive
---@field capture string Tree-sitter capture name
---@field order integer query capture order
---@field priority integer|nil priority supplied by query metadata

---@class MDEyeBlockAttrs
---@field level integer|nil heading
---@field title string|nil heading
---@field anchor string|nil heading/footnote
---@field ordered boolean|nil list
---@field start integer|nil list start number
---@field lang string|nil code fence label
---@field lines string[]|nil code/html content
---@field highlights MDEyeCodeCapture[]|nil code syntax captures
---@field diagram MDEyeMermaidGraph|nil parsed Mermaid flowchart
---@field diagram_error string|nil native Mermaid fallback reason
---@field highlight_lang string|nil resolved code parser language
---@field header MDEyeTableRow|nil table header
---@field rows MDEyeTableRow[]|nil table body
---@field aligns string[]|nil table alignments
---@field label string|nil footnote label
---@field ordinal integer|nil footnote number
---@field alert "note"|"tip"|"important"|"warning"|"caution"|nil quote alert type

---@class MDEyeBlock
---@field kind "heading"|"paragraph"|"list"|"quote"|"code"|"table"|"rule"|"html"|"footnote"
---@field source MDEyeSourceSpan
---@field runs MDEyeInline[]|nil heading, paragraph, footnote
---@field items MDEyeListItem[]|nil list
---@field blocks MDEyeBlock[]|nil quote or continued footnote content
---@field attrs MDEyeBlockAttrs

---@class MDEyeCodeLanguageStatus
---@field highlight_lang string|nil resolved parser language; nil means plain-text fallback

---@class MDEyeDocument
---@field blocks MDEyeBlock[]
---@field anchors table<string, MDEyeSourceSpan>
---@field code_languages table<string, MDEyeCodeLanguageStatus>

---Parse state shared by the conversion walk.
---@class MDEyeFootnoteDef
---@field label string normalized label
---@field anchor string
---@field content_start integer
---@field ordinal integer|nil

---@class MDEyeParseCtx
---@field src string full source text
---@field line_offsets integer[] byte offset of the start of each 0-based row
---@field inline_index table<string, {root: TSNode, ranges: integer[][]}>
---@field refs table<string, string> normalized reference label -> destination
---@field footnotes table<string, MDEyeFootnoteDef>
---@field footnote_nodes table<integer, MDEyeFootnoteDef> paragraph start byte -> definition
---@field next_footnote integer

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

---Generate the same practical anchor shape used by GitHub Markdown headings:
---lowercase text, ASCII punctuation removed, and whitespace replaced by `-`.
---Non-ASCII letters are retained so translated documents remain linkable.
---@param text string
---@return string
function M.slug(text)
  local out = {}
  text = vim.fn.tolower(vim.trim(text))
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    local byte = ch:byte()
    if not byte or byte >= 128 or ch:match("^[%w_ %-]$") then
      out[#out + 1] = ch
    end
  end
  local slug = table.concat(out):gsub("%s+", "-")
  return slug ~= "" and slug or "section"
end

---Normalize an href fragment before looking it up in a render plan.
---@param fragment string
---@return string
function M.normalize_anchor(fragment)
  fragment = fragment:gsub("^#", "")
  fragment = fragment:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return vim.fn.tolower(fragment)
end

---Resolve a fragment to the exact anchor id used by a document or render plan.
---@param anchors table<string, unknown>
---@param fragment string
---@return string|nil
function M.anchor_id(anchors, fragment)
  local id = M.normalize_anchor(fragment)
  if anchors[id] then
    return id
  end
  local slug = M.slug(id)
  return anchors[slug] and slug or nil
end

---@param anchors table<string, unknown>
---@param base string
---@return string
local function allocate_anchor(anchors, base)
  local anchor = base
  local suffix = 1
  while anchors[anchor] do
    anchor = base .. "-" .. suffix
    suffix = suffix + 1
  end
  return anchor
end

---@param ctx MDEyeParseCtx
---@param def MDEyeFootnoteDef
---@return integer
local function ensure_footnote_ordinal(ctx, def)
  if not def.ordinal then
    def.ordinal = ctx.next_footnote
    ctx.next_footnote = ctx.next_footnote + 1
  end
  return def.ordinal
end

local inline_converters

---Append a plain text run unless empty.
local function push_text(ctx, out, sb, eb, ranges)
  local text = extract(ctx, sb, eb, ranges)
  if text ~= "" then
    out[#out + 1] = { kind = "text", text = text, source = span_from_bytes(ctx, sb, eb) }
  end
end

---@param sb integer
---@param eb integer
---@param ranges integer[][]|nil
---@return boolean
local function intersects_ranges(sb, eb, ranges)
  if not ranges then
    return true
  end
  for _, range in ipairs(ranges) do
    if math.max(sb, range[1]) < math.min(eb, range[2]) then
      return true
    end
  end
  return false
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
      if intersects_ranges(csb, ceb, ranges) then
        local converter = inline_converters[child:type()]
        if converter then
          converter(ctx, child, ranges, out)
        else
          -- Unknown constructs stay readable as plain text.
          push_text(ctx, out, csb, ceb, ranges)
        end
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

---@param node TSNode
---@param ... string
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

---@param ctx MDEyeParseCtx
---@param node TSNode
---@param ranges integer[][]|nil
---@param out MDEyeInline[]
local function convert_reference_link(ctx, node, ranges, out)
  local text = child_of_type(node, "link_text")
  if text then
    local _, _, sb = text:start()
    local _, _, eb = text:end_()
    local label = extract(ctx, sb, eb, ranges)
    if label:sub(1, 1) == "^" then
      local def = ctx.footnotes[normalize_ref_label(label:sub(2))]
      if def then
        local ordinal = ensure_footnote_ordinal(ctx, def)
        out[#out + 1] = {
          kind = "footnote",
          text = ("[%d]"):format(ordinal),
          target = "#" .. def.anchor,
          label = def.label,
          source = span_from_node(node),
        }
      else
        out[#out + 1] = {
          kind = "text",
          text = "[" .. label .. "]",
          source = span_from_node(node),
        }
      end
      return
    end
  end

  local children = text and convert_inline_children(ctx, text, ranges) or {}
  out[#out + 1] = {
    kind = "link",
    children = children,
    target = link_target_from_ref(ctx, node, ranges),
    source = span_from_node(node),
  }
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

  full_reference_link = convert_reference_link,

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

  hard_line_break = function(_, node, _, out)
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

---Convert only [start_byte, end_byte) of a block inline node. Footnote
---definitions use this to omit `[^label]:` while retaining ordinary inline
---styling in the definition body.
---@param ctx MDEyeParseCtx
---@param node TSNode|nil
---@param start_byte integer
---@param end_byte integer
---@return MDEyeInline[]
local function convert_inline_range(ctx, node, start_byte, end_byte)
  if not node then
    return {}
  end
  local injected = injected_for(ctx, node)
  if not injected then
    local out = {}
    push_text(ctx, out, start_byte, end_byte, nil)
    return out
  end
  local ranges = {}
  for _, range in ipairs(injected.ranges or { { start_byte, end_byte } }) do
    local sb = math.max(start_byte, range[1])
    local eb = math.min(end_byte, range[2])
    if sb < eb then
      ranges[#ranges + 1] = { sb, eb }
    end
  end
  return convert_inline_children(ctx, injected.root, ranges)
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

local code_language_aliases = {
  cjs = "javascript",
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  py = "python",
  rb = "ruby",
  sh = "bash",
  shell = "bash",
  ts = "typescript",
  yml = "yaml",
  ["c++"] = "cpp",
  ["c#"] = "c_sharp",
}

local code_query_cache = {}

---Parse fenced content with its language parser and normalize highlight
---captures into line-local byte ranges. Missing parsers/queries deliberately
---return an empty list: fenced text remains fully readable.
---@param lines string[]
---@param label string|nil
---@return MDEyeCodeCapture[] highlights
---@return string|nil language
local function code_highlights(lines, label)
  if not label or label == "" or #lines == 0 then
    return {}, nil
  end
  local raw = label:lower()
  local lang = code_language_aliases[raw] or raw
  local code = table.concat(lines, "\n")
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok_parser or not parser then
    return {}, nil
  end

  local query = code_query_cache[lang]
  if query == nil then
    local ok_query
    ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not ok_query or not query then
      return {}, nil
    end
    code_query_cache[lang] = query
  end

  local ok, highlights = pcall(function()
    local trees = parser:parse()
    if not trees or not trees[1] then
      return {}
    end
    local out = {}
    local sequence = 0
    for id, capture, metadata in query:iter_captures(trees[1]:root(), code, 0, -1) do
      local name = query.captures[id]
      if name and name:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = capture:range()
        sequence = sequence + 1
        local capture_metadata = metadata and (metadata[id] or metadata) or {}
        local priority = tonumber(capture_metadata.priority)
        for row = sr, er do
          local line = lines[row + 1]
          if line then
            local start_col = row == sr and sc or 0
            local end_col = row == er and ec or #line
            if start_col < end_col then
              out[#out + 1] = {
                row = row,
                start_col = start_col,
                end_col = end_col,
                capture = name,
                order = sequence,
                priority = priority,
              }
            end
          end
        end
      end
    end
    return out
  end)
  return ok and highlights or {}, ok and lang or nil
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
  local diagram, diagram_error
  local highlights, highlight_lang = {}, nil
  if lang and lang:lower() == "mermaid" then
    diagram, diagram_error = require("mdeye.mermaid").parse(lines)
  else
    highlights, highlight_lang = code_highlights(lines, lang)
  end
  return {
    kind = "code",
    attrs = {
      lang = lang,
      lines = lines,
      highlights = highlights,
      highlight_lang = highlight_lang,
      diagram = diagram,
      diagram_error = diagram_error,
    },
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
    attrs = { lang = nil, lines = lines, highlights = {}, highlight_lang = nil },
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

---The bundled Markdown grammar treats GFM footnotes as ordinary shortcut
---links and paragraphs. Recognize definition paragraphs up front so inline
---conversion can resolve references regardless of source order.
---@param ctx MDEyeParseCtx
---@param node TSNode
local function collect_footnotes(ctx, node)
  local node_type = node:type()
  if node_type == "paragraph" or node_type == "link_reference_definition" then
    local _, _, sb = node:start()
    local _, _, eb = node:end_()
    local raw = extract(ctx, sb, eb, nil)
    local _, prefix_end, label = raw:find("^%[%^([^%]]+)%]:[ \t]*")
    if label then
      local key = normalize_ref_label(label)
      local def = ctx.footnotes[key]
      if not def then
        def = {
          label = key,
          anchor = "fn-" .. M.slug(key),
          content_start = sb + prefix_end,
        }
        ctx.footnotes[key] = def
      end
      ctx.footnote_nodes[sb] = def
    end
    return
  end
  for child in node:iter_children() do
    if child:named() then
      collect_footnotes(ctx, child)
    end
  end
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
---@param node TSNode
---@param footnote MDEyeFootnoteDef
---@return MDEyeBlock
local function convert_footnote_definition(ctx, node, footnote)
  local span = span_from_node(node)
  local inline = child_of_type(node, "inline")
  local runs
  if inline then
    runs = convert_inline_range(ctx, inline, footnote.content_start, span.end_byte)
  else
    local content_end = span.end_byte
    while content_end > footnote.content_start do
      local last = ctx.src:sub(content_end, content_end)
      if last ~= "\n" and last ~= "\r" then
        break
      end
      content_end = content_end - 1
    end
    runs = {}
    push_text(ctx, runs, footnote.content_start, content_end, nil)
  end
  return {
    kind = "footnote",
    runs = runs,
    attrs = {
      label = footnote.label,
      ordinal = footnote.ordinal,
      anchor = footnote.anchor,
    },
    source = span,
  }
end

---@param runs MDEyeInline[]
---@param rebase fun(span: MDEyeSourceSpan)
local function rebase_inline_sources(runs, rebase)
  for _, run in ipairs(runs) do
    rebase(run.source)
    if run.children then
      rebase_inline_sources(run.children, rebase)
    end
  end
end

local rebase_block_sources

---@param row MDEyeTableRow
---@param rebase fun(span: MDEyeSourceSpan)
local function rebase_table_row_sources(row, rebase)
  rebase(row.source)
  for _, cell in ipairs(row.cells) do
    rebase(cell.source)
    rebase_inline_sources(cell.runs, rebase)
  end
end

---@param blocks MDEyeBlock[]
---@param rebase fun(span: MDEyeSourceSpan)
rebase_block_sources = function(blocks, rebase)
  for _, block in ipairs(blocks) do
    rebase(block.source)
    if block.runs then
      rebase_inline_sources(block.runs, rebase)
    end
    if block.blocks then
      rebase_block_sources(block.blocks, rebase)
    end
    for _, item in ipairs(block.items or {}) do
      rebase(item.source)
      rebase_block_sources(item.blocks, rebase)
    end
    if block.attrs.header then
      rebase_table_row_sources(block.attrs.header, rebase)
    end
    for _, row in ipairs(block.attrs.rows or {}) do
      rebase_table_row_sources(row, rebase)
    end
  end
end

---Parse an indented footnote continuation as ordinary Markdown, then map its
---semantic blocks back onto the original source coordinates.
---@param ctx MDEyeParseCtx
---@param span MDEyeSourceSpan
---@return MDEyeBlock[]
local function parse_footnote_continuation(ctx, span)
  local raw = extract(ctx, span.start_byte, span.end_byte, nil)
  local raw_lines = vim.split(raw, "\n", { plain = true })
  if raw_lines[#raw_lines] == "" then
    raw_lines[#raw_lines] = nil
  end

  local lines, raw_offsets, local_offsets, indents = {}, {}, {}, {}
  local raw_offset, local_offset = 0, 0
  for index, line in ipairs(raw_lines) do
    local indent = line:sub(1, 4) == "    " and 4 or (line:sub(1, 1) == "\t" and 1 or 0)
    local stripped = line:sub(indent + 1)
    lines[index] = stripped
    raw_offsets[index] = raw_offset
    local_offsets[index] = local_offset
    indents[index] = indent
    raw_offset = raw_offset + #line + 1
    local_offset = local_offset + #stripped + 1
  end
  if #lines == 0 then
    return {}
  end

  local content_line_count = #lines
  local fallback = {
    kind = "paragraph",
    runs = {
      {
        kind = "text",
        text = table.concat(lines, "\n"),
        source = vim.deepcopy(span),
      },
    },
    attrs = {},
    source = vim.deepcopy(span),
  }
  local labels = vim.tbl_keys(ctx.refs)
  table.sort(labels)
  if #labels > 0 then
    lines[#lines + 1] = ""
    for _, label in ipairs(labels) do
      lines[#lines + 1] = ("[%s]: %s"):format(label, ctx.refs[label])
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local parsed
  local ok = pcall(function()
    parsed = M.parse(bufnr)
  end)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if not ok or not parsed then
    return { fallback }
  end

  local blocks = {}
  for _, block in ipairs(parsed.blocks) do
    if block.source.start_row < content_line_count then
      blocks[#blocks + 1] = block
    end
  end

  local function row_for_byte(byte)
    local lo, hi = 1, #local_offsets
    while lo < hi do
      local mid = math.ceil((lo + hi) / 2)
      if local_offsets[mid] <= byte then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo
  end

  local function original_byte(byte)
    local row = row_for_byte(byte)
    local col = math.max(byte - local_offsets[row], 0)
    return span.start_byte + raw_offsets[row] + indents[row] + col
  end

  local function original_end_byte(byte)
    local row = row_for_byte(byte)
    if row > 1 and byte == local_offsets[row] then
      return span.start_byte + raw_offsets[row]
    end
    return original_byte(byte)
  end

  rebase_block_sources(blocks, function(source)
    source.start_byte = original_byte(source.start_byte)
    source.end_byte = original_end_byte(source.end_byte)
    source.start_row = span.start_row + source.start_row
    source.end_row = span.start_row + source.end_row
  end)
  return #blocks > 0 and blocks or { fallback }
end

---@param ctx MDEyeParseCtx
---@param footnote MDEyeBlock
---@param node TSNode
local function append_footnote_continuation(ctx, footnote, node)
  local span = span_from_node(node)
  footnote.blocks = footnote.blocks or {}
  vim.list_extend(footnote.blocks, parse_footnote_continuation(ctx, span))
  footnote.source.end_byte = span.end_byte
  footnote.source.end_row = span.end_row
end

local alert_types = {
  NOTE = "note",
  TIP = "tip",
  IMPORTANT = "important",
  WARNING = "warning",
  CAUTION = "caution",
}

---Recognize a GitHub-style alert marker in the first quote paragraph and
---consume it so only the alert title and body reach layout.
---@param blocks MDEyeBlock[]
---@return string|nil alert
local function consume_alert_marker(blocks)
  local paragraph = blocks[1]
  local runs = paragraph and paragraph.kind == "paragraph" and paragraph.runs or nil
  local marker = runs and runs[1] or nil
  if not marker or marker.kind ~= "link" or not marker.children or #marker.children ~= 1 then
    return nil
  end
  local marker_text = marker.children[1]
  local name = marker_text.kind == "text" and marker_text.text:match("^!([%a]+)$") or nil
  local alert = name and alert_types[name:upper()] or nil
  if not alert then
    return nil
  end

  -- The marker must occupy the first quote line by itself. The inline parser
  -- represents the following quote line as a leading newline on the next text
  -- run; a marker-only paragraph has no next run.
  local next_run = runs[2]
  if next_run and (next_run.kind ~= "text" or not next_run.text:match("^[ \t]*\n")) then
    return nil
  end

  table.remove(runs, 1)
  if runs[1] then
    runs[1].text = runs[1].text:gsub("^[ \t]*\n[ \t]*", "", 1)
    if runs[1].text == "" then
      table.remove(runs, 1)
    end
  end
  if #runs == 0 then
    table.remove(blocks, 1)
  end
  return alert
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
    elseif t == "paragraph" or t == "link_reference_definition" then
      local _, _, sb = child:start()
      local footnote = ctx.footnote_nodes[sb]
      if footnote then
        out[#out + 1] = convert_footnote_definition(ctx, child, footnote)
      elseif t == "paragraph" then
        out[#out + 1] = {
          kind = "paragraph",
          runs = convert_inline(ctx, child_of_type(child, "inline")),
          attrs = {},
          source = span_from_node(child),
        }
      end
    elseif t == "list" then
      out[#out + 1] = convert_list(ctx, child)
    elseif t == "block_quote" then
      local blocks = {}
      convert_blocks(ctx, child, blocks)
      out[#out + 1] = {
        kind = "quote",
        blocks = blocks,
        attrs = { alert = consume_alert_marker(blocks) },
        source = span_from_node(child),
      }
    elseif t == "fenced_code_block" then
      out[#out + 1] = convert_code(ctx, child)
    elseif t == "indented_code_block" then
      local previous = out[#out]
      local start_row = child:start()
      if previous and previous.kind == "footnote" and start_row - previous.source.end_row <= 2 then
        append_footnote_continuation(ctx, previous, child)
      else
        out[#out + 1] = convert_indented_code(ctx, child)
      end
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

---@param runs MDEyeInline[]|nil
---@return string
local function inline_text(runs)
  local parts = {}
  for _, run in ipairs(runs or {}) do
    if run.kind == "break" then
      parts[#parts + 1] = " "
    elseif run.text then
      parts[#parts + 1] = run.text
    end
    if run.children then
      parts[#parts + 1] = inline_text(run.children)
    end
  end
  return table.concat(parts)
end

---@param blocks MDEyeBlock[]
---@param visit fun(block: MDEyeBlock)
local function walk_blocks(blocks, visit)
  for _, block in ipairs(blocks) do
    visit(block)
    if block.blocks then
      walk_blocks(block.blocks, visit)
    elseif block.items then
      for _, item in ipairs(block.items) do
        walk_blocks(item.blocks, visit)
      end
    end
  end
end

---@param blocks MDEyeBlock[]
---@param anchors table<string, MDEyeSourceSpan>
local function assign_heading_anchors(blocks, anchors)
  walk_blocks(blocks, function(block)
    if block.kind ~= "heading" then
      return
    end
    local title = vim.trim(inline_text(block.runs):gsub("%s+", " "))
    local base = M.slug(title)
    local anchor = allocate_anchor(anchors, base)
    block.attrs.title = title
    block.attrs.anchor = anchor
    anchors[anchor] = block.source
  end)
end

---@param blocks MDEyeBlock[]
---@param ctx MDEyeParseCtx
---@param anchors table<string, MDEyeSourceSpan>
local function finalize_footnotes(blocks, ctx, anchors)
  walk_blocks(blocks, function(block)
    if block.kind ~= "footnote" then
      return
    end
    local def = ctx.footnotes[block.attrs.label]
    block.attrs.ordinal = ensure_footnote_ordinal(ctx, def)
    local anchor = allocate_anchor(anchors, def.anchor)
    def.anchor = anchor
    block.attrs.anchor = anchor
    anchors[anchor] = block.source
  end)
end

---@param blocks MDEyeBlock[]
---@return table<string, MDEyeCodeLanguageStatus>
local function collect_code_languages(blocks)
  local languages = {}
  walk_blocks(blocks, function(block)
    if block.kind == "code" and block.attrs.lang then
      local label = block.attrs.lang
      local status = languages[label] or {}
      status.highlight_lang = status.highlight_lang or block.attrs.highlight_lang
      languages[label] = status
    end
  end)
  return languages
end

---@param runs MDEyeInline[]
---@param ctx MDEyeParseCtx
local function update_footnote_runs(runs, ctx)
  for _, run in ipairs(runs) do
    if run.kind == "footnote" and run.label then
      run.target = "#" .. ctx.footnotes[run.label].anchor
    end
    if run.children then
      update_footnote_runs(run.children, ctx)
    end
  end
end

---@param blocks MDEyeBlock[]
---@param ctx MDEyeParseCtx
local function update_footnote_targets(blocks, ctx)
  walk_blocks(blocks, function(block)
    if block.runs then
      update_footnote_runs(block.runs, ctx)
    end
    if block.kind == "table" then
      local rows = {}
      if block.attrs.header then
        rows[#rows + 1] = block.attrs.header
      end
      vim.list_extend(rows, block.attrs.rows)
      for _, row in ipairs(rows) do
        for _, cell in ipairs(row.cells) do
          update_footnote_runs(cell.runs, ctx)
        end
      end
    end
  end)
end

---@class MDEyeParserDiagnostics
---@field parsers table<string, boolean>
---@field table_injection boolean|nil
---@field error string|nil

---Inspect the Markdown parser stack. Keeping this here preserves the rule
---that Tree-sitter is only accessed through document.lua.
---@return MDEyeParserDiagnostics
function M.parser_diagnostics()
  local result = { parsers = {} }
  for _, lang in ipairs({ "markdown", "markdown_inline" }) do
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    result.parsers[lang] = ok and loaded == true
  end
  if not result.parsers.markdown or not result.parsers.markdown_inline then
    return result
  end

  local sample = "| a |\n| - |\n| b |\n"
  local ok, parser = pcall(vim.treesitter.get_string_parser, sample, "markdown")
  if not ok or not parser then
    result.error = "could not create a markdown string parser"
    return result
  end
  parser:parse(true)
  local inline = parser:children()["markdown_inline"]
  local regions = inline and inline:included_regions() or {}
  local count = 0
  for _, region in pairs(regions) do
    count = count + #region
  end
  result.table_injection = count >= 2
  return result
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
    footnotes = {},
    footnote_nodes = {},
    next_footnote = 1,
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
  collect_footnotes(ctx, root)
  collect_refs(ctx, root)

  local blocks = {}
  convert_blocks(ctx, root, blocks)
  local anchors = {}
  assign_heading_anchors(blocks, anchors)
  finalize_footnotes(blocks, ctx, anchors)
  update_footnote_targets(blocks, ctx)
  return {
    blocks = blocks,
    anchors = anchors,
    code_languages = collect_code_languages(blocks),
  },
    nil
end

return M
