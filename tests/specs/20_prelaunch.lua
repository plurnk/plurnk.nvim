-- Pre-launch hardening and the deterministic :checkhealth surface.
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

  local ai = require("plurnk.language").run

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
  require("plurnk.workspace_context").switch_worker("busy", 777, function() end)
  local warned = false
  for _, n in ipairs(notes) do
    if n.msg:match("continues on the daemon") and n.msg:match("busy·main%-thread") then warned = true end
  end
  H.assert_truthy(warned, "in-flight switch warns with workspace·run")

  state.set_loop_inflight("busy", false)
  notes = {}
  require("plurnk.workspace_context").switch_worker("busy", 778, function() end)
  for _, n in ipairs(notes) do
    H.assert_truthy(not n.msg:match("continues on the daemon"), "idle switch stays quiet")
  end

  -- ── Compatibility check: authoritative old discovery version → once ─
  require("plurnk.client").send = function(method, _, _, cb)
    if method == "discover" and cb then
      cb({ schemaVersion = 0, actions = {}, notifications = {}, display = {} })
    end
  end
  notes = {}
  require("plurnk.client").check_daemon_once()
  local stale = false
  for _, n in ipairs(notes) do
    if n.msg:match("incompatible") and n.msg:match("schema 0") then stale = true end
  end
  H.assert_truthy(stale, "old discovery schema triggers the compatibility warning")

  notes = {}
  require("plurnk.client").check_daemon_once()
  H.assert_eq(#notes, 0, "staleness check fires once per instance")

  local health = require("plurnk.health")
  local fixtures = {
    provenance = { root = "/tmp/plurnk.nvim", version = "v0.30.0-4-gabc", remote = "https://github.com/plurnk/plurnk.nvim.git" },
    renderer = { available = true, path = "/usr/bin/plurnk" },
    mappings_enabled = false,
  }
  local function matching(records, pattern, level)
    for _, record in ipairs(records) do
      if (level == nil or record.level == level) and record.message:match(pattern) then return record end
    end
    return nil
  end

  -- The real private daemon is reached through worldless discover; no
  -- workspace or model route is needed for a healthy report.
  local healthy = health.collect(fixtures)
  H.assert_truthy(matching(healthy, "Daemon reachable", "ok"), "health reaches the daemon")
  H.assert_truthy(matching(healthy, "schema 1 supplies every client capability", "ok"),
    "health proves the complete AG-UI+ client contract")
  H.assert_truthy(not matching(healthy, ".", "error"), "healthy composition has no health errors")

  local unreachable = health.collect(vim.tbl_extend("force", fixtures, {
    target = { url = "https://secret@example.test/private?token=also-secret", token = "hidden" },
    probe = function() return nil, { detail = "connection refused" } end,
  }))
  H.assert_truthy(matching(unreachable, "Daemon unreachable: connection refused", "error"),
    "unreachable daemon is an error")
  local rendered = vim.inspect(unreachable)
  H.assert_truthy(not rendered:match("secret") and not rendered:match("also%-secret") and not rendered:match("hidden"),
    "health never reports endpoint credentials")
  H.assert_truthy(matching(unreachable, "Endpoint: https://example%.test", "info"),
    "health reports the redacted endpoint")

  local old = health.collect(vim.tbl_extend("force", fixtures, {
    probe = function() return { schemaVersion = 0, actions = {}, notifications = {}, display = {} }, nil end,
  }))
  H.assert_truthy(matching(old, "Incompatible daemon: daemon discovery schema 0", "error"),
    "health distinguishes stale protocol metadata from reachability")

  -- Default mappings fill independent free modes, preserve an occupied key,
  -- and emit one aggregate setup warning. checkhealth names the owner.
  vim.g.mapleader = ","
  vim.keymap.set("n", "<leader>ap", "<Nop>", { desc = "Another plugin" })
  notes = {}
  require("plurnk").apply_default_keymaps()
  H.assert_eq(#notes, 1, "mapping setup emits at most one warning")
  H.assert_match(notes[1].msg, "1 default mapping was skipped", "setup warning is concise and aggregate")
  local inspected = require("plurnk.keymaps").inspect()
  H.assert_truthy(#inspected > 20, "every enabled default mode mapping is inspected")
  local mapping_health = health.collect(vim.tbl_extend("force", fixtures, {
    curl = false,
    mappings_enabled = true,
    mappings = inspected,
  }))
  H.assert_truthy(matching(mapping_health, "n <leader>ap is owned by Another plugin", "warn"),
    "health identifies the conflicting mapping owner")
  vim.keymap.del("n", "<leader>ap")
  notes = {}
  require("plurnk").apply_default_keymaps()
  H.assert_eq(#notes, 0, "healthy default-mapping setup stays quiet")

  vim.cmd("checkhealth plurnk")
  local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  H.assert_match(report, "plurnk.nvim installation", ":checkhealth loads the idiomatic health module")
  H.assert_match(report, "AG%-UI%+ discovery schema 1", ":checkhealth presents protocol compatibility")

  vim.notify = orig_notify
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
