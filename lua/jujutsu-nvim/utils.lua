local M = {}

M.remove = function(list, pred)
  local filtered = {}
  for _, v in ipairs(list) do
    if not pred(v) then
      table.insert(filtered, v)
    end
  end
  return filtered
end

M.is_blank = function(str)
  return vim.trim(str or "") == ""
end

M.keys = function(t)
  local keys = {}
  for k, _ in pairs(t) do
    table.insert(keys, k)
  end
  return keys
end

M.reverse = function(list)
  local reversed = {}
  for i = #list, 1, -1 do
    table.insert(reversed, list[i])
  end
  return reversed
end

return M
