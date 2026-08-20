-- Small argv tokenizer shared by local slash-command projections. It produces
-- an argument vector; callers pass that vector directly to vim.system and
-- never interpolate it through a shell.

local M = {}

M.parse = function(source)
  local values, value = {}, ""
  local quote = nil
  local escaped, started = false, false
  for index = 1, #source do
    local character = source:sub(index, index)
    if escaped then
      value = value .. character
      escaped, started = false, true
    elseif character == "\\" then
      escaped, started = true, true
    elseif quote ~= nil then
      if character == quote then quote = nil else value = value .. character end
      started = true
    elseif character == '"' or character == "'" then
      quote, started = character, true
    elseif character:match("%s") then
      if started then
        values[#values + 1] = value
        value, started = "", false
      end
    else
      value, started = value .. character, true
    end
  end
  if escaped or quote ~= nil then return nil end
  if started then values[#values + 1] = value end
  return values
end

return M
