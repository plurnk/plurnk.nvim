-- Workspace MCP management is a thin :AI/ projection over AG-UI+ actions.
local NAME = "41_mcp"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["workspace.mcp.list"] = {
      servers = {
        { name = "gitea", state = "connected", transport = "http", tools = { "issue_read", "issue_search" } },
        { name = "local", state = "connected", transport = "stdio", tools = {} },
      },
    },
    ["workspace.mcp.attach"] = { status = 201, server = { name = "echo", state = "connected" } },
    ["workspace.mcp.replace"] = { status = 200, server = { name = "echo", state = "connected" } },
    ["workspace.mcp.detach"] = { status = 200, name = "echo", detached = true },
    ["workspace.mcp.reconnect"] = { status = 200, server = { name = "echo", state = "connected" } },
    ["workspace.mcp.oauth.complete"] = { status = 200, server = { name = "gitea", state = "connected" } },
  }
  local client = require("plurnk.client")
  client.check_daemon_once = function() end
  client.notify = function(message) notices[#notices + 1] = message end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if callback then callback(results[method]) end
  end
  local state = require("plurnk.state")
  state.set_active_workspace_name("mcp-test")
  state.set_workspace_id("mcp-test", 1)

  local commands = require("plurnk.commands")
  local ai = commands.ai

  ai({ args = "/mcp", range = 0 })
  H.assert_eq(sent[1].method, "workspace.mcp.list", ":AI/mcp lists workspace servers")
  H.assert_match(notices[#notices], "gitea%s+connected%s+http%s+2 tools", "list renders server state")
  H.assert_match(notices[#notices], "local%s+connected%s+stdio%s+0 tools", "list renders empty catalog")

  local definition = { name = "echo", transport = "stdio", command = "/opt/echo", args = { "--stdio" } }
  local path = vim.fn.tempname() .. " definition.json"
  vim.fn.writefile({ vim.json.encode(definition) }, path)

  sent, notices = {}, {}
  ai({ args = "/mcp " .. path, range = 0 })
  ai({ args = "/mcp replace " .. path, range = 0 })
  H.assert_eq(sent[1].method, "workspace.mcp.attach", "definition file maps to attach")
  H.assert_truthy(vim.deep_equal(sent[1].params.server, definition), "attach forwards decoded definition unchanged")
  H.assert_eq(sent[2].method, "workspace.mcp.replace", "replace maps to replace action")
  H.assert_truthy(vim.deep_equal(sent[2].params.server, definition), "replace forwards decoded definition unchanged")

  sent = {}
  ai({ args = "/mcp detach echo", range = 0 })
  ai({ args = "/mcp reconnect echo", range = 0 })
  ai({ args = "/mcp oauth gitea https://client.example/callback?code=x&state=y", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "workspace.mcp.detach", params = { name = "echo" } }), "detach action shape")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "workspace.mcp.reconnect", params = { name = "echo" } }), "reconnect action shape")
  H.assert_truthy(vim.deep_equal(sent[3], {
    method = "workspace.mcp.oauth.complete",
    params = { name = "gitea", callbackUrl = "https://client.example/callback?code=x&state=y" },
  }), "OAuth completion action shape")

  results["workspace.mcp.attach"] = {
    status = 202,
    authorization = { url = "https://gitea.example/authorize?state=abc" },
  }
  sent, notices = {}, {}
  ai({ args = "/mcp " .. path, range = 0 })
  H.assert_match(notices[#notices], "https://gitea%.example/authorize%?state=abc", "authorization URL is shown")
  H.assert_match(notices[#notices], ":AI/mcp oauth echo <callback%-url>", "exact OAuth completion form is shown")

  -- JSON syntax is client-owned; definition semantics are not. `{}` crosses
  -- the wire so the daemon can return its exact definition-invalid Problem.
  local malformed = vim.fn.tempname() .. ".json"
  local structurally_invalid = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{nope" }, malformed)
  vim.fn.writefile({ "{}" }, structurally_invalid)
  sent, notices = {}, {}
  ai({ args = "/mcp " .. malformed, range = 0 })
  H.assert_eq(#sent, 0, "malformed local JSON never dispatches")
  H.assert_match(notices[#notices], "not valid JSON", "malformed JSON is diagnosed locally")
  ai({ args = "/mcp " .. structurally_invalid, range = 0 })
  H.assert_eq(sent[1].method, "workspace.mcp.attach", "definition semantics reach daemon authority")
  H.assert_truthy(vim.deep_equal(sent[1].params.server, {}), "client does not imitate MCP schema validation")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/mcp replace",
    "/mcp detach",
    "/mcp detach two names",
    "/mcp reconnect",
    "/mcp oauth gitea",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 5, "each malformed command has one usage diagnosis")

  local completion = commands.ai_complete("", "AI /mcp re", 0)
  H.assert_eq(table.concat(completion, ","), "reconnect,replace", "MCP management verbs complete")
  local completion_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{}" }, completion_path)
  local file_completion = commands.ai_complete("", "AI /mcp replace " .. completion_path:sub(1, #completion_path - 2), 0)
  H.assert_truthy(#file_completion > 0, "MCP replacement definition path completes")

  vim.fn.delete(path)
  vim.fn.delete(malformed)
  vim.fn.delete(structurally_invalid)
  vim.fn.delete(completion_path)
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
