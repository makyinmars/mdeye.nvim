---Pure layout: semantic document + width policy -> complete render plan.
---
---The same document, options, and measure function always produce the same
---plan. Display-cell widths and Lua byte offsets are tracked as separate
---values end to end: wrapping decisions use cells, mark columns use bytes.
local M = {}

---@class MDEyeMark
---@field row integer 0-based preview row
---@field start_col integer byte column in the generated line
---@field end_col integer byte column, exclusive
---@field hl string
---@field target string|nil link destination for interaction
---@field priority integer

---@class MDEyeBlockMap
---@field row_start integer 0-based preview row, inclusive
---@field row_end integer 0-based preview row, inclusive
---@field source MDEyeSourceSpan

---@class MDEyeHeadingMap
---@field row integer 0-based preview row
---@field level integer
---@field title string
---@field anchor string
---@field source MDEyeSourceSpan

---@class MDEyeAnchorMap
---@field row integer 0-based preview row
---@field source MDEyeSourceSpan

---@class MDEyeCodeBlockMap
---@field row_start integer 0-based preview row, including the language label
---@field row_end integer 0-based preview row
---@field source MDEyeSourceSpan
---@field lines string[] original fenced content
---@field lang string|nil

---@class MDEyeImageReservation
---@field key string cached image identity
---@field row_start integer 0-based first reserved buffer row
---@field row_end integer 0-based last reserved buffer row
---@field col integer left edge in display cells
---@field width integer
---@field height integer

---@class MDEyeRenderPlan
---@field lines string[]
---@field text string[] content without container prefixes
---@field images MDEyeImageReservation[]
---@field row_keys table<integer, string> semantic diagram row identities
---@field marks MDEyeMark[]
---@field blocks MDEyeBlockMap[] ordered by row_start; nested blocks follow parents
---@field headings MDEyeHeadingMap[]
---@field anchors table<string, MDEyeAnchorMap>
---@field code_blocks MDEyeCodeBlockMap[]
---@field width integer content width in display cells
---@field margin integer left margin in display cells

---@class MDEyeLayoutOpts
---@field usable_width integer owner window text width in cells
---@field max_width integer|false false uses the full available window width
---@field min_margin integer
---@field tab_width integer|nil defaults to 4
---@field mermaid_enabled boolean|nil render supported Mermaid diagrams; defaults to true
---@field mermaid_layout "graph"|"connections"|nil
---@field image_specs table<integer, MDEyeImageSpec>|nil indexed by source start byte
---@field code_wrap boolean|nil wrap fenced lines to the content width
---@field measure fun(s: string): integer display cells; defaults to strdisplaywidth

local MIN_CONTENT = 20
local TABLE_CELL_MIN = 3

local PRIORITY_BLOCK = 100
local PRIORITY_INLINE = 110
local PRIORITY_CODE = 120

---@class MDEyeFrag
---@field text string
---@field hls string[]|nil
---@field target string|nil

---A fragment list plus running width, forming one wrap-atomic word.
---@class MDEyeAtom
---@field frags MDEyeFrag[]
---@field width integer
---@field brk boolean|nil hard line break marker

local function frag(text, hls, target)
  return { text = text, hls = hls, target = target }
end

local style_hl = {
  emphasis = "MDEyeEmphasis",
  strong = "MDEyeStrong",
  strike = "MDEyeStrike",
}

