-- Common command routing for MCP, Agent Skills, and outbound A2A agents.

local M = {}

local FAMILIES = {
  mcp = "plurnk.mcp",
  skills = "plurnk.skills",
  agents = "plurnk.agents",
}

function M.run(family, args)
  local module = FAMILIES[family]
  assert(module, "unknown Functionality family: " .. tostring(family))
  return require(module).run(args, require("plurnk.workspace_context").resolve)
end

function M.complete(cmdline)
  for _, family in ipairs({ "mcp", "skills", "agents" }) do
    local completion = require(FAMILIES[family]).complete(cmdline)
    if completion then return completion end
  end
  return nil
end

return M
