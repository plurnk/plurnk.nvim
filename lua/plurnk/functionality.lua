-- Common command routing for MCP, Agent Skills, outbound A2A agents, file
-- members, and the environment.

local M = {}

-- Default action prefixes. Env also accepts an explicit workspace scope.
local FAMILIES = {
  mcp = { module = "plurnk.mcp", actions = "workspace.mcp" },
  skills = { module = "plurnk.skills", actions = "workspace.skills" },
  agents = { module = "plurnk.agents", actions = "workspace.agents" },
  members = { module = "plurnk.members", actions = "workspace.members" },
  env = { module = "plurnk.env", actions = "worker.env" },
}

local aliases_by_workspace = {}
local pending = {}
local CACHE_TTL_NS = 5 * 1000 * 1000 * 1000

local function now() return vim.uv.hrtime() end

local function active_key(family, binding, scope)
  local context = require("plurnk.workspace_context")
  if not binding and not context.active() then return nil end
  binding = binding or context.binding()
  return table.concat({ binding.workspace, family, family == "env" and (scope == "workspace" and "" or binding.threadId) or "" }, "\0")
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
  local family_spec = FAMILIES[family]
  assert(family_spec, "unknown Functionality family: " .. tostring(family))
  return require(family_spec.module).run(args, require("plurnk.workspace_context").resolve)
end

function M.remember_aliases(family, definitions, binding, scope)
  local key = active_key(family, binding, scope)
  if key then aliases_by_workspace[key] = { values = project_aliases(definitions), at = now() } end
end

function M.invalidate_aliases(family, binding, scope)
  local key = active_key(family, binding, scope)
  if key then aliases_by_workspace[key] = nil end
end

function M.complete_aliases(family, prefix, scope)
  assert(FAMILIES[family], "unknown Functionality family: " .. tostring(family))
  local key = active_key(family, nil, scope)
  if not key then return {} end

  local cached = aliases_by_workspace[key]
  if (cached == nil or now() - cached.at >= CACHE_TTL_NS) and not pending[key] then
    pending[key] = true
    local ok = pcall(function()
      local action = family == "env" and scope == "workspace" and "workspace.env" or FAMILIES[family].actions
      require("plurnk.client").send(action .. ".list", {}, false, function(result, problem)
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
