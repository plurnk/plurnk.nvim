-- [§nvim-stale-daemon-probe]
-- Pre-launch hardening: :AI/ help screen (no RPC), the in-flight
-- connection-drop warning, and the daemon staleness check.
-- Pure module path; stubs transport/client send + vim.notify.
local NAME = "20_prelaunch"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(sent, { method = method, params = params, cb = cb })
  end
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, lvl) table.insert(notes, { msg = msg, lvl = lvl }) end

  local ai = require("plurnk.commands").ai

  -- ── :AI/ and :AI/help — language screen, zero RPC ──────────────────
  ai({ args = "/", range = 0 })
  ai({ args = "/help", range = 0 })
  H.assert_eq(#sent, 0, ":AI/ help sends nothing")

  -- ── In-flight switch warns; idle switch is silent ──────────────────
  local state = require("plurnk.state")
  state.set_workspace_id("busy", 9)
  state.set_active_workspace_name("busy")
  vim.b.plurnk_workspace = "busy"
  state.set_worker_name("busy", "main-thread")
  state.set_loop_inflight("busy", true)

  notes = {}
  -- switch_worker to a different run forces fresh_connection.
  require("plurnk.commands").switch_worker("busy", 777, function() end)
  local warned = false
  for _, n in ipairs(notes) do
    if n.msg:match("continues on the daemon") and n.msg:match("busy·main%-thread") then warned = true end
  end
  H.assert_truthy(warned, "in-flight switch warns with workspace·run")

  state.set_loop_inflight("busy", false)
  notes = {}
  require("plurnk.commands").switch_worker("busy", 778, function() end)
  for _, n in ipairs(notes) do
    H.assert_truthy(not n.msg:match("continues on the daemon"), "idle switch stays quiet")
  end

  -- ── Staleness check: old daemon → blunt warning, once ──────────────
  -- check_daemon_once routes discover through client.send now (bridge-aware),
  -- not transport.send directly — stub the discover reply there.
  require("plurnk.client").send = function(method, _, _, cb)
    if method == "discover" and cb then
      -- A manifest missing the AG-UI+ markers this client depends on (op.exec/op.look).
      cb({ methods = { ping = {}, ["workspace.list"] = {} }, notifications = {} })
    end
  end
  notes = {}
  require("plurnk.client").check_daemon_once()
  local stale = false
  for _, n in ipairs(notes) do
    if n.msg:match("OLDER") and n.msg:match("op%.exec") then stale = true end
  end
  H.assert_truthy(stale, "old daemon triggers the staleness warning")

  notes = {}
  require("plurnk.client").check_daemon_once()
  H.assert_eq(#notes, 0, "staleness check fires once per instance")

  vim.notify = orig_notify
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
