-- Installed-client dogfood: current MCP lifecycle succeeds through AG-UI+;
-- a pre-server/discover peer is rejected with the daemon's exact diagnosis.
local NAME = "42_mcp_live"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local service_root = os.getenv("PLURNK_SERVICE_DIR") or (root .. "/../plurnk-service")
  local current_fixture = service_root .. "/plurnk-mcp/src/fixtures/echo-server.mjs"
  local legacy_fixture = service_root .. "/plurnk-mcp/src/fixtures/legacy-server.mjs"
  if vim.fn.filereadable(current_fixture) == 0 or vim.fn.filereadable(legacy_fixture) == 0 then
    error("MCP dogfood fixtures are unavailable under " .. service_root)
  end

  local current_definition = vim.fn.tempname() .. " current.json"
  local legacy_definition = vim.fn.tempname() .. " legacy.json"
  local node = vim.fn.exepath("node")
  vim.fn.writefile({ vim.json.encode({
    args = { current_fixture },
    tools = { "echo" },
    read = { "echo" },
  }) }, current_definition)
  vim.fn.writefile({ vim.json.encode({
    args = { legacy_fixture },
  }) }, legacy_definition)

  local notes = {}
  local original_notify = vim.notify
  vim.notify = function(message, ...)
    notes[#notes + 1] = tostring(message)
    return original_notify(message, ...)
  end
  local function wait_note(pattern, label)
    H.wait_for(function()
      for _, message in ipairs(notes) do
        if message:match(pattern) then return true end
      end
      return false
    end, 20000, label)
  end

  local workspace = H.call("workspace.create", { projectRoot = root }, 10000)
  H.assert_type(workspace, "table", "workspace.create result")
  local state = require("plurnk.state")
  state.set_active_workspace_name(workspace.name)
  state.set_workspace_id(workspace.name, workspace.id)

  local ai = require("plurnk.commands").ai
  ai({ args = "/mcp add current " .. node .. " \"" .. current_definition .. "\"", range = 0 })
  wait_note("added: current %(connected%)", "current add")

  ai({ args = "/mcp", range = 0 })
  wait_note("current%s+connected%s+stdio.*1/2 tools", "current list")

  ai({ args = "/mcp disable current", range = 0 })
  wait_note("disabled: current %(disabled%)", "current disable")

  ai({ args = "/mcp enable current", range = 0 })
  wait_note("enabled: current %(connected%)", "current enable")

  ai({ args = "/mcp add legacy " .. node .. " \"" .. legacy_definition .. "\"", range = 0 })
  wait_note("MCP server 'legacy' did not offer required revision 2026%-07%-28 through server/discover", "legacy revision attribution")
  wait_note("upgrade or replace the legacy endpoint", "legacy recovery")

  ai({ args = "/mcp remove current", range = 0 })
  wait_note("removed: current", "current remove")

  vim.notify = original_notify
  vim.fn.delete(current_definition)
  vim.fn.delete(legacy_definition)
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
