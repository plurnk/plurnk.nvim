-- Common command routing for MCP, Agent Skills, outbound A2A agents, and file
-- members.

local M = {}

local FAMILIES = {
  mcp = "plurnk.mcp",
  skills = "plurnk.skills",
  agents = "plurnk.agents",
  members = "plurnk.members",
}

local aliases_by_workspace = {}
local pending = {}
local CACHE_TTL_NS = 5 * 1000 * 1000 * 1000

local function now() return vim.uv.hrtime() end

local function active_key(family)
  local state = require("plurnk.state")
  local workspace = state.get_active_workspace_name()
  if not workspace then return nil end
  return table.concat({ workspace, family }, "\0")
end

local function project_aliases(definitions)
  local aliases = {}
  for _, entry in ipairs(type(definitions) == "table" and definitions or {}) do
    if type(entry) == "table" and type(entry.alias) == "string" and entry.alias ~= "" then
      aliases[#aliases + 1] = entry.alias
    end
  end
  table.sort(aliases)
  return aliases
end

function M.run(family, args)
  local module = FAMILIES[family]
  assert(module, "unknown Functionality family: " .. tostring(family))
  return require(module).run(args, require("plurnk.workspace_context").resolve)
end

function M.remember_aliases(family, definitions)
  local key = active_key(family)
  if key then aliases_by_workspace[key] = { values = project_aliases(definitions), at = now() } end
end

function M.invalidate_aliases(family)
  local key = active_key(family)
  if key then aliases_by_workspace[key] = nil end
end

function M.complete_aliases(family, prefix)
  assert(FAMILIES[family], "unknown Functionality family: " .. tostring(family))
  local key = active_key(family)
  if not key then return {} end

  local cached = aliases_by_workspace[key]
  if (cached == nil or now() - cached.at >= CACHE_TTL_NS) and not pending[key] then
    pending[key] = true
    local ok = pcall(function()
      require("plurnk.client").send("workspace." .. family .. ".list", {}, false, function(result, problem)
        pending[key] = nil
        if problem ~= nil or type(result) ~= "table" or type(result.definitions) ~= "table" then return end
        aliases_by_workspace[key] = { values = project_aliases(result.definitions), at = now() }
      end)
    end)
    if not ok then pending[key] = nil end
  end

  local out = {}
  for _, alias in ipairs(cached and cached.values or {}) do
    if vim.startswith(alias, prefix or "") then out[#out + 1] = alias end
  end
  return out
end

return M
