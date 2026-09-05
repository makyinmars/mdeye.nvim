---Display-cell primitives shared by native diagram layouts.
local M = {}

function M.wrap(text, width, measure)
  if width < 1 then
    return nil
  end
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

function M.label(node)
  return node.label == node.id and node.id or (node.id .. ": " .. node.label)
end

function M.box(node, width, measure, min_height)
  local lines = M.wrap(M.label(node), width - 4, measure)
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
  while #out < (min_height or 0) - 1 do
    out[#out + 1] = "|" .. string.rep(" ", width - 2) .. "|"
  end
  out[#out + 1] = border
  return out
end

function M.canvas(width, measure)
  local grid = { rows = {}, keys = {}, width = width, measure = measure }
  function grid:put(x, y, text)
    self.rows[y] = self.rows[y] or {}
    for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
      local size = self.measure(ch)
      if size == 0 and x > 1 then
        local previous = x - 1
        while previous > 1 and self.rows[y][previous] == "" do
          previous = previous - 1
        end
        self.rows[y][previous] = (self.rows[y][previous] or "") .. ch
      else
        self.rows[y][x] = ch
        for offset = 1, size - 1 do
          self.rows[y][x + offset] = ""
        end
        x = x + size
      end
    end
  end
  function grid:line(x1, y1, x2, y2, stroke)
    local vertical = x1 == x2
    local dx, dy = x2 >= x1 and 1 or -1, y2 >= y1 and 1 or -1
    local count = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
    for i = 0, count do
      local x, y = x1 + (vertical and 0 or i * dx), y1 + (vertical and i * dy or 0)
      local old = self.rows[y] and self.rows[y][x]
      local ch = stroke or (vertical and "|" or "-")
      if old and old ~= " " and old ~= ch then
        ch = "x"
      end
      self:put(x, y, ch)
    end
  end
  function grid:finish()
    local result = {}
    for y = 1, #self.rows do
      local chars = {}
      for x = 1, self.width do
        chars[#chars + 1] = self.rows[y][x] or " "
      end
      result[y] = table.concat(chars):gsub("%s+$", "")
    end
    return result, self.keys
  end
  return grid
end

return M
