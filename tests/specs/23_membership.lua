-- [§nvim-membership-verbs]
-- Membership overlay commands (svc#200), converged with the TUI's
-- /pick /hide /view /drop /members. Service vocabulary; live via
-- workspace.constrain / unconstrain / constraints. Pure module path; no daemon.
local NAME = "23_membership"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(sent, { method = method, params = params })
    if method == "workspace.constraints" and cb then
      cb({ constraints = { { effect = "hide", glob = "*.lock" }, { effect = "pick", glob = "docs/**" } } })
    end
    if method == "workspace.members" and cb then
      cb({
        members = { { path = "/src/a.lua", effect = "member" }, { path = "/vendor/x.lua", effect = "view" } },
        hidden = { "/secret.env" },
      })
    end
  end
  require("plurnk.client").check_daemon_once = function() end
  -- An active workspace → resolve_workspace_then short-circuits straight to the send.
  require("plurnk.state").set_active_workspace_name("memb")

  local cmds = require("plurnk.commands")
  local function last(method)
    for i = #sent, 1, -1 do if sent[i].method == method then return sent[i] end end
    return nil
  end

  -- /pick /hide /view → workspace.constrain with the SERVICE vocabulary
  cmds.pick({ args = "src/**" })
  H.assert_eq(last("workspace.constrain").params.effect, "pick", "/pick → effect=pick")
  H.assert_eq(last("workspace.constrain").params.glob, "src/**", "/pick carries the glob")
  cmds.hide({ args = "*.lock" })
  H.assert_eq(last("workspace.constrain").params.effect, "hide", "/hide → effect=hide")
  cmds.view({ args = "vendor/**" })
  H.assert_eq(last("workspace.constrain").params.effect, "view", "/view → effect=view")

  -- /repo (svc#242) → workspace.constrain with effect=repo, explicit dir glob
  cmds.repo({ args = "packages/api" })
  H.assert_eq(last("workspace.constrain").params.effect, "repo", "/repo → effect=repo")
  H.assert_eq(last("workspace.constrain").params.glob, "packages/api", "/repo carries the dir glob")

  -- /repo with no arg in a file buffer → the file's DIRECTORY, not the file
  -- (repo is a folder declaration; the current-file default would be wrong)
  sent = {}
  vim.api.nvim_buf_set_name(0, "packages/api/server.lua")
  cmds.repo({ args = "" })
  local r = last("workspace.constrain")
  H.assert_truthy(r ~= nil and r.params.glob == "packages/api", "no-arg repo uses the current file's directory")
  H.assert_truthy(r ~= nil and not r.params.glob:match("server%.lua"), "no-arg repo excludes the file itself")

  -- no arg + a real file buffer → picks the CURRENT file (the one-keystroke
  -- vim move). The glob is the buffer's workspace-relative path.
  sent = {}
  vim.api.nvim_buf_set_name(0, "src/widget.lua")
  cmds.pick({ args = "" })
  local cur = last("workspace.constrain")
  H.assert_truthy(cur ~= nil and cur.params.glob:match("widget%.lua"), "no-arg pick uses the current file")
  H.assert_eq(cur.params.effect, "pick", "current-file pick → effect=pick")

  -- no arg in a non-file (scheme://) buffer → nothing sent
  sent = {}
  vim.api.nvim_buf_set_name(0, "plurnk-nvim://workspace/x")
  cmds.pick({ args = "" })
  H.assert_eq(#sent, 0, "no-arg in a non-file buffer sends nothing")

  -- /drop → list, then unconstrain the matching glob (any effect)
  sent = {}
  cmds.drop({ args = "*.lock" })
  H.assert_eq(sent[1].method, "workspace.constraints", "/drop lists constraints first")
  local un = last("workspace.unconstrain")
  H.assert_truthy(un and un.params.effect == "hide" and un.params.glob == "*.lock",
    "/drop unconstrains the matching hide *.lock")

  -- /drop with no match → no unconstrain
  sent = {}
  cmds.drop({ args = "nomatch/**" })
  H.assert_truthy(last("workspace.unconstrain") == nil, "/drop with no match unconstrains nothing")

  -- /members → reports the RESOLVED universe (workspace.members), NOT the rule
  -- globs. The first RPC must be workspace.members; the rules ride as a footer.
  sent = {}
  local notified = {}
  local real_notify = require("plurnk.client").notify
  require("plurnk.client").notify = function(msg) notified[#notified + 1] = msg end
  cmds.members()
  require("plurnk.client").notify = real_notify
  H.assert_eq(sent[1].method, "workspace.members", "/members asks the daemon for the resolved universe first")
  local out = table.concat(notified, "\n")
  H.assert_match(out, "the model's universe: 2 files \u{2014} 1 editable, 1 read%-only, 1 hidden",
    "/members states the true resolved counts")
  H.assert_match(out, "view%s+/vendor/x%.lua", "/members shows the read-only member by resolved path")
  H.assert_match(out, "member%s+/src/a%.lua", "/members shows the editable member by resolved path")
  H.assert_match(out, "hidden%s+/secret%.env", "/members surfaces the hidden (excluded) file honestly")
  H.assert_match(out, "rules: hide %*%.lock", "/members shows the rule footer (what /drop targets), distinct from the universe")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
