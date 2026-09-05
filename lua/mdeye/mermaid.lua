---Conservative Mermaid flowchart/sequence parsing and portable layout dispatch.
---Unsupported input returns a reason; callers must retain the entire source.
local M = {}

---@class MDEyeMermaidNode
---@field id string
---@field label string
---@field shape string
---@field order integer|nil declaration order (flowcharts)
---@field group string|nil containing subgraph ID

---@class MDEyeMermaidGraph
---@field kind "flowchart"
---@field groups {id: string, label: string, parent: string|nil, order: integer}[]
---@field direction string
---@field nodes MDEyeMermaidNode[] declaration order
---@field edges { from: MDEyeMermaidNode, to: MDEyeMermaidNode, label: string, kind: string }[]

local directions = { TD = true, TB = true, BT = true, LR = true, RL = true }
local reserved = {
  subgraph = true,
  ["end"] = true,
  style = true,
  classDef = true,
  class = true,
  linkStyle = true,
  click = true,
  direction = true,
}

---Split statements without splitting quoted labels or labels containing semicolons.
local function statements(lines)
  local out, part, stack = {}, {}, {}
  local quote = false
  local closers = { ["["] = "]", ["("] = ")", ["{"] = "}" }
  local function flush()
    local text = vim.trim(table.concat(part))
    if text ~= "" then
      out[#out + 1] = text
    end
    part = {}
  end
  for _, line in ipairs(lines) do
    local i = 1
    while i <= #line do
      local ch = line:sub(i, i)
      if not quote and #stack == 0 and line:sub(i, i + 1) == "%%" then
        if line:sub(i, i + 2) == "%%{" then
          return nil
        end
        break
      elseif ch == '"' then
        quote = not quote
      elseif not quote then
        if closers[ch] then
          stack[#stack + 1] = closers[ch]
        elseif ch == stack[#stack] then
          stack[#stack] = nil
        elseif ch == "]" or ch == ")" or ch == "}" then
          return nil
        end
      end
      if ch == ";" and not quote and #stack == 0 then
        flush()
      else
        part[#part + 1] = ch
      end
      i = i + 1
    end
    if quote or #stack > 0 then
      return nil -- multiline/Markdown labels are not in the supported subset
    end
    flush()
  end
  return out
end

local shapes = {
  { "((", "))", "circle" },
  { "([", "])", "rounded" },
  { "[[", "]]", "rectangle" },
  { "[", "]", "rectangle" },
  { "(", ")", "rounded" },
  { "{", "}", "decision" },
}

local function plain_label(text)
  text = vim.trim(text)
  if text:sub(1, 1) == '"' and text:sub(-1) == '"' then
    text = text:sub(2, -2)
  end
  -- Do not silently reinterpret HTML, entities, Markdown strings, or escapes.
  if text == "" or text:find('[<>#`"\\]') or text:find("[%c]") or text:find("&[%w#]+;") then
    return nil
  end
  return text
end

---@param lines string[] original fence content
---@return MDEyeMermaidGraph|MDEyeSequence|nil graph
---@return string|nil reason
function M.parse(lines)
  if #lines > 500 or #table.concat(lines, "\n") > 65536 then
    return nil, "diagram exceeds native limits"
  end
  for _, line in ipairs(lines) do
    if vim.trim(line) == "sequenceDiagram" then
      return require("mdeye.sequence").parse(lines)
    end
  end
  local parts = statements(lines)
  if not parts or not parts[1] then
    return nil, "incomplete or unsupported syntax"
  end
  local keyword, direction, rest = parts[1]:match("^(%a+)%s+(%u+)%s*(.*)$")
  if (keyword ~= "flowchart" and keyword ~= "graph") or not directions[direction] then
    return nil, "only flowchart/graph is supported"
  end
  local graph = { kind = "flowchart", direction = direction, nodes = {}, edges = {}, groups = {} }
  local group_stack, group_ids, order = {}, {}, 0
  local by_id = {}
  local function node(text)
    local id, tail = text:match("^([%a_][%w_]*)%s*(.*)$")
    if not id or reserved[id] then
      return nil
    end
    local label, shape
    for _, spec in ipairs(shapes) do
      if tail:sub(1, #spec[1]) == spec[1] then
        local close
        if tail:sub(#spec[1] + 1, #spec[1] + 1) == '"' then
          local quote_end = tail:find('"', #spec[1] + 2, true)
          if quote_end and tail:sub(quote_end + 1, quote_end + #spec[2]) == spec[2] then
            close = quote_end + 1
          end
        else
          close = tail:find(spec[2], #spec[1] + 1, true)
        end
        if not close then
          return nil
        end
        local raw_label = tail:sub(#spec[1] + 1, close - 1)
        if raw_label:sub(1, 1) ~= '"' and raw_label:find("[%[%]{}()/]") then
          return nil
        end
        label = plain_label(raw_label)
        if not label then
          return nil
        end
        shape = spec[3]
        tail = vim.trim(tail:sub(close + #spec[2]))
        break
      end
    end
    local found = by_id[id]
    if not found then
      order = order + 1
      found = {
        id = id,
        label = id,
        shape = "rectangle",
        order = order,
        group = group_stack[#group_stack],
      }
      by_id[id] = found
      graph.nodes[#graph.nodes + 1] = found
    end
    if group_stack[#group_stack] and not found.group then
      found.group = group_stack[#group_stack]
    end
    if group_ids[id] then
      return nil
    end
    if label then
      found.label, found.shape = label, shape
    end
    return found, tail
  end
  local edge_kinds = { "-->", "---", "-.->", "==>" }
  parts[1] = rest
  for _, statement in ipairs(parts) do
    if statement:match("^subgraph%s+") then
      local id, title = statement:match("^subgraph%s+([%a_][%w_]*)%s*%[(.*)%]$")
      if not id then
        id = statement:match("^subgraph%s+([%a_][%w_]*)$")
        title = id
      end
      title = title and plain_label(title)
      if not id or not title or group_ids[id] or by_id[id] or #group_stack >= 8 then
        return nil, "unsupported subgraph"
      end
      order = order + 1
      graph.groups[#graph.groups + 1] =
        { id = id, label = title, parent = group_stack[#group_stack], order = order }
      group_ids[id] = true
      group_stack[#group_stack + 1] = id
    elseif statement == "end" then
      if #group_stack == 0 then
        return nil, "unmatched subgraph end"
      end
      group_stack[#group_stack] = nil
    elseif statement ~= "" then
      local from, tail = node(statement)
      if not from then
        return nil, "unsupported node or directive"
      end
      while tail ~= "" do
        local kind
        for _, candidate in ipairs(edge_kinds) do
          if tail:sub(1, #candidate) == candidate then
            if candidate == "---" and tail:sub(4, 4):match("[ox]") then
              return nil, "unsupported circle or cross connection"
            end
            kind = candidate
            tail = vim.trim(tail:sub(#candidate + 1))
            break
          end
        end
        local label = ""
        if not kind then
          local raw_label, remainder = tail:match("^%-%-%s+(.-)%s+%-%->%s*(.*)$")
          label = raw_label and plain_label(raw_label) or nil
          if not label then
            return nil, "unsupported connection or directive"
          end
          kind, tail = "-->", remainder
        end
        if tail:sub(1, 1) == "|" then
          local finish = tail:find("|", 2, true)
          label = finish and plain_label(tail:sub(2, finish - 1)) or nil
          if not label then
            return nil, "unsupported edge label"
          end
          tail = vim.trim(tail:sub(finish + 1))
        end
        local to
        to, tail = node(tail)
        if not to then
          return nil, "incomplete or unsupported connection"
        end
        graph.edges[#graph.edges + 1] = { from = from, to = to, label = label, kind = kind }
        if #graph.edges > 200 then
          return nil, "diagram exceeds native limits"
        end
        from = to
      end
    end
    if #graph.nodes > 100 then
      return nil, "diagram exceeds native limits"
    end
  end
  if #group_stack > 0 then
    return nil, "unclosed subgraph"
  end
  if #graph.nodes == 0 then
    return nil, "empty diagram"
  end
  return graph
end

---Wrap by display cells, including long labels without spaces.
local function wrap(text, width, measure)
  local lines, part, cells = {}, {}, 0
  for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
    local size = measure(ch)
    if size > width then
      return nil
    end
    if cells + size > width then
      lines[#lines + 1] = table.concat(part)
      part, cells = {}, 0
    end
    part[#part + 1], cells = ch, cells + size
  end
  lines[#lines + 1] = table.concat(part)
  return lines
end

local function box(node, width, measure)
  -- IDs make repeated branch junctions and duplicate labels unambiguous.
  local label = node.label == node.id and node.id or (node.id .. ": " .. node.label)
  local lines = wrap(label, width - 4, measure)
  if not lines then
    return nil
  end
  local left, right = "+", "+"
  if node.shape == "decision" then
    left, right = "<", ">"
  elseif node.shape == "rounded" or node.shape == "circle" then
    left, right = "(", ")"
  end
  local border = left .. string.rep("-", width - 2) .. right
  local out = { border }
  for _, line in ipairs(lines) do
    out[#out + 1] = "| " .. line .. string.rep(" ", width - 3 - measure(line)) .. "|"
  end
  out[#out + 1] = border
  return out
end

---@param graph MDEyeMermaidGraph
---@param width integer available display cells
---@param measure fun(text: string): integer
---@return string[]|nil lines connected pairs; repeated IDs denote the same node
local function connections(graph, width, measure)
  if width < 8 then
    return nil
  end
  local out, connected = {}, {}
  local function append(lines)
    if not lines then
      return false
    end
    vim.list_extend(out, lines)
    return true
  end
  local function node_width(node)
    local text = node.label == node.id and node.id or (node.id .. ": " .. node.label)
    return math.min(width, math.max(8, measure(text) + 4))
  end
  local function blank()
    if #out > 0 then
      out[#out + 1] = ""
    end
  end
  for _, edge in ipairs(graph.edges) do
    blank()
    connected[edge.from.id], connected[edge.to.id] = true, true
    local reverse = graph.direction == "RL" or graph.direction == "BT"
    local first, second = edge.from, edge.to
    if reverse then
      first, second = second, first
    end
    local fw, sw = node_width(first), node_width(second)
    local stroke = edge.kind == "-.->" and "." or (edge.kind == "==>" and "=" or "-")
    local arrow = edge.kind == "---" and stroke:rep(3)
      or (reverse and ("<" .. stroke:rep(2)) or (stroke:rep(2) .. ">"))
    local gap = " " .. (edge.label ~= "" and (edge.label .. " ") or "") .. arrow .. " "
    local horizontal = graph.direction == "LR" or graph.direction == "RL"
    if horizontal and fw + sw + measure(gap) <= width then
      local a, b = box(first, fw, measure), box(second, sw, measure)
      if not a or not b then
        return nil
      end
      for i = 1, math.max(#a, #b) do
        out[#out + 1] = (a[i] or string.rep(" ", fw))
          .. (i == 2 and gap or string.rep(" ", measure(gap)))
          .. (b[i] or "")
      end
    else
      -- Narrow horizontal diagrams stack; arrowheads still identify the target.
      if not append(box(first, fw, measure)) then
        return nil
      end
      local connector = edge.kind == "-.->" and ":" or (edge.kind == "==>" and "!" or "|")
      if reverse and edge.kind ~= "---" then
        out[#out + 1] = "  ^"
      end
      local label_lines = wrap(edge.label, width - 4, measure)
      if not label_lines then
        return nil
      end
      for _, line in ipairs(label_lines) do
        out[#out + 1] = "  " .. connector .. (line ~= "" and (" " .. line) or "")
      end
      if not reverse and edge.kind ~= "---" then
        out[#out + 1] = "  v"
      end
      if not append(box(second, sw, measure)) then
        return nil
      end
    end
  end
  for _, node in ipairs(graph.nodes) do
    if not connected[node.id] then
      blank()
      if not append(box(node, node_width(node), measure)) then
        return nil
      end
    end
  end
  return out
end

---Layout native graphs/sequences, retaining a compact connection fallback.
---@param graph MDEyeMermaidGraph|MDEyeSequence
---@param width integer
---@param measure fun(text: string): integer
---@param mode "graph"|"connections"|nil
---@return string[]|nil, table<integer, string>|nil, string|nil
function M.layout(graph, width, measure, mode)
  if graph.kind == "sequence" then
    local lines, keys = require("mdeye.sequence").layout(graph, width, measure)
    return lines, keys, "sequence"
  end
  if mode ~= "connections" then
    local lines, keys = require("mdeye.graph").layout(graph, width, measure)
    if lines then
      return lines, keys, "graph"
    end
  end
  if #(graph.groups or {}) > 0 then
    return nil
  end -- never drop grouping
  return connections(graph, width, measure), {}, "connections"
end

return M
