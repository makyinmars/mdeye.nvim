---A bounded Mermaid sequence model and lifeline layout.
local draw = require("mdeye.diagram")
local M = {}
local arrows = { "-->>", "->>", "-->", "->", "--x", "-x", "--)", "-)" }
local function label(text)
  text = vim.trim(text)
  if
    text == ""
    or text:find('[<>#`"\\]')
    or text:find("[%c]")
    or text:find(";", 1, true)
    or text:find("&[%w#]+;")
  then
    return nil
  end
  return text
end

---@class MDEyeSequence
---@field kind "sequence"
---@field participants MDEyeMermaidNode[]
---@field events table[] ordered messages, activations, notes, and regions
---@field autonumber boolean

---@param lines string[]
---@return MDEyeSequence|nil, string|nil
function M.parse(lines)
  local model = { kind = "sequence", participants = {}, events = {}, autonumber = false }
  local by_id, regions, activated = {}, {}, {}
  local function participant(id, name, actor)
    if not id or not id:match("^[%a_][%w_]*$") then
      return nil
    end
    local found = by_id[id]
    if not found then
      if #model.participants >= 20 then
        return nil
      end
      found = { id = id, label = id, shape = "rectangle" }
      model.participants[#model.participants + 1], by_id[id] = found, found
    end
    if name then
      found.label = name
    end
    if actor then
      found.shape = "rounded"
    end
    return found
  end
  local header = false
  for _, raw in ipairs(lines) do
    if raw:find("%%{", 1, true) then
      return nil, "unsupported sequence directive"
    end
    local text = vim.trim(raw:gsub("%%.*$", ""))
    if text ~= "" then
      if not header then
        if text ~= "sequenceDiagram" then
          return nil, "unsupported sequence header"
        end
        header = true
      elseif text == "autonumber" then
        model.autonumber = true
      elseif text:match("^participant%s") or text:match("^actor%s") then
        local kind, id, tail = text:match("^(%a+)%s+([%w_]+)%s*(.*)$")
        local name = tail == "" and id or label((tail or ""):match("^as%s+(.+)$") or "")
        if not name or not participant(id, name, kind == "actor") then
          return nil, "unsupported participant"
        end
      elseif text:match("^activate%s") or text:match("^deactivate%s") then
        local kind, id = text:match("^(%a+)%s+([%w_]+)$")
        local who = participant(id)
        if not who then
          return nil, "unsupported activation"
        end
        activated[id] = (activated[id] or 0) + (kind == "activate" and 1 or -1)
        if activated[id] < 0 then
          return nil, "unmatched deactivation"
        end
        model.events[#model.events + 1] = { kind = kind, who = who }
      elseif text:match("^Note%s") then
        local where, ids, value = text:match("^Note%s+([%a ]+)%s+([%w_,]+)%s*:%s*(.+)$")
        local a, b = (ids or ""):match("^([%w_]+),?([%w_]*)$")
        local from, to = participant(a), b ~= "" and participant(b) or nil
        if
          not from
          or not label(value or "")
          or (where ~= "over" and where ~= "left of" and where ~= "right of")
        then
          return nil, "unsupported sequence note"
        end
        model.events[#model.events + 1] =
          { kind = "note", from = from, to = to or from, label = value, where = where }
      elseif text == "end" then
        if #regions == 0 then
          return nil, "unmatched sequence end"
        end
        regions[#regions] = nil
        model.events[#model.events + 1] = { kind = "end" }
      else
        local region, title = text:match("^(%a+)%s+(.+)$")
        if region == "loop" or region == "alt" or region == "opt" or region == "par" then
          if not label(title) then
            return nil, "unsupported sequence region"
          end
          regions[#regions + 1] = region
          model.events[#model.events + 1] = { kind = "region", label = region .. ": " .. title }
        elseif region == "else" or region == "and" then
          if
            #regions == 0
            or (region == "else" and regions[#regions] ~= "alt")
            or (region == "and" and regions[#regions] ~= "par")
            or not label(title)
          then
            return nil, "unmatched sequence branch"
          end
          model.events[#model.events + 1] = { kind = "branch", label = region .. ": " .. title }
        else
          local from_id, rest = text:match("^([%a_][%w_]*)%s*(.+)$")
          local arrow
          for _, candidate in ipairs(arrows) do
            if rest and rest:sub(1, #candidate) == candidate then
              arrow, rest = candidate, vim.trim(rest:sub(#candidate + 1))
              break
            end
          end
          local activation, to_id, value = (rest or ""):match("^([+-]?)([%a_][%w_]*)%s*:%s*(.+)$")
          local from, to = participant(from_id), participant(to_id)
          if not arrow or not from or not to or not label(value or "") then
            return nil, "unsupported sequence statement"
          end
          if activation == "+" then
            activated[to.id] = (activated[to.id] or 0) + 1
          elseif activation == "-" then
            activated[from.id] = (activated[from.id] or 0) - 1
            if activated[from.id] < 0 then
              return nil, "unmatched deactivation"
            end
          end
          model.events[#model.events + 1] = {
            kind = "message",
            from = from,
            to = to,
            arrow = arrow,
            label = value,
            activation = activation,
          }
        end
      end
      if #model.events > 200 then
        return nil, "sequence exceeds native limits"
      end
    end
  end
  if #regions > 0 then
    return nil, "unclosed sequence region"
  end
  if #model.participants == 0 then
    return nil, "empty sequence diagram"
  end
  local occurrences = {}
  for _, event in ipairs(model.events) do
    local identity = table.concat({
      event.kind,
      event.from and event.from.id or "",
      event.to and event.to.id or "",
      event.who and event.who.id or "",
      event.arrow or "",
      event.label or "",
    }, ":")
    occurrences[identity] = (occurrences[identity] or 0) + 1
    event.key = "event:" .. identity .. ":" .. occurrences[identity]
  end
  return model
end

---@param model MDEyeSequence
---@param width integer
---@param measure fun(text: string): integer
---@return string[]|nil, table<integer, string>|nil
function M.layout(model, width, measure)
  local count = #model.participants
  local cell = math.floor(width / count)
  if cell < 10 then
    return nil
  end
  local canvas, positions, active = draw.canvas(width, measure), {}, {}
  local header_height = 0
  for i, who in ipairs(model.participants) do
    local box_width = math.min(cell - 2, math.max(8, measure(draw.label(who)) + 4))
    local box = draw.box(who, box_width, measure)
    if not box then
      return nil
    end
    local x = (i - 1) * cell + math.floor((cell - box_width) / 2) + 1
    for y, line in ipairs(box) do
      canvas:put(x, y, line)
    end
    header_height = math.max(header_height, #box)
    positions[who.id] = x + math.floor(box_width / 2)
  end
  local y, number, depth = header_height + 1, 0, 0
  local function lifelines(first, last)
    for row = first, last do
      for _, who in ipairs(model.participants) do
        canvas:put(positions[who.id], row, (active[who.id] or 0) > 0 and "#" or "|")
      end
      if depth > 0 then
        canvas:put(1, row, "|")
        canvas:put(width, row, "|")
      end
    end
  end
  for _, event in ipairs(model.events) do
    local first = y
    if event.kind == "activate" or event.kind == "deactivate" then
      active[event.who.id] = (active[event.who.id] or 0) + (event.kind == "activate" and 1 or -1)
      lifelines(y, y)
      y = y + 1
    elseif event.kind == "region" or event.kind == "branch" or event.kind == "end" then
      canvas:put(1, y, "+" .. string.rep("-", width - 2) .. "+")
      y = y + 1
      if event.kind == "region" then
        depth = depth + 1
      elseif event.kind == "end" then
        depth = depth - 1
      end
      if event.label then
        for _, line in ipairs(draw.wrap(event.label, width - 4, measure) or {}) do
          canvas:put(1, y, "| " .. line .. string.rep(" ", width - 4 - measure(line)) .. " |")
          y = y + 1
        end
      end
    elseif event.kind == "note" then
      local a, b = positions[event.from.id], positions[event.to.id]
      local left, right =
        math.max(2, math.min(a, b) - math.floor(cell / 2) + 1),
        math.min(width - 1, math.max(a, b) + math.floor(cell / 2) - 1)
      if event.where == "left of" then
        left, right = math.max(2, a - cell + 2), a - 1
      elseif event.where == "right of" then
        left, right = a + 1, math.min(width - 1, a + cell - 2)
      end
      local note = draw.wrap("Note: " .. event.label, right - left + 1, measure)
      if not note then
        return nil
      end
      lifelines(y, y + #note)
      for _, line in ipairs(note) do
        canvas:put(left, y, line)
        y = y + 1
      end
      y = y + 1
    else
      number = number + 1
      local a, b = positions[event.from.id], positions[event.to.id]
      local left, right = math.min(a, b), math.max(a, b)
      local self = a == b
      if self then
        right = math.min(width - 1, a + math.floor(cell / 2) - 1)
        left = math.max(2, a - math.floor(cell / 2) + 1)
      end
      local text = (model.autonumber and (number .. ". ") or "") .. event.label
      local labels = draw.wrap(text, right - left + 1, measure)
      if not labels then
        return nil
      end
      lifelines(y, y + #labels + (self and 3 or 1))
      for _, line in ipairs(labels) do
        canvas:put(left, y, line)
        y = y + 1
      end
      local stroke = event.arrow:sub(1, 2) == "--" and "." or "-"
      if self then
        canvas:put(a + 1, y, stroke:rep(right - a - 1) .. "+")
        canvas:put(right, y + 1, "|")
        canvas:put(a + 1, y + 2, "<" .. stroke:rep(right - a - 2) .. "+")
        y = y + 3
      else
        canvas:put(left + 1, y, stroke:rep(right - left - 1))
        local tip = event.arrow:sub(-1) == "x" and "x" or (a < b and ">" or "<")
        canvas:put(b + (a < b and -1 or 1), y, tip)
        y = y + 1
      end
      if event.activation == "+" then
        active[event.to.id] = (active[event.to.id] or 0) + 1
      elseif event.activation == "-" then
        active[event.from.id] = (active[event.from.id] or 0) - 1
      end
      y = y + 1
    end
    for row = first, y - 1 do
      canvas.keys[row] = event.key
    end
  end
  lifelines(y, y)
  for row = 1, y do
    canvas.rows[row] = canvas.rows[row] or {}
  end
  return canvas:finish()
end

return M
