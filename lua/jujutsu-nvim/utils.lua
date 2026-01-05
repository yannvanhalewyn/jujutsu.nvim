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

return M
