-- Outbound A2A agents management is a thin :AI/ projection over the Worker's
-- common Functionality actions: the client composes exact definitions only.
local NAME = "50_agents"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["worker.agents.list"] = {
      definitions = {
        { alias = "researcher", origin = "service", state = "active", definition = { name = "researcher", url = "https://agent.example" }, detail = { name = "Research Assistant", version = "2.1", description = "Finds sources", skills = { "search", "summarize" } } },
        { alias = "scribe", origin = "worker", state = "disabled", definition = { name = "scribe", url = "https://scribe.example" } },
        { alias = "ghost", origin = "service", state = "unavailable", definition = { name = "ghost", url = "http://127.0.0.1:9" }, problem = { detail = "no discoverable standard Agent Card" } },
      },
    },
    ["worker.agents.discover"] = {
      candidates = { { alias = "research-assistant", summary = "Finds sources", definition = { name = "research-assistant", url = "https://agent.example" }, provenance = { kind = "agent-card", source = "https://agent.example" } } },
    },
    ["worker.agents.add"] = { status = 201, alias = "researcher", definition = { alias = "researcher", state = "active" } },
    ["worker.agents.enable"] = { status = 200, alias = "researcher", definition = { alias = "researcher", state = "active" } },
    ["worker.agents.disable"] = { status = 200, alias = "researcher", definition = { alias = "researcher", state = "disabled" } },
    ["worker.agents.remove"] = { status = 200, alias = "researcher", removed = true },
  }
  local client = require("plurnk.client")
  client.check_daemon_once = function() end
  client.notify = function(message) notices[#notices + 1] = message end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if callback then callback(results[method]) end
  end
  local state = require("plurnk.state")
  state.set_active_workspace_name("agents-test")
  state.set_workspace_id("agents-test", 1)

  local commands = require("plurnk.language")
  local ai = commands.run

  ai({ args = "/agents", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.agents.list", params = {} }), ":AI/agents lists the Worker's agents")
  H.assert_match(notices[#notices], "researcher%s+active%s+https://agent%.example%s+Research Assistant v2%.1%s+2 skills%s+%(service%)", "list renders active agents with card identity")
  H.assert_match(notices[#notices], "scribe%s+disabled%s+https://scribe%.example", "list renders disabled Worker-owned agents")
  H.assert_match(notices[#notices], "ghost%s+unavailable%s+http://127%.0%.0%.1:9%s+%(service%)%s+— no discoverable standard Agent Card", "list renders unavailable agents with their problem")

  sent, notices = {}, {}
  ai({ args = "/agents discover https://agent.example", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.agents.discover", params = { source = "https://agent.example" } }), "discover action shape")
  H.assert_match(notices[#notices], "research%-assistant%s+candidate%s+https://agent%.example%s+Finds sources", "discover renders candidates")

  local options = { cardPath = "/cards/research.json", authorization = { type = "bearer", token = "${RESEARCH_TOKEN}" } }
  local path = vim.fn.tempname() .. " options.json"
  vim.fn.writefile({ vim.json.encode(options) }, path)
  sent, notices = {}, {}
  ai({ args = "/agents add researcher https://agent.example \"" .. path .. "\"", range = 0 })
  ai({ args = "/agents add scribe https://scribe.example", range = 0 })
  ai({ args = "/agents enable researcher", range = 0 })
  ai({ args = "/agents disable researcher", range = 0 })
  ai({ args = "/agents remove researcher", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.agents.add", params = { alias = "researcher", definition = { name = "researcher", url = "https://agent.example", cardPath = "/cards/research.json", authorization = { type = "bearer", token = "${RESEARCH_TOKEN}" } } } }), "add composes one exact definition from url and decoded options")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.agents.add", params = { alias = "scribe", definition = { name = "scribe", url = "https://scribe.example" } } }), "add without options")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.agents.enable", params = { alias = "researcher" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[4], { method = "worker.agents.disable", params = { alias = "researcher" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[5], { method = "worker.agents.remove", params = { alias = "researcher" } }), "remove action shape")
  H.assert_match(notices[1], "added: researcher %(active%)", "add renders the daemon state")
  H.assert_match(notices[5], "removed: researcher", "remove confirms")

  local malformed = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{nope" }, malformed)
  sent, notices = {}, {}
  ai({ args = "/agents add peer https://peer.example " .. malformed, range = 0 })
  H.assert_eq(#sent, 0, "malformed local JSON never dispatches")
  H.assert_match(notices[#notices], "not a valid JSON object", "malformed JSON is diagnosed locally")

  sent, notices = {}, {}
  for _, input in ipairs({ "/agents add", "/agents add one", "/agents discover", "/agents discover a b", "/agents enable", "/agents disable a b", "/agents remove", "/agents add echo 'unterminated" }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 8, "each malformed command has one usage diagnosis")
  H.assert_eq(table.concat(commands.complete("", "AI /agents di", 0), ","), "disable,discover", "agents verbs complete")

  vim.fn.delete(path)
  vim.fn.delete(malformed)
  print(NAME .. " ok")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
