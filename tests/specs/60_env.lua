-- The environment is a thin :AI/ projection over the Worker's common
-- Functionality actions — the same lifecycle as /mcp, /skills, /agents, and
-- /members — with one difference: the family is worker-scoped, so its actions
-- are worker.env.* and the bridge binds the active Worker. The client composes
-- one exact { value } definition, handing the value over verbatim, and renders
-- the daemon's states; against the live daemon an added name lists as the
-- Worker's own and discover names a sibling package's declaration.
local NAME = "60_env"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["worker.env.list"] = {
      definitions = {
        { alias = "PATH", origin = "service", state = "active", definition = { value = "/usr/bin:/bin" } },
        { alias = "CI", origin = "service", state = "disabled", definition = { value = "1" } },
        { alias = "CARGO_TARGET_DIR", origin = "worker", state = "active", definition = { value = "/tmp/shared" } },
        { alias = "TOOLCHAIN", origin = "worker", state = "active", inherited = "alice", definition = { value = "stable" } },
      },
    },
    ["worker.env.discover"] = {
      candidates = {
        { alias = "PAGER", definition = { value = "cat" }, provenance = { kind = "declaration", source = "@plurnk/plurnk-execs", reference = ".env.defaults" }, summary = "A pager that waits for a keypress hangs a spawn that has no terminal." },
        { alias = "TAVILY_API_KEY", definition = { value = "" }, provenance = { kind = "declaration", source = "@plurnk/plurnk-schemes-http-tavily", reference = ".env.defaults" }, summary = "The Tavily API key." },
      },
    },
    ["worker.env.add"] = { status = 201, alias = "CARGO_TARGET_DIR", definition = { alias = "CARGO_TARGET_DIR", state = "active" } },
    ["worker.env.enable"] = { status = 200, alias = "CI", definition = { alias = "CI", state = "active" } },
    ["worker.env.disable"] = { status = 200, alias = "CI", definition = { alias = "CI", state = "disabled" } },
    ["worker.env.remove"] = { status = 200, alias = "CARGO_TARGET_DIR", removed = true },
  }
  local client = require("plurnk.client")
  local real_send, real_check = client.send, client.check_daemon_once
  client.check_daemon_once = function() end
  client.notify = function(message) notices[#notices + 1] = message end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if callback then callback(results[method]) end
  end
  local state = require("plurnk.state")
  state.set_active_workspace_name("env-test")
  state.set_workspace_id("env-test", 1)
  state.set_worker_id("env-test", 7)

  local commands = require("plurnk.language")
  local ai = commands.run

  ai({ args = "/env", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.env.list", params = {} }), ":AI/env lists the Worker's environment through the worker-scoped action")
  H.assert_match(notices[#notices], "PATH%s+active%s+/usr/bin:/bin%s+%(service%)", "list renders an ambient name with its value")
  H.assert_match(notices[#notices], "CI%s+disabled%s+1%s+%(service%)", "a masked ambient name keeps its value in view")
  H.assert_match(notices[#notices], "CARGO_TARGET_DIR%s+active%s+/tmp/shared\n", "list renders the Worker's own entry")
  H.assert_match(notices[#notices], "TOOLCHAIN%s+active%s+stable%s+%(from alice%)", "an inherited entry names the Worker that set it")

  sent, notices = {}, {}
  vim.cmd("PlurnkEnv")
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.env.list", params = {} }), ":PlurnkEnv is the native spelling of :AI/env")
  results["worker.env.list"] = { definitions = {} }
  sent, notices = {}, {}
  ai({ args = "/env", range = 0 })
  H.assert_match(notices[#notices], "environment: none", "an empty list says so")

  sent, notices = {}, {}
  ai({ args = "/env discover", range = 0 })
  ai({ args = "/env discover search", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.env.discover", params = {} }), "an empty query is the whole catalog")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.env.discover", params = { query = "search" } }), "a query passes through verbatim")
  H.assert_match(notices[#notices], "PAGER%s+@plurnk/plurnk%-execs%s+=cat%s+A pager that waits", "discover renders a candidate with its owning package and default")
  H.assert_match(notices[#notices], "TAVILY_API_KEY%s+@plurnk/plurnk%-schemes%-http%-tavily%s+The Tavily API key%.", "an optional declaration shows no empty value")
  results["worker.env.discover"] = { candidates = {} }
  sent, notices = {}, {}
  ai({ args = "/env discover nothing", range = 0 })
  H.assert_match(notices[#notices], "environment candidates: none", "no candidates says so")

  sent, notices = {}, {}
  ai({ args = "/env add CARGO_TARGET_DIR /tmp/shared", range = 0 })
  ai({ args = '/env add GREETING hello  there "friend"', range = 0 })
  ai({ args = "/env enable CI", range = 0 })
  ai({ args = "/env disable CI", range = 0 })
  ai({ args = "/env remove CARGO_TARGET_DIR", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.env.add", params = { alias = "CARGO_TARGET_DIR", definition = { value = "/tmp/shared" } } }), "add composes one exact { value } definition")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.env.add", params = { alias = "GREETING", definition = { value = 'hello  there "friend"' } } }), "the value reaches the daemon as typed: inner spaces and quotes are the value's own")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.env.enable", params = { alias = "CI" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[4], { method = "worker.env.disable", params = { alias = "CI" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[5], { method = "worker.env.remove", params = { alias = "CARGO_TARGET_DIR" } }), "remove action shape")
  H.assert_match(notices[1], "added: CARGO_TARGET_DIR %(active%)", "add renders the daemon state")
  H.assert_match(notices[3], "enabled: CI %(active%)", "enable renders the daemon state")
  H.assert_match(notices[4], "disabled: CI %(disabled%)", "disable renders the daemon state")
  H.assert_match(notices[5], "removed: CARGO_TARGET_DIR", "remove confirms")

  results["worker.env.add"] = { status = 201, alias = "X", definition = { alias = "X", state = "unavailable", problem = { detail = "never reach a subprocess" } } }
  sent, notices = {}, {}
  ai({ args = "/env add X 1", range = 0 })
  H.assert_match(notices[#notices], "added: X %(unavailable%)%s+— never reach a subprocess", "an unavailable outcome renders its Problem")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/env add",
    "/env add ONLY_A_NAME",
    "/env enable",
    "/env disable a b",
    "/env remove",
    "/env update",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 6, "each malformed command has one usage diagnosis")

  H.assert_eq(table.concat(commands.complete("", "AI /env di", 0), ","), "disable,discover", "env verbs complete")
  results["worker.env.list"] = { definitions = { { alias = "CARGO_TARGET_DIR", state = "active", definition = { value = "/tmp/shared" } }, { alias = "CI", state = "disabled", definition = { value = "1" } } } }
  local aliases = commands.complete("", "AI /env enable C", 0)
  if #aliases == 0 then aliases = commands.complete("", "AI /env enable C", 0) end
  H.assert_eq(table.concat(aliases, ","), "CARGO_TARGET_DIR,CI", "an alias-taking env command lazily completes current names through the worker-scoped list")

  -- Against the live daemon: an added name lists as this Worker's own with its
  -- value, discover names a sibling package's declaration, and disable and
  -- remove follow.
  client.send, client.check_daemon_once = real_send, real_check
  local workspace = "nvim-env-" .. tostring(vim.uv.hrtime())
  local created = H.call("workspace.create", { name = workspace })
  state.set_active_workspace_name(workspace)
  state.set_workspace_id(workspace, created.id)
  local function settle(input, pattern, label)
    notices = {}
    ai({ args = input, range = 0 })
    H.wait_for(function() return #notices > 0 end, 20000, label)
    H.assert_match(notices[#notices], pattern, label)
  end
  settle("/env add CARGO_TARGET_DIR /tmp/plurnk-nvim", "added: CARGO_TARGET_DIR %(active%)", "the live add is active")
  settle("/env", "CARGO_TARGET_DIR%s+active%s+/tmp/plurnk%-nvim", "the live list renders the Worker's own entry with its value")
  settle("/env discover PAGER", "PAGER%s+@plurnk/plurnk%-execs", "the live catalog names the declaring package")
  settle("/env disable CARGO_TARGET_DIR", "disabled: CARGO_TARGET_DIR %(disabled%)", "the live disable renders the daemon state")
  settle("/env remove CARGO_TARGET_DIR", "removed: CARGO_TARGET_DIR", "the live remove confirms")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
