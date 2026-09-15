-- The operator's environment, read the way the terminal client reads it
-- ({§nvim-transport-target}): the editor's own environment first, then `./.env` in the
-- working directory, then the XDG user file the daemon itself is configured from
-- (`$XDG_CONFIG_HOME/plurnk/.env`, `~/.config/plurnk/.env` by default). Files are read on
-- demand and never cached: the operator edits the file and expects the next action to see it.

local M = {}

-- XDG is the cross-process user-configuration contract; a relative XDG_CONFIG_HOME is ignored.
M.user_config_file = function()
  local configured = vim.env.XDG_CONFIG_HOME
  local config_home = (type(configured) == "string" and configured:sub(1, 1) == "/")
    and configured
    or ((vim.env.HOME ~= nil and vim.env.HOME ~= "") and vim.env.HOME or vim.fn.expand("~")) .. "/.config"
  return config_home .. "/plurnk/.env"
end

M.files = function()
  return { vim.fn.getcwd() .. "/.env", M.user_config_file() }
end

-- `KEY=VALUE` lines, an optional `export ` prefix, `#` comments, and one pair of matching
-- quotes around the value. Anything else is not a definition.
local function parse(lines)
  local values = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^%s*export%s+([%w_]+)%s*=%s*(.-)%s*$")
    if key == nil then key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$") end
    if key ~= nil then
      local quoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
      if quoted ~= nil then
        value = quoted
      else
        value = value:gsub("%s+#.*$", "")
      end
      values[key] = value
    end
  end
  return values
end

M.read = function(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  return parse(vim.fn.readfile(path))
end

-- The first non-empty definition in precedence order, else nil.
M.get = function(name)
  local own = vim.env[name]
  if type(own) == "string" and own ~= "" then return own end
  for _, path in ipairs(M.files()) do
    local value = M.read(path)[name]
    if type(value) == "string" and value ~= "" then return value end
  end
  return nil
end

return M
