-- Workspace MCP management is a thin :AI/ projection over AG-UI+ actions.
local NAME = "41_mcp"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["workspace.mcp.list"] = {
      servers = {
        { alias = "gitea", state = "connected", transport = "http", target = "https://example.test/mcp", enabledTools = { "issue_read" }, tools = { "issue_read", "issue_search" } },
        { alias = "local", state = "disabled", transport = "stdio", target = "local-mcp", tools = {} },
      },
    },
    ["workspace.mcp.add"] = { status = 201, server = { alias = "echo", state = "connected" } },
    ["workspace.mcp.enable"] = { status = 200, server = { alias = "echo", state = "connected" } },
    ["workspace.mcp.disable"] = { status = 200, server = { alias = "echo", state = "disabled" } },
    ["workspace.mcp.remove"] = { status = 200, alias = "echo", removed = true },
    ["workspace.mcp.oauth.complete"] = { status = 200, server = { alias = "gitea", state = "connected" } },
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
  H.assert_match(notices[#notices], "gitea%s+connected%s+http%s+https://example%.test/mcp%s+1/2 tools", "list renders enabled/catalog tool counts")
  H.assert_match(notices[#notices], "local%s+disabled%s+stdio%s+local%-mcp%s+0 tools", "list renders cold-disabled servers")

  local options = { args = { "--stdio" }, tools = { "issue_read" }, read = { "issue_read" } }
  local path = vim.fn.tempname() .. " options.json"
  vim.fn.writefile({ vim.json.encode(options) }, path)

  sent, notices = {}, {}
  ai({ args = "/mcp add echo \"/opt/MCP Servers/echo\" \"" .. path .. "\"", range = 0 })
  H.assert_eq(sent[1].method, "workspace.mcp.add", "add maps to the alias-first action")
  H.assert_truthy(vim.deep_equal(sent[1].params, {
    alias = "echo",
    target = "/opt/MCP Servers/echo",
    options = options,
  }), "add preserves the exact target and decoded options")

  sent = {}
  ai({ args = "/mcp enable echo", range = 0 })
  ai({ args = "/mcp disable echo", range = 0 })
  ai({ args = "/mcp remove echo", range = 0 })
  ai({ args = "/mcp oauth gitea https://client.example/callback?code=x&state=y", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "workspace.mcp.enable", params = { alias = "echo" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "workspace.mcp.disable", params = { alias = "echo" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "workspace.mcp.remove", params = { alias = "echo" } }), "remove action shape")
  H.assert_truthy(vim.deep_equal(sent[4], {
    method = "workspace.mcp.oauth.complete",
    params = { alias = "gitea", callbackUrl = "https://client.example/callback?code=x&state=y" },
  }), "OAuth completion action shape")

  results["workspace.mcp.add"] = {
    status = 202,
    authorization = { url = "https://gitea.example/authorize?state=abc" },
  }
  sent, notices = {}, {}
  ai({ args = "/mcp add echo echo-mcp", range = 0 })
  H.assert_match(notices[#notices], "https://gitea%.example/authorize%?state=abc", "authorization URL is shown")
  H.assert_match(notices[#notices], ":AI/mcp oauth echo <callback%-url>", "exact OAuth completion form is shown")

  -- JSON syntax is client-owned; option semantics are not. `{}` crosses the
  -- wire so the daemon can return its exact definition-invalid Problem.
  local malformed = vim.fn.tempname() .. ".json"
  local structurally_invalid = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{nope" }, malformed)
  vim.fn.writefile({ "{}" }, structurally_invalid)
  sent, notices = {}, {}
  ai({ args = "/mcp add echo echo-mcp " .. malformed, range = 0 })
  H.assert_eq(#sent, 0, "malformed local JSON never dispatches")
  H.assert_match(notices[#notices], "not valid JSON", "malformed JSON is diagnosed locally")
  ai({ args = "/mcp add echo echo-mcp " .. structurally_invalid, range = 0 })
  H.assert_eq(sent[1].method, "workspace.mcp.add", "option semantics reach daemon authority")
  H.assert_truthy(vim.deep_equal(sent[1].params.options, {}), "client does not imitate MCP schema validation")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/mcp add",
    "/mcp add echo",
    "/mcp enable",
    "/mcp disable two aliases",
    "/mcp remove",
    "/mcp oauth gitea",
    "/mcp add echo 'unterminated",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 7, "each malformed command has one usage diagnosis")

  local completion = commands.ai_complete("", "AI /mcp en", 0)
  H.assert_eq(table.concat(completion, ","), "enable", "MCP management verbs complete")
  local completion_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{}" }, completion_path)
  local prefix = completion_path:sub(1, #completion_path - 2)
  local file_completion = commands.ai_complete("", "AI /mcp add echo echo-mcp " .. prefix, 0)
  H.assert_truthy(#file_completion > 0, "MCP options path completes")

  vim.fn.delete(path)
  vim.fn.delete(malformed)
  vim.fn.delete(structurally_invalid)
  vim.fn.delete(completion_path)
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
