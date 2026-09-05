---Shared-node flowcharts with orthogonal edge lanes and subgraph containers.
local draw = require("mdeye.diagram")
local M = {}

local function order_nodes(graph)
  local items = {}
  local function visit(parent, depth)
    local local_items = {}
    for _, node in ipairs(graph.nodes) do
      if node.group == parent then
        local_items[#local_items + 1] = { node = node, order = node.order }
      end
    end
    for _, group in ipairs(graph.groups or {}) do
      if group.parent == parent then
        local_items[#local_items + 1] = { group = group, order = group.order }
      end
    end
    table.sort(local_items, function(a, b)
      return a.order < b.order
    end)
    if graph.direction == "BT" or graph.direction == "RL" then
      local reversed = {}
      for i = #local_items, 1, -1 do
        reversed[#reversed + 1] = local_items[i]
      end
      local_items = reversed
    end
    for _, item in ipairs(local_items) do
      if item.node then
        items[#items + 1] = { node = item.node, depth = depth }
      else
        items[#items + 1] = { group = item.group, depth = depth, opening = true }
        visit(item.group.id, depth + 1)
        items[#items + 1] = { group = item.group, depth = depth }
      end
    end
  end
  visit(nil, 0)
  return items
end

local function lanes(edges, positions)
  local occupied, assignments = {}, {}
  for index, edge in ipairs(edges) do
    local a, b = positions[edge.from.id], positions[edge.to.id]
    local lo, hi = math.min(a.index, b.index), math.max(a.index, b.index)
    local lane = 1
    while occupied[lane] do
      local available = true
      for _, interval in ipairs(occupied[lane]) do
        if not (hi < interval[1] or lo > interval[2]) then
          available = false
          break
        end
      end
      if available then
        break
      end
      lane = lane + 1
    end
    occupied[lane] = occupied[lane] or {}
    occupied[lane][#occupied[lane] + 1] = { lo, hi }
    assignments[index] = lane
  end
  return assignments, #occupied
end

---Returns nil when a shared graph cannot fit; caller retains the connection view.
---@param graph MDEyeMermaidGraph
---@param width integer
---@param measure fun(text: string): integer
---@return string[]|nil, table|nil
function M.layout(graph, width, measure)
  local items, positions, degree = order_nodes(graph), {}, {}
  for _, edge in ipairs(graph.edges) do
    degree[edge.from.id] = (degree[edge.from.id] or 0) + 1
    degree[edge.to.id] = (degree[edge.to.id] or 0) + 1
  end
  local ordinal = 0
  for _, item in ipairs(items) do
    if item.node then
      ordinal = ordinal + 1
      positions[item.node.id] = { index = ordinal, used = 0 }
    end
  end
  local assigned, lane_count = lanes(graph.edges, positions)
  local horizontal = (graph.direction == "LR" or graph.direction == "RL")
    and #(graph.groups or {}) == 0
  local natural = 0
  for _, item in ipairs(items) do
    if item.node then
      local w = math.max(8, measure(draw.label(item.node)) + 4, (degree[item.node.id] or 0) * 4 + 2)
      natural = natural + w + 3
    end
  end
  horizontal = horizontal and natural - 3 <= width
  local canvas = draw.canvas(width, measure)
  local body_width = width - (lane_count > 0 and (lane_count * 2 + 6) or 0)
  local ideal = 12
  for _, item in ipairs(items) do
    local label = item.node and draw.label(item.node) or item.group.label
    ideal = math.max(ideal, measure(label) + 4 + item.depth * 4)
  end
  body_width = math.min(body_width, ideal)
  local y, x, max_height = 1, 1, 0
  local containers = {}
  for _, item in ipairs(items) do
    if item.node then
      local node = item.node
      local w = horizontal
          and math.max(8, measure(draw.label(node)) + 4, (degree[node.id] or 0) * 4 + 2)
        or math.min(body_width - item.depth * 4, math.max(12, measure(draw.label(node)) + 4))
      if w < 8 then
        return nil
      end
      local box = draw.box(node, w, measure, horizontal and 3 or ((degree[node.id] or 0) + 2))
      if not box then
        return nil
      end
      local px = horizontal and x or (1 + item.depth * 2)
      for i, line in ipairs(box) do
        canvas:put(px, y + i - 1, line)
        canvas.keys[y + i - 1] = "node:" .. node.id
      end
      local pos = positions[node.id]
      pos.x, pos.y, pos.w, pos.h = px, y, w, #box
      max_height = math.max(max_height, #box)
      if horizontal then
        x = x + w + 3
      else
        y = y + #box + 2
      end
    elseif item.opening then
      local title = draw.wrap(item.group.label, body_width - item.depth * 4 - 4, measure)
      if not title then
        return nil
      end
      containers[item.group.id] =
        { top = y, x = 1 + item.depth * 2, right = body_width - item.depth * 2 }
      local container = containers[item.group.id]
      canvas:put(container.x, y, "+" .. string.rep("-", container.right - container.x - 1) .. "+")
      for _, line in ipairs(title) do
        y = y + 1
        canvas:put(container.x + 2, y, line)
      end
      y = y + 2
    else
      local container = containers[item.group.id]
      for row = container.top + 1, y - 1 do
        canvas:put(container.x, row, "|")
        canvas:put(container.right, row, "|")
      end
      canvas:put(container.x, y, "+" .. string.rep("-", container.right - container.x - 1) .. "+")
      y = y + 2
    end
  end
  -- Dedicated ports and interval-colored lanes keep cycles and parallel edges distinct.
  for index, edge in ipairs(graph.edges) do
    local a, b = positions[edge.from.id], positions[edge.to.id]
    a.used = a.used + 1
    local ap = a.used
    b.used = b.used + 1
    local bp = b.used
    local stroke = edge.kind == "-.->" and "." or (edge.kind == "==>" and "=" or "-")
    if horizontal then
      local ax, bx = a.x + ap * 4 - 2, b.x + bp * 4 - 2
      local ay, by = a.y + a.h, b.y + b.h
      local lane = max_height + 2 + assigned[index] * 2
      canvas:line(ax, ay, ax, lane)
      canvas:line(ax, lane, bx, lane, stroke)
      canvas:line(bx, lane, bx, by)
      canvas:put(ax, lane, "+")
      canvas:put(bx, lane, "+")
      canvas:put(ax, ay, tostring(index))
      canvas:put(bx, by, edge.kind == "---" and "|" or "^")
    else
      local ax, bx = a.x + a.w, b.x + b.w
      local ay, by = a.y + ap, b.y + bp
      local lane = body_width + 5 + assigned[index] * 2
      canvas:line(ax, ay, lane, ay, stroke)
      canvas:line(lane, ay, lane, by)
      canvas:line(lane, by, bx, by, stroke)
      canvas:put(lane, ay, "+")
      canvas:put(lane, by, "+")
      canvas:put(ax, ay, tostring(index))
      canvas:put(bx, by, edge.kind == "---" and "-" or "<")
    end
  end
  -- Sparse rows between boxes are real blank lines.
  local last = 0
  for row in pairs(canvas.rows) do
    last = math.max(last, row)
  end
  for row = 1, last do
    canvas.rows[row] = canvas.rows[row] or {}
  end
  local lines, keys = canvas:finish()
  if #graph.edges > 0 then
    lines[#lines + 1] = ""
    for index, edge in ipairs(graph.edges) do
      local label = ("%d: %s %s %s%s"):format(
        index,
        edge.from.id,
        edge.kind,
        edge.to.id,
        edge.label ~= "" and (" — " .. edge.label) or ""
      )
      for _, line in ipairs(draw.wrap(label, width, measure) or {}) do
        lines[#lines + 1] = line
        keys[#lines] = "edge:" .. index
      end
    end
  end
  return lines, keys
end

return M