---Flatten an inline run tree to styled text segments.
---@param runs MDEyeInline[]
---@param hls string[]|nil
---@param target string|nil
---@param out table[]
local function flatten_runs(runs, hls, target, out)
  for _, run in ipairs(runs) do
    if run.kind == "text" then
      out[#out + 1] = { text = run.text, hls = hls, target = target }
    elseif run.kind == "break" then
      out[#out + 1] = { brk = true }
    elseif run.kind == "code" then
      local nhls = { "MDEyeCode" }
      vim.list_extend(nhls, hls or {})
      out[#out + 1] = { text = run.text, hls = nhls, target = target }
    elseif run.kind == "link" then
      local nhls = { "MDEyeLink" }
      vim.list_extend(nhls, hls or {})
      flatten_runs(run.children or {}, nhls, run.target or target, out)
    elseif run.kind == "image" then
      local nhls = { "MDEyeLink" }
      vim.list_extend(nhls, hls or {})
      out[#out + 1] = { text = run.text or "image", hls = nhls, target = run.target or target }
    elseif run.kind == "footnote" then
      local nhls = { "MDEyeFootnote" }
      vim.list_extend(nhls, hls or {})
      out[#out + 1] = { text = run.text or "[?]", hls = nhls, target = run.target or target }
    elseif run.children then
      local hl = style_hl[run.kind]
      local nhls = hl and { hl } or {}
      vim.list_extend(nhls, hls or {})
      flatten_runs(run.children, nhls, target, out)
    elseif run.text then
      out[#out + 1] = { text = run.text, hls = hls, target = target }
    end
  end
end

---Split segments into wrap atoms (words). Whitespace, including source
---newlines inside paragraphs, collapses into inter-atom glue.
---@param segments table[]
---@param measure fun(s: string): integer
---@return MDEyeAtom[]
local function to_atoms(segments, measure)
  local atoms = {}
  local open = nil
  local function close()
    if open then
      atoms[#atoms + 1] = open
      open = nil
    end
  end
  for _, seg in ipairs(segments) do
    if seg.brk then
      close()
      atoms[#atoms + 1] = { brk = true }
    else
      local text = seg.text:gsub("\t", " ")
      local pos = 1
      while pos <= #text do
        local ws_s, ws_e = text:find("^%s+", pos)
        if ws_s then
          close()
          pos = ws_e + 1
        else
          local word = text:match("^%S+", pos)
          open = open or { frags = {}, width = 0 }
          open.frags[#open.frags + 1] = frag(word, seg.hls, seg.target)
          open.width = open.width + measure(word)
          pos = pos + #word
        end
      end
    end
  end
  close()
  return atoms
end

---Split one overlong atom into pieces no wider than `avail`, preserving
---fragment style boundaries and never producing an empty piece.
---@param atom MDEyeAtom
---@param avail integer
---@param measure fun(s: string): integer
---@return MDEyeAtom[]
local function split_atom(atom, avail, measure)
  local pieces = {}
  local cur = { frags = {}, width = 0 }
  local function flush()
    if #cur.frags > 0 then
      pieces[#pieces + 1] = cur
      cur = { frags = {}, width = 0 }
    end
  end
  for _, f in ipairs(atom.frags) do
    local pending = nil
    for _, ch in ipairs(vim.fn.split(f.text, "\\zs")) do
      local w = measure(ch)
      if cur.width + w > avail and cur.width > 0 then
        if pending then
          cur.frags[#cur.frags + 1] = pending
          pending = nil
        end
        flush()
      end
      if pending then
        pending.text = pending.text .. ch
      else
        pending = frag(ch, f.hls, f.target)
      end
      cur.width = cur.width + w
    end
    if pending then
      cur.frags[#cur.frags + 1] = pending
    end
  end
  flush()
  return pieces
end

---Greedy word wrap by display cells.
---@param atoms MDEyeAtom[]
---@param avail integer
---@param measure fun(s: string): integer
---@return MDEyeFrag[][] lines
local function wrap_atoms(atoms, avail, measure)
  avail = math.max(avail, 1)
  local lines = {}
  local cur, cur_w = {}, 0
  local function flush()
    lines[#lines + 1] = cur
    cur, cur_w = {}, 0
  end
  local function place(atom)
    if #cur > 0 then
      -- Glue takes the style shared by both neighbours so an emphasized
      -- phrase keeps a continuous style run.
      local prev = cur[#cur]
      local nxt = atom.frags[1]
      local hls = (prev.hls and nxt.hls and vim.deep_equal(prev.hls, nxt.hls)) and prev.hls or nil
      cur[#cur + 1] = frag(" ", hls, hls and prev.target == nxt.target and prev.target or nil)
      cur_w = cur_w + 1
    end
    vim.list_extend(cur, atom.frags)
    cur_w = cur_w + atom.width
  end
  for _, atom in ipairs(atoms) do
    if atom.brk then
      flush()
    else
      local sep = #cur > 0 and 1 or 0
      if cur_w + sep + atom.width <= avail then
        place(atom)
      elseif atom.width <= avail then
        flush()
        place(atom)
      else
        -- Overlong token: split only when it cannot fit on an empty line.
        if #cur > 0 then
          flush()
        end
        for _, piece in ipairs(split_atom(atom, avail, measure)) do
          if cur_w + (#cur > 0 and 1 or 0) + piece.width > avail and #cur > 0 then
            flush()
          end
          place(piece)
        end
      end
    end
  end
  if #cur > 0 or #lines == 0 then
    flush()
  end
  return lines
end

---Wrap inline runs into fragment lines.
---@param runs MDEyeInline[]
---@param avail integer
---@param measure fun(s: string): integer
---@param base_hls string[]|nil style override applied to every fragment
---@return MDEyeFrag[][]
local function wrap_runs(runs, avail, measure, base_hls)
  local segments = {}
  flatten_runs(runs, nil, nil, segments)
  if base_hls then
    for _, seg in ipairs(segments) do
      if not seg.brk then
        seg.hls = base_hls
      end
    end
  end
  local atoms = to_atoms(segments, measure)
  if #atoms == 0 then
    return {}
  end
  return wrap_atoms(atoms, avail, measure)
end

---Layout emission context. Owns the growing plan and the margin prefix.
---@class MDEyeLayoutCtx
---@field plan MDEyeRenderPlan
---@field measure fun(s: string): integer
---@field tab_width integer
---@field code_wrap boolean
---@field mermaid_enabled boolean
---@field mermaid_layout "graph"|"connections"
---@field image_specs table<integer, MDEyeImageSpec>
local Ctx = {}
Ctx.__index = Ctx

---@return integer row emitted 0-based row
function Ctx:emit(prefix, frags)
  -- One-shot prefix override: the first content line of a list item carries
  -- the item marker; every following line uses the hanging indent.
  if self.pending_first_prefix and frags then
    prefix = self.pending_first_prefix
    self.pending_first_prefix = nil
  end
  local plan = self.plan
  local row = #plan.lines
  local text = {}
  for _, f in ipairs(frags or {}) do
    text[#text + 1] = f.text
  end
  plan.text[row + 1] = table.concat(text)
  local parts = { string.rep(" ", plan.margin) }
  local col = plan.margin -- margin is ASCII spaces: bytes == cells
  local all = {}
  vim.list_extend(all, prefix or {})
  vim.list_extend(all, frags or {})
  -- Trim trailing whitespace so blank and gutter-only lines stay clean;
  -- fragments marked `keep` (code-block background padding) are preserved.
  while #all > 0 do
    local last = all[#all]
    if last.keep then
      break
    end
    local trimmed = last.text:gsub("%s+$", "")
    if trimmed == "" then
      all[#all] = nil
    else
      if trimmed ~= last.text then
        local copy = frag(trimmed, last.hls, last.target)
        all[#all] = copy
      end
      break
    end
  end
  for _, f in ipairs(all) do
    if f.text ~= "" then
      parts[#parts + 1] = f.text
      local s, e = col, col + #f.text
      if f.hls then
        for _, hl in ipairs(f.hls) do
          plan.marks[#plan.marks + 1] = {
            row = row,
            start_col = s,
            end_col = e,
            hl = hl,
            target = f.target,
            priority = PRIORITY_INLINE,
          }
        end
      elseif f.target then
        plan.marks[#plan.marks + 1] = {
          row = row,
          start_col = s,
          end_col = e,
          hl = "MDEyeLink",
          target = f.target,
          priority = PRIORITY_INLINE,
        }
      end
      col = e
    end
  end
  local line = table.concat(parts)
  if line:match("^%s*$") and not (frags and frags[#frags] and frags[#frags].reserve) then
    line = line:gsub("%s+$", "")
    while plan.marks[#plan.marks] and plan.marks[#plan.marks].row == row do
      plan.marks[#plan.marks] = nil
    end
  end
  plan.lines[#plan.lines + 1] = line
  return row
end

---Add one full-width block-background mark on a row.
function Ctx:block_mark(row, hl)
  local plan = self.plan
  plan.marks[#plan.marks + 1] = {
    row = row,
    start_col = math.min(plan.margin, #plan.lines[row + 1]),
    end_col = #plan.lines[row + 1],
    hl = hl,
    priority = PRIORITY_BLOCK,
  }
end

function Ctx:register_block(span, row_start, row_end)
  self.plan.blocks[#self.plan.blocks + 1] = {
    row_start = row_start,
    row_end = row_end,
    source = span,
  }
end

local render_blocks

---@param ctx MDEyeLayoutCtx
local function render_paragraph(ctx, block, prefix, avail)
  local lines = wrap_runs(block.runs, avail, ctx.measure)
  if #lines == 0 then
    return
  end
  local first, last
  for _, lfrags in ipairs(lines) do
    local row = ctx:emit(prefix, lfrags)
    first = first or row
    last = row
  end
  local image = ctx.image_specs[block.source.start_byte]
  if image then
    local width = math.min(avail, image.max_width)
    local height = math.max(1, math.min(image.max_height, math.ceil(width * image.aspect * 0.5)))
    local col = ctx.plan.margin
    for _, f in ipairs(prefix) do
      col = col + ctx.measure(f.text)
    end
    local start = #ctx.plan.lines
    for _ = 1, height do
      -- Real padding keeps backend screenpos() columns accurate, including in quotes.
      local spacer = frag(string.rep(" ", width))
      spacer.keep, spacer.reserve = true, true
      last = ctx:emit({ frag(string.rep(" ", col - ctx.plan.margin)) }, { spacer })
      ctx.plan.row_keys[last + 1] = "image:" .. image.key
    end
    ctx.plan.images[#ctx.plan.images + 1] = {
      key = image.key,
      row_start = start,
      row_end = last,
      col = col,
      width = width,
      height = height,
    }
  end
  ctx:register_block(block.source, first, last)
end

---@param ctx MDEyeLayoutCtx
---@param block MDEyeBlock
---@param prefix MDEyeFrag[]
---@param avail integer
local function render_footnote(ctx, block, prefix, avail)
  local marker = ("%d. "):format(block.attrs.ordinal)
  local marker_width = ctx.measure(marker)
  local first_prefix = vim.list_slice(prefix)
  first_prefix[#first_prefix + 1] = frag(marker, { "MDEyeFootnote" })
  local continuation = vim.list_slice(prefix)
  continuation[#continuation + 1] = frag(string.rep(" ", marker_width))
  local lines = wrap_runs(block.runs, avail - marker_width, ctx.measure)

  local first, last
  ctx.pending_first_prefix = first_prefix
  for _, lfrags in ipairs(lines) do
    local row = ctx:emit(continuation, lfrags)
    first = first or row
    last = row
  end
  if block.blocks and #block.blocks > 0 then
    if first then
      ctx:emit(continuation, nil)
    end
    local before = #ctx.plan.lines
    render_blocks(ctx, block.blocks, continuation, avail - marker_width)
    if #ctx.plan.lines > before then
      first = first or before
      last = #ctx.plan.lines - 1
    end
  end
  if not first then
    first = ctx:emit(continuation, {})
    last = first
  end
  ctx.pending_first_prefix = nil
  ctx:register_block(block.source, first, last)
  ctx.plan.anchors[block.attrs.anchor] = { row = first, source = block.source }
end

---@param ctx MDEyeLayoutCtx
local function render_heading(ctx, block, prefix, avail)
  local level = block.attrs.level
  local hl = "MDEyeHeading" .. level
  local lines = wrap_runs(block.runs, avail, ctx.measure, { hl })
  local first, last
  for _, lfrags in ipairs(lines) do
    local row = ctx:emit(prefix, lfrags)
    first = first or row
    last = row
  end
  if level <= 2 then
    local ch = level == 1 and "━" or "─"
    local row = ctx:emit(prefix, { frag(ch:rep(avail), { "MDEyeHeadingRule" }) })
    first = first or row
    last = row
  end
  if first then
    ctx:register_block(block.source, first, last)
    local heading = {
      row = first,
      level = level,
      title = block.attrs.title,
      anchor = block.attrs.anchor,
      source = block.source,
    }
    ctx.plan.headings[#ctx.plan.headings + 1] = heading
    ctx.plan.anchors[heading.anchor] = heading
  end
end

---@param ctx MDEyeLayoutCtx
local function render_rule(ctx, block, prefix, avail)
  local row = ctx:emit(prefix, { frag(("─"):rep(avail), { "MDEyeMuted" }) })
  ctx:register_block(block.source, row, row)
end

---@param line string
---@param col integer
---@param expand string
---@return integer
local function expanded_byte_col(line, col, expand)
  return #(line:sub(1, col):gsub("\t", expand))
end

---@param text string
---@param avail integer
---@param measure fun(s: string): integer
---@param wrap boolean
---@return { text: string, start_col: integer, end_col: integer }[]
local function code_chunks(text, avail, measure, wrap)
  if not wrap or measure(text) <= avail then
    return { { text = text, start_col = 0, end_col = #text } }
  end

  local chunks = {}
  local parts = {}
  local start_col, byte_col, cells = 0, 0, 0
  local function flush()
    chunks[#chunks + 1] = {
      text = table.concat(parts),
      start_col = start_col,
      end_col = byte_col,
    }
    parts = {}
    start_col = byte_col
    cells = 0
  end
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    local width = measure(ch)
    if cells > 0 and cells + width > avail then
      flush()
    end
    parts[#parts + 1] = ch
    byte_col = byte_col + #ch
    cells = cells + width
  end
  if #parts > 0 or #chunks == 0 then
    flush()
  end
  return chunks
end

---@param ctx MDEyeLayoutCtx
local function render_code(ctx, block, prefix, avail)
  local diagram, diagram_keys, diagram_mode
  if ctx.mermaid_enabled and block.attrs.diagram then
    diagram, diagram_keys, diagram_mode = require("mdeye.mermaid").layout(
      block.attrs.diagram,
      avail - 1,
      ctx.measure,
      ctx.mermaid_layout
    )
  end
  local first, last
  if block.attrs.lang then
    local lang = block.attrs.lang
    if lang:lower() == "mermaid" and ctx.mermaid_enabled then
      lang = diagram and ("mermaid (" .. diagram_mode .. ")") or "mermaid (source)"
    end
    for _, chunk in ipairs(code_chunks(lang, math.max(avail, 1), ctx.measure, true)) do
      local pad = math.max(avail - ctx.measure(chunk.text), 0)
      local row = ctx:emit(prefix, {
        frag(string.rep(" ", pad)),
        frag(chunk.text, { "MDEyeMuted" }),
      })
      first = first or row
      last = row
    end
    if lang == "mermaid (source)" then
      local reason = block.attrs.diagram_error or "pane too narrow for diagram"
      local runs = { { kind = "text", text = reason } }
      for _, line in ipairs(wrap_runs(runs, avail, ctx.measure, { "MDEyeMuted" })) do
        last = ctx:emit(prefix, line)
      end
    end
  end
  local expand = string.rep(" ", ctx.tab_width)
  for index, line in ipairs(diagram or block.attrs.lines) do
    local expanded = line:gsub("\t", expand)
    for _, chunk in
      ipairs(
        code_chunks(expanded, math.max(avail - 1, 1), ctx.measure, not diagram and ctx.code_wrap)
      )
    do
      local text = " " .. chunk.text
      local w = ctx.measure(text)
      if w < avail then
        text = text .. string.rep(" ", avail - w)
      end
      local code_frag = frag(text, diagram and { "MDEyeDiagram" } or nil)
      code_frag.keep = true
      local row = ctx:emit(prefix, { code_frag })
      ctx:block_mark(row, "MDEyeCodeBlock")
      if diagram_keys then
        ctx.plan.row_keys[row + 1] = diagram_keys[index]
      end

      local generated = ctx.plan.lines[row + 1]
      local text_start = #generated - #text
      for _, capture in ipairs(block.attrs.highlights or {}) do
        if capture.row == index - 1 then
          local capture_start = expanded_byte_col(line, capture.start_col, expand)
          local capture_end = expanded_byte_col(line, capture.end_col, expand)
          local start_col = math.max(capture_start, chunk.start_col)
          local end_col = math.min(capture_end, chunk.end_col)
          if start_col < end_col then
            ctx.plan.marks[#ctx.plan.marks + 1] = {
              row = row,
              start_col = text_start + 1 + start_col - chunk.start_col,
              end_col = text_start + 1 + end_col - chunk.start_col,
              hl = "@" .. capture.capture .. "." .. block.attrs.highlight_lang,
              priority = capture.priority or (PRIORITY_CODE + capture.order),
            }
          end
        end
      end

      first = first or row
      last = row
    end
  end
  if #block.attrs.lines == 0 then
    local empty = frag(string.rep(" ", avail))
    empty.keep = true
    local row = ctx:emit(prefix, { empty })
    ctx:block_mark(row, "MDEyeCodeBlock")
    first = first or row
    last = row
  end
  ctx:register_block(block.source, first, last)
  ctx.plan.code_blocks[#ctx.plan.code_blocks + 1] = {
    row_start = first,
    row_end = last,
    source = block.source,
    lines = vim.deepcopy(block.attrs.lines),
    lang = block.attrs.lang,
  }
end

---@param ctx MDEyeLayoutCtx
local function render_html(ctx, block, prefix, avail)
  local _ = avail
  local first, last
  for _, line in ipairs(block.attrs.lines) do
    local row = ctx:emit(prefix, { frag(line, { "MDEyeMuted" }) })
    first = first or row
    last = row
  end
  if first then
    ctx:register_block(block.source, first, last)
  end
end

local alert_styles = {
  note = { title = "Note", hl = "MDEyeAlertNote" },
  tip = { title = "Tip", hl = "MDEyeAlertTip" },
  important = { title = "Important", hl = "MDEyeAlertImportant" },
  warning = { title = "Warning", hl = "MDEyeAlertWarning" },
  caution = { title = "Caution", hl = "MDEyeAlertCaution" },
}

---@param ctx MDEyeLayoutCtx
local function render_quote(ctx, block, prefix, avail)
  local alert = alert_styles[block.attrs.alert]
  local quote_hl = alert and alert.hl or "MDEyeQuote"
  local qprefix = vim.list_slice(prefix)
  qprefix[#qprefix + 1] = frag("┃ ", { quote_hl })
  local row_start = #ctx.plan.lines
  if alert then
    ctx:emit(prefix, {
      frag("┃ ", { quote_hl }),
      frag(alert.title, { quote_hl }),
    })
  end
  render_blocks(ctx, block.blocks, qprefix, avail - 2)
  local row_end = #ctx.plan.lines - 1
  if row_end >= row_start then
    ctx:register_block(block.source, row_start, row_end)
  end
end

local task_glyphs = function(measure)
  -- Deterministic ASCII fallback: if the glyphs do not measure as one cell
  -- (e.g. ambiwidth=double), use bracket markers instead.
  if measure("☐") == 1 and measure("☑") == 1 then
    return "☐", "☑"
  end
  return "[ ]", "[x]"
end

---@param ctx MDEyeLayoutCtx
local function render_list(ctx, block, prefix, avail)
  local items = block.items or {}
  local ordered = block.attrs.ordered
  local start = block.attrs.start or 1
  local unchecked, checked = task_glyphs(ctx.measure)

  -- Marker column width: widest marker aligns the whole list level.
  local marker_texts = {}
  local marker_w = 0
  for i, item in ipairs(items) do
    local text
    if item.task == "checked" then
      text = checked
    elseif item.task == "unchecked" then
      text = unchecked
    elseif ordered then
      text = ("%d."):format(start + i - 1)
    else
      text = "•"
    end
    marker_texts[i] = text
    marker_w = math.max(marker_w, ctx.measure(text))
  end
  local hang = marker_w + 1

  -- A list is "loose" when the source separates items with blank lines;
  -- loose lists get blank lines between items, tight lists stay compact.
  local loose = false
  for i = 1, #items - 1 do
    local prev = items[i]
    local last_content_row = prev.source.start_row
    for _, b in ipairs(prev.blocks) do
      last_content_row = math.max(last_content_row, b.source.end_row)
    end
    if items[i + 1].source.start_row - last_content_row > 1 then
      loose = true
    end
  end

  local list_start = #ctx.plan.lines
  for i, item in ipairs(items) do
    if i > 1 and loose then
      ctx:emit(prefix, nil)
    end
    local text = marker_texts[i]
    local hl = "MDEyeListMarker"
    if item.task == "checked" then
      hl = "MDEyeTaskChecked"
    elseif item.task == "unchecked" then
      hl = "MDEyeTaskUnchecked"
    end
    local pad = string.rep(" ", marker_w - ctx.measure(text))
    local first_prefix = vim.list_slice(prefix)
    first_prefix[#first_prefix + 1] = frag(pad .. text .. " ", { hl })
    local cont_prefix = vim.list_slice(prefix)
    cont_prefix[#cont_prefix + 1] = frag(string.rep(" ", hang))

    local item_start = #ctx.plan.lines
    ctx.pending_first_prefix = first_prefix
    render_blocks(ctx, item.blocks, cont_prefix, avail - hang, not loose)
    if #ctx.plan.lines == item_start then
      -- Item without content still occupies one marker line.
      ctx.pending_first_prefix = nil
      ctx:emit(first_prefix, { frag("") })
    end
    ctx.pending_first_prefix = nil
    ctx:register_block(item.source, item_start, #ctx.plan.lines - 1)
  end
  if #ctx.plan.lines > list_start then
    ctx:register_block(block.source, list_start, #ctx.plan.lines - 1)
  end
end

---Layout one table cell into fragment lines at a given width.
local function cell_lines(cell, width, measure, header)
  local lines = wrap_runs(cell.runs, width, measure, nil)
  if header then
    for _, lfrags in ipairs(lines) do
      for _, f in ipairs(lfrags) do
        local hls = { "MDEyeStrong" }
        vim.list_extend(hls, f.hls or {})
        f.hls = hls
      end
    end
  end
  return lines
end

local function frags_width(frags, measure)
  local w = 0
  for _, f in ipairs(frags) do
    w = w + measure(f.text)
  end
  return w
end

---@param ctx MDEyeLayoutCtx
local function render_table(ctx, block, prefix, avail)
  local measure = ctx.measure
  local header = block.attrs.header
  local rows = block.attrs.rows
  local aligns = block.attrs.aligns or {}

  local all_rows = {}
  if header then
    all_rows[#all_rows + 1] = header
  end
  vim.list_extend(all_rows, rows)
  if #all_rows == 0 then
    return
  end
  local ncols = 0
  for _, row in ipairs(all_rows) do
    ncols = math.max(ncols, #row.cells)
  end
  if ncols == 0 then
    return
  end

  -- Natural column widths from unwrapped single-line cell content.
  local widths = {}
  for c = 1, ncols do
    widths[c] = 1
  end
  for _, row in ipairs(all_rows) do
    for c = 1, ncols do
      local cell = row.cells[c]
      if cell then
        local lines = cell_lines(cell, math.huge, measure, false)
        for _, lfrags in ipairs(lines) do
          widths[c] = math.max(widths[c], frags_width(lfrags, measure))
        end
      end
    end
  end

  -- Shrink the widest columns until the table fits the content width; cells
  -- in shrunken columns wrap onto continuation lines.
  local chrome = (ncols + 1) + 2 * ncols -- borders plus one-cell padding
  local function total()
    local t = chrome
    for c = 1, ncols do
      t = t + widths[c]
    end
    return t
  end
  while total() > avail do
    local widest, wc = 0, nil
    for c = 1, ncols do
      if widths[c] > widest then
        widest, wc = widths[c], c
      end
    end
    if not wc or widths[wc] <= TABLE_CELL_MIN then
      break
    end
    widths[wc] = math.max(TABLE_CELL_MIN, widths[wc] - (total() - avail))
  end

  local border_hl = { "MDEyeTableBorder" }
  local function border(l, mid, r, fill)
    local parts = { l }
    for c = 1, ncols do
      parts[#parts + 1] = string.rep(fill, widths[c] + 2)
      parts[#parts + 1] = c < ncols and mid or r
    end
    return { frag(table.concat(parts), border_hl) }
  end

  local first_row_emitted, last_row_emitted
  local function emit_row(row, is_header)
    local per_cell = {}
    local height = 1
    for c = 1, ncols do
      local cell = row.cells[c]
      per_cell[c] = cell and cell_lines(cell, widths[c], measure, is_header) or {}
      height = math.max(height, #per_cell[c])
    end
    local row_first
    for l = 1, height do
      local frags = {}
      frags[#frags + 1] = frag("│", border_hl)
      for c = 1, ncols do
        local content = per_cell[c][l] or {}
        local w = frags_width(content, measure)
        local space = widths[c] - w
        local left, right = 0, space
        local align = aligns[c] or "left"
        if align == "right" then
          left, right = space, 0
        elseif align == "center" then
          left = math.floor(space / 2)
          right = space - left
        end
        frags[#frags + 1] = frag(" " .. string.rep(" ", left))
        vim.list_extend(frags, content)
        frags[#frags + 1] = frag(string.rep(" ", right) .. " ")
        frags[#frags + 1] = frag("│", border_hl)
      end
      local r = ctx:emit(prefix, frags)
      row_first = row_first or r
      first_row_emitted = first_row_emitted or r
      last_row_emitted = r
    end
    ctx:register_block(row.source, row_first, last_row_emitted)
  end

  local table_start = #ctx.plan.lines
  ctx:emit(prefix, border("┌", "┬", "┐", "─"))
  if header then
    emit_row(header, true)
    ctx:emit(prefix, border("├", "┼", "┤", "─"))
  end
  for _, row in ipairs(rows) do
    emit_row(row, false)
  end
  ctx:emit(prefix, border("└", "┴", "┘", "─"))
  ctx:register_block(block.source, table_start, #ctx.plan.lines - 1)
end

local renderers = {
  paragraph = render_paragraph,
  footnote = render_footnote,
  heading = render_heading,
  rule = render_rule,
  code = render_code,
  html = render_html,
  quote = render_quote,
  list = render_list,
  table = render_table,
}

---Blank lines separating two sibling blocks: deliberate vertical rhythm.
local function spacing_between(prev, nxt)
  if nxt.kind == "heading" and nxt.attrs.level <= 2 then
    return 2
  end
  if prev.kind == "heading" then
    return 1
  end
  return 1
end

---@param ctx MDEyeLayoutCtx
---@param blocks MDEyeBlock[]
---@param prefix MDEyeFrag[]
---@param avail integer
---@param tight boolean|nil inside a tight list item: no blank before a
---directly nested list
render_blocks = function(ctx, blocks, prefix, avail, tight)
  avail = math.max(avail, 1)
  for i, block in ipairs(blocks) do
    if i > 1 then
      local n = spacing_between(blocks[i - 1], block)
      if tight and block.kind == "list" and blocks[i - 1].kind == "paragraph" then
        n = 0
      end
      for _ = 1, n do
        ctx:emit(prefix, nil)
      end
    end
    local renderer = renderers[block.kind]
    if renderer then
      renderer(ctx, block, prefix, avail)
    end
  end
end

---Compute the reading column geometry.
---@param usable integer
---@param max_width integer|false
---@param min_margin integer
---@return integer width, integer margin
function M.geometry(usable, max_width, min_margin)
  local available = usable - 2 * min_margin
  local width = max_width and math.min(max_width, available) or available
  if width < MIN_CONTENT then
    -- Margins shrink before content becomes unusably narrow.
    width = math.max(math.min(usable, MIN_CONTENT), 1)
  end
  local margin = math.max(math.floor((usable - width) / 2), 0)
  return width, margin
end

---@param doc MDEyeDocument
---@param opts MDEyeLayoutOpts
---@return MDEyeRenderPlan
function M.plan(doc, opts)
  local measure = opts.measure or function(s)
    return vim.fn.strdisplaywidth(s)
  end
  local width, margin = M.geometry(opts.usable_width, opts.max_width, opts.min_margin)
  local plan = {
    lines = {},
    text = {},
    row_keys = {},
    images = {},
    marks = {},
    blocks = {},
    headings = {},
    anchors = {},
    code_blocks = {},
    width = width,
    margin = margin,
  }
  local ctx = setmetatable({
    plan = plan,
    measure = measure,
    tab_width = opts.tab_width or 4,
    code_wrap = opts.code_wrap == true,
    mermaid_enabled = opts.mermaid_enabled ~= false,
    mermaid_layout = opts.mermaid_layout or "graph",
    image_specs = opts.image_specs or {},
  }, Ctx)

  ctx:emit({}, nil) -- top padding
  render_blocks(ctx, doc.blocks, {}, width)
  ctx:emit({}, nil) -- bottom padding

  -- Merge contiguous marks that carry the same style and target, so a link
  -- or emphasis phrase is one continuous mark per line.
  table.sort(plan.marks, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    if a.hl ~= b.hl then
      return a.hl < b.hl
    end
    return a.start_col < b.start_col
  end)
  local merged = {}
  for _, mark in ipairs(plan.marks) do
    local prev = merged[#merged]
    if
      prev
      and prev.row == mark.row
      and prev.hl == mark.hl
      and prev.target == mark.target
      and prev.priority == mark.priority
      and prev.end_col == mark.start_col
    then
      prev.end_col = mark.end_col
    else
      merged[#merged + 1] = mark
    end
  end
  plan.marks = merged

  table.sort(plan.blocks, function(a, b)
    if a.row_start ~= b.row_start then
      return a.row_start < b.row_start
    end
    return a.row_end > b.row_end -- outer blocks first at equal start
  end)
  return plan
end

return M
