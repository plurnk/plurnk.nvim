local M = {}

local DEFAULT = {
  proposals = "review",
}

function M.base()
  local configured = require("plurnk.config").get("loop_policy")
  local policy = vim.deepcopy(type(configured) == "table" and configured or DEFAULT)
  return policy
end

-- Lua's empty table encodes as JSON [], but CapabilityPolicy is an object.
-- Preserve every nonempty value for server validation; only the structurally
-- ambiguous empty table receives its contract-owned object identity.
function M.capabilities(value)
  local capabilities = type(value) == "table" and vim.deepcopy(value) or vim.empty_dict()
  if next(capabilities) == nil then return vim.empty_dict() end
  return capabilities
end

function M.prompt(text, base)
  local policy = vim.deepcopy(base or M.base())
  local prefix = text:sub(1, 1)
  if prefix == "?" then
    policy.proposals = "review"
  end
  local prompt = text
  if text:sub(1, 3) == "..." then
    prompt = text:sub(4):gsub("^%s*", "")
  elseif prefix == "?" or prefix == ":" then
    prompt = text:gsub("^[%?%:]+%s*", "")
  end
  return { policy = policy, prompt = prompt }
end

return M
