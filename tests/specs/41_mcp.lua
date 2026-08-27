-- Worker MCP management is a thin :AI/ projection over the common Functionality actions.
local NAME = "41_mcp"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["worker.mcp.list"] = {
      definitions = {
        { alias = "gitea", origin = "worker", state = "active", definition = { name = "gitea", transport = "http", url = "https://example.test/mcp", tools = { "issue_read" } }, detail = { tools = { "issue_read", "issue_search" } } },
        { alias = "local", origin = "service", state = "disabled", definition = { name = "local", transport = "stdio", command = "local-mcp", args = {} }, detail = { tools = {} } },
        { alias = "flaky", origin = "worker", state = "unavailable", definition = { name = "flaky", transport = "stdio", command = "flaky-mcp", args = {} }, problem = { detail = "spawn failed" } },
      },
    },
    ["worker.mcp.discover"] = {
      candidates = { { alias = "echo", definition = { name = "echo", transport = "http", url = "https://echo.test/mcp" }, provenance = { kind = "direct-target" } } },
    },
    ["worker.mcp.add"] = { status = 201, alias = "echo", definition = { alias = "echo", state = "active" } },
    ["worker.mcp.enable"] = { status = 200, alias = "echo", definition = { alias = "echo", state = "active" } },
    ["worker.mcp.disable"] = { status = 200, alias = "echo", definition = { alias = "echo", state = "disabled" } },
    ["worker.mcp.remove"] = { status = 200, alias = "echo", removed = true },
    ["worker.mcp.oauth.complete"] = { status = 200, alias = "gitea", definition = { alias = "gitea", state = "active" } },
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

  local commands = require("plurnk.language")
  local ai = commands.run

  ai({ args = "/mcp", range = 0 })
  H.assert_eq(sent[1].method, "worker.mcp.list", ":AI/mcp lists the Worker's MCP definitions")
  H.assert_match(notices[#notices], "gitea%s+active%s+http%s+https://example%.test/mcp%s+1/2 tools", "list renders enabled/catalog tool counts")
  H.assert_match(notices[#notices], "local%s+disabled%s+stdio%s+local%-mcp%s+0 tools%s+%(service%)", "list renders disabled service definitions")
  H.assert_match(notices[#notices], "flaky%s+unavailable%s+stdio%s+flaky%-mcp%s+— spawn failed", "list renders unavailable definitions with their problem")

  sent, notices = {}, {}
  ai({ args = "/mcp discover https://echo.test/mcp", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.mcp.discover", params = { source = "https://echo.test/mcp" } }), "discover action shape")
  H.assert_match(notices[#notices], "echo%s+candidate%s+http%s+https://echo%.test/mcp", "discover renders candidates")

  local options = { args = { "--stdio" }, tools = { "issue_read" }, read = { "issue_read" } }
  local path = vim.fn.tempname() .. " options.json"
  vim.fn.writefile({ vim.json.encode(options) }, path)

  sent, notices = {}, {}
  ai({ args = "/mcp add echo \"/opt/MCP Servers/echo\" \"" .. path .. "\"", range = 0 })
  H.assert_eq(sent[1].method, "worker.mcp.add", "add maps to the alias-first action")
  H.assert_truthy(vim.deep_equal(sent[1].params, {
    alias = "echo",
    definition = { name = "echo", transport = "stdio", command = "/opt/MCP Servers/echo", args = { "--stdio" }, tools = { "issue_read" }, read = { "issue_read" } },
  }), "add composes one exact stdio definition from target and decoded options")
  H.assert_match(notices[#notices], "added: echo %(active%)", "add renders the daemon state")

  sent = {}
  ai({ args = "/mcp add brave https://example.test/mcp", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1].params, {
    alias = "brave",
    definition = { name = "brave", transport = "http", url = "https://example.test/mcp" },
  }), "an absolute http(s) target composes a Streamable HTTP definition")

  sent = {}
  ai({ args = "/mcp enable echo", range = 0 })
  ai({ args = "/mcp disable echo", range = 0 })
  ai({ args = "/mcp remove echo", range = 0 })
  ai({ args = "/mcp oauth gitea https://client.example/callback?code=x&state=y", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.mcp.enable", params = { alias = "echo" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.mcp.disable", params = { alias = "echo" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.mcp.remove", params = { alias = "echo" } }), "remove action shape")
  H.assert_truthy(vim.deep_equal(sent[4], {
    method = "worker.mcp.oauth.complete",
    params = { alias = "gitea", callbackUrl = "https://client.example/callback?code=x&state=y" },
  }), "OAuth completion action shape")

  local specialization = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ vim.json.encode({ tools = { "issue_search" } }) }, specialization)
  sent, notices = {}, {}
  ai({ args = "/mcp enable gitea " .. specialization, range = 0 })
  H.assert_eq(sent[1].method, "worker.mcp.list", "specialization reads the current definition")
  H.assert_truthy(vim.deep_equal(sent[2], {
    method = "worker.mcp.add",
    params = {
      alias = "gitea",
      definition = {
        name = "gitea",
        transport = "http",
        url = "https://example.test/mcp",
        tools = { "issue_search" },
      },
    },
  }), "enable options specialize the current definition through worker.mcp.add")

  results["worker.mcp.add"] = {
    status = 202,
    alias = "echo",
    definition = { alias = "echo", state = "authorization-required", authorization = { url = "https://gitea.example/authorize?state=abc" } },
  }
  sent, notices = {}, {}
  ai({ args = "/mcp add echo echo-mcp", range = 0 })
  H.assert_match(notices[#notices], "https://gitea%.example/authorize%?state=abc", "authorization URL is shown")
  H.assert_match(notices[#notices], ":AI/mcp oauth echo <callback%-url>", "exact OAuth completion form is shown")

  -- JSON syntax is client-owned; definition semantics are not. `{}` composes
  -- the bare definition so the daemon returns its exact definition-invalid Problem.
  local malformed = vim.fn.tempname() .. ".json"
  local structurally_invalid = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{nope" }, malformed)
  vim.fn.writefile({ "{}" }, structurally_invalid)
  sent, notices = {}, {}
  ai({ args = "/mcp add echo echo-mcp " .. malformed, range = 0 })
  H.assert_eq(#sent, 0, "malformed local JSON never dispatches")
  H.assert_match(notices[#notices], "not a valid JSON object", "malformed JSON is diagnosed locally")
  ai({ args = "/mcp add echo echo-mcp " .. structurally_invalid, range = 0 })
  H.assert_eq(sent[1].method, "worker.mcp.add", "definition semantics reach daemon authority")
  H.assert_truthy(vim.deep_equal(sent[1].params.definition, { name = "echo", transport = "stdio", command = "echo-mcp", args = {} }), "client does not imitate MCP schema validation")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/mcp add",
    "/mcp add echo",
    "/mcp discover",
    "/mcp enable",
    "/mcp disable two aliases",
    "/mcp remove",
    "/mcp oauth gitea",
    "/mcp add echo 'unterminated",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 8, "each malformed command has one usage diagnosis")

  local completion = commands.complete("", "AI /mcp en", 0)
  H.assert_eq(table.concat(completion, ","), "enable", "MCP management verbs complete")
  H.assert_eq(table.concat(commands.complete("", "AI /mcp di", 0), ","), "disable,discover", "discover completes alongside disable")
  local completion_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{}" }, completion_path)
  local prefix = completion_path:sub(1, #completion_path - 2)
  local file_completion = commands.complete("", "AI /mcp add echo echo-mcp " .. prefix, 0)
  H.assert_truthy(#file_completion > 0, "MCP options path completes")

  vim.fn.delete(path)
  vim.fn.delete(malformed)
  vim.fn.delete(structurally_invalid)
  vim.fn.delete(completion_path)
  vim.fn.delete(specialization)
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
