local M = {}

local function render(result)
  if type(result) ~= "table" or type(result.effective) ~= "table" then return end
  local lines = {
    "capabilities:",
    "  effective: " .. vim.json.encode(result.effective),
    "  workspace: " .. vim.json.encode(result.workspace),
    "  service: " .. vim.json.encode(result.service),
  }
  require("plurnk.client").notify(
    table.concat(lines, "\n"),
    vim.log.levels.INFO)
end

function M.run(raw)
  require("plurnk.workspace_context").resolve(function()
    local client = require("plurnk.client")
    local source = vim.trim(raw or "")
    if source == "" then
      client.send("workspace.capabilities.get", {}, false, render)
      return
    end
    local ok, capabilities = pcall(vim.json.decode, source)
    if not ok or type(capabilities) ~= "table" then
      client.notify("/capabilities needs a CapabilityPolicy JSON object", vim.log.levels.WARN)
      return
    end
    client.send("workspace.capabilities.set", {
      policy = capabilities,
    }, false, render)
  end)
end

return M
