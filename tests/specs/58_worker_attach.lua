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
  H.assert_eq(table.concat(trees, "|"), "● sess|├─ ○ guesser1|└─ ○ sess-fork|   └─ ○ recheck|○ stray",
    "bound tree first with connectors, siblings newest first; orphan parent stands as a root; scratch workers excluded")
  local deep = workers.topology(workers.conversations(directory), 3)
  H.assert_eq(deep[1].tree, "○ sess", "a bound descendant keeps its root first")
  H.assert_eq(deep[4].tree, "   └─ ● recheck", "only the bound worker is marked")

  -- {§nvim-worker-hops}: pure hops over the directory, the path, and the sibling position
  local hop = function(bound, direction) local target, reason = workers.hop(directory, bound, direction); return target and target.name or ("(" .. reason .. ")") end
  H.assert_eq(hop(1, "enter"), "guesser1", "l enters the newest child")
  H.assert_eq(hop(4, "parent"), "sess", "h climbs")
  H.assert_eq(hop(4, "next"), "sess-fork", "j walks to the older sibling")
  H.assert_eq(hop(2, "next"), "guesser1", "and wraps")
  H.assert_eq(hop(4, "prev"), "sess-fork", "k wraps the other way")
  H.assert_eq(hop(2, "enter"), "recheck", "enter descends one level")
  H.assert_eq(hop(3, "enter"), "(no children)", "an edge names why")
  H.assert_eq(hop(3, "next"), "(no siblings)", "an only child has no siblings")
  H.assert_eq(hop(1, "parent"), "(at the root: no parent)", "the root has no parent")
  H.assert_eq(hop(1, "next"), "stray", "root conversations are siblings; scratch workers are not places")
  H.assert_eq(hop(99, "enter"), "(no bound worker yet)", "nothing bound, nowhere to hop")
  H.assert_eq(workers.path(directory, 1), "/~sess", "a root is still named; ~ marks where the tab is")
  H.assert_eq(workers.path(directory, 3), "/sess/sess-fork/~recheck", "a child always shows that it is a child")
  H.assert_eq(workers.path(directory, 99), "/~", "unknown: here, unnamed")
  local position = workers.position(directory, 2)
  H.assert_eq(position.index .. "/" .. position.count, "2/2", "sibling position, newest first")
  H.assert_truthy(workers.position(directory, 3) == nil, "an only child has no position")

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
  H.assert_match(shown.format(shown.items[3]), "^└─ ● sess%-fork", "the bound conversation is marked where it sits in the tree, newest sibling first")

  -- a hop is a full attach through the same path: the daemon names the target, the tab rebinds,
  -- and the report carries the path and sibling position
  local before_hop = #sent
  cmds.hop("parent")
  local hopped
  for i = before_hop + 1, #sent do if sent[i].method == "workspace.attach" then hopped = sent[i] end end
  H.assert_truthy(hopped ~= nil, "a hop attaches")
  H.assert_eq(hopped.params.workerId, 1, "h from sess-fork lands on sess")
  H.assert_eq(workers.position_label("s"), "[/~sess] (2/2)", "the winbar's position: the root named with ~, the older of two root conversations (stray is newer)")
  cmds.hop("parent")
  H.assert_match(notices[#notices].msg, "^%(at the root: no parent%)$", "an edge reports why nothing moved")
  H.assert_match(require("plurnk.worker_tab").winbar_text("s", 1), "%[/~sess%] %(2/2%) ", "the winbar leads with where the tab is in the tree")
end)
if not ok then H.fail(NAME, err) end
H.finish(NAME)
