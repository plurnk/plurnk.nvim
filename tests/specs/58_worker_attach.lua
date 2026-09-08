-- nvim#27: attach a tab to a conversation worker by name; the workers picker is
-- the topology (bound tree first, ● on the bound worker); /attach completes over
-- the directory's conversation names.
local NAME = "58_worker_attach"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local directory = {
    { id = 5, name = "plurnk", created_at = "2026-09-04T10:00:00Z", origin = "_plurnk", parentWorkerId = vim.NIL },
    { id = 6, name = "client-1", created_at = "2026-09-04T10:00:00Z", origin = "client", parentWorkerId = vim.NIL },
    { id = 1, name = "sess", created_at = "2026-09-04T10:01:00Z", origin = "model", parentWorkerId = vim.NIL },
    { id = 2, name = "sess-fork", created_at = "2026-09-04T10:02:00Z", origin = "model", parentWorkerId = 1 },
    { id = 4, name = "guesser1", created_at = "2026-09-04T10:03:00Z", origin = "model", parentWorkerId = 1 },
    { id = 3, name = "recheck", created_at = "2026-09-04T10:04:00Z", origin = "model", parentWorkerId = 2 },
    { id = 9, name = "stray", created_at = "2026-09-04T10:05:00Z", origin = "model", parentWorkerId = 404 },
  }

  -- topology: pure projection
  local workers = require("plurnk.workers")
  local rows = workers.topology(workers.conversations(directory), 1)
  local trees = {}
  for _, row in ipairs(rows) do trees[#trees + 1] = row.tree end
  H.assert_eq(table.concat(trees, "|"), "● sess|├─ ○ sess-fork|│  └─ ○ recheck|└─ ○ guesser1|○ stray",
    "bound tree first with connectors; orphan parent stands as a root; scratch workers excluded")
  local deep = workers.topology(workers.conversations(directory), 3)
  H.assert_eq(deep[1].tree, "○ sess", "a bound descendant keeps its root first")
  H.assert_eq(deep[3].tree, "│  └─ ● recheck", "only the bound worker is marked")

  -- plurnk-service#523: the picker line carries the daemon's kind and lifecycle with the
  -- status gauge's glyph; a daemon that states neither yields the bare line.
  local stated = workers.topology({
    { id = 1, name = "sess", created_at = "2026-09-04T10:01:00Z", origin = "model", parentWorkerId = vim.NIL, kind = "conversation", lifecycle = "parked" },
    { id = 2, name = "sess-fork", created_at = "2026-09-04T10:02:00Z", origin = "model", parentWorkerId = 1, kind = "fork", lifecycle = "running" },
    { id = 4, name = "guesser1", created_at = "2026-09-04T10:03:00Z", origin = "model", parentWorkerId = 1, kind = "work", lifecycle = "failed" },
    { id = 8, name = "fresh", created_at = "2026-09-04T10:05:00Z", origin = "model", parentWorkerId = vim.NIL, kind = "conversation", lifecycle = "idle" },
  }, 1)
  H.assert_eq(workers.row_label(stated[1]), "● sess  conversation  💤 parked  2026-09-04T10:01:00Z", "kind and glyphed lifecycle ride the bound row")
  H.assert_eq(workers.row_label(stated[2]), "├─ ○ sess-fork  fork  ⌛︎ running  2026-09-04T10:02:00Z", "a fork child")
  H.assert_eq(workers.row_label(stated[3]), "└─ ○ guesser1  work  ❌ failed  2026-09-04T10:03:00Z", "a failed work child")
  H.assert_eq(workers.row_label(stated[4]), "○ fresh  conversation  · idle  2026-09-04T10:05:00Z", "idle keeps a placeholder glyph")
  H.assert_eq(workers.row_label(rows[1]), "● sess  2026-09-04T10:01:00Z", "no stated kind or lifecycle, no columns")
  H.assert_eq(workers.lifecycle_label("hibernating"), "hibernating", "an unknown word is rendered, never a guessed glyph")

  -- daemon stubs
  local sent, notices = {}, {}
  local client = require("plurnk.client")
  client.send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if method == "workspace.workers" and cb then cb({ workers = directory }) end
    if method == "workspace.attach" and cb then cb({ workerId = params.workerId, workerName = "sess-fork" }) end
  end
  client.notify = function(msg, level) notices[#notices + 1] = { msg = msg, level = level } end
  client.check_daemon_once = function() end
  local rt = require("plurnk.worker_tab")
  rt.open = function() end
  rt.note_worker_resolved = function() end
  local context = require("plurnk.workspace_context")
  context.hydrate_worker = function() end
  context.warn_if_switching_live = function() end
  require("plurnk.generation").hydrate = function() end
  local state = require("plurnk.state")
  state.set_active_workspace_name("s")
  state.set_workspace_id("s", 9)
  state.set_worker_id("s", 1)

  -- attach by a known name → resolve then bind by id
  local cmds = require("plurnk.workspaces")
  cmds.attach("sess-fork")
  local attach
  for _, e in ipairs(sent) do if e.method == "workspace.attach" then attach = e end end
  H.assert_eq(sent[1].method, "workspace.workers", "attach resolves the name against the directory")
  H.assert_truthy(attach ~= nil, "a known name binds")
  H.assert_eq(attach.params.workerId, 2, "attach targets the resolved worker id")
  H.assert_match(notices[#notices].msg, "attached → sess%-fork", "the bind is reported by name")

  -- attach by an unknown name → no bind, one pointer to the plugin's mint
  local before = #sent
  cmds.attach("nope")
  local bound_again = false
  for i = before + 1, #sent do if sent[i].method == "workspace.attach" then bound_again = true end end
  H.assert_truthy(not bound_again, "an unknown name binds nothing")
  H.assert_match(notices[#notices].msg, ":PlurnkFork nope", "the report points at the mint")
  H.assert_eq(notices[#notices].level, vim.log.levels.WARN, "unknown name is a warning")

  -- completion over the remembered directory (conversations only)
  local language = require("plurnk.language")
  H.assert_eq(table.concat(language.complete("", "AI /attach se", 0), ","), "sess,sess-fork",
    "/attach completes conversation names from the cached directory")
  H.assert_eq(#language.complete("", "AI /attach cli", 0), 0, "scratch workers are not attach targets")

  -- the picker renders the topology
  local shown
  vim.ui.select = function(items, opts, on_choice) shown = { items = items, format = opts.format_item }; on_choice(nil) end
  cmds.workers()
  H.assert_truthy(shown ~= nil, "the picker opened")
  -- the earlier attach bound sess-fork: its tree still heads the picker, the mark moves to it
  H.assert_match(shown.format(shown.items[1]), "^○ sess  2026", "the bound conversation's tree heads the picker, rows carry creation time")
  H.assert_match(shown.format(shown.items[2]), "^├─ ● sess%-fork", "the bound conversation is marked where it sits in the tree")
end)
if not ok then H.fail(NAME, err) end
H.finish(NAME)
