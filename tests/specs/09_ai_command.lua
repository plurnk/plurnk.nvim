-- [§nvim-prompt-prefixes][§nvim-stop][§nvim-workspace-settings]
-- :AI command — prefix-stripping, /stop, ??-new-workspace.
-- Pure module path; stubs client.send so no daemon round-trip.
local NAME = "09_ai_command"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local captured = {}
  -- AG-UI+: loop runs ride bridge.run (not client.send). Capture them shaped like
  -- the old records so the routing assertions stay meaningful.
  require("plurnk.bridge").run = function(_thread, prompt, opts, on_done)
    local fwd = (opts and opts.forwardedProps) or {}
    table.insert(captured, { method = "loop.run", params = vim.tbl_extend("force", { prompt = prompt }, fwd) })
    if on_done then on_done(200) end
    return nil
  end
  require("plurnk.client").send = function(method, params, _, cb)
    table.insert(captured, { method = method, params = params })
    -- For workspace.create called by `??`, fire the callback (returning the
    -- run identity directly, §13.5-workspace-create) so the second send
    -- (loop.run) actually happens.
    if method == "workspace.create" and cb then
      cb({ id = 99, name = "ai-test-workspace", workerId = 7, workerName = "auto-run" })
    end
  end
  local function find(list, method)
    for _, m in ipairs(list) do if m.method == method then return m end end
    return nil
  end

  -- Bind a workspace so prompt() can resolve.
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = "smoke"
  require("plurnk.state").set_workspace_id("smoke", 1)

  local ai = require("plurnk.commands").ai

  -- :AI: Hello, world.
  ai({ args = ": Hello, world.", range = 0 })
  H.assert_eq(captured[#captured].method, "loop.run", ":AI: routes to loop.run")
  H.assert_eq(captured[#captured].params.prompt, "Hello, world.", ":AI: strips colon")

  -- :AI? plain
  captured = {}
  ai({ args = "? what is france", range = 0 })
  H.assert_eq(captured[1].params.prompt, "what is france", ":AI? strips ?")

  -- :AI! cmd → op.exec (daemon-owned Run mode, #16 phase 2)
  captured = {}
  ai({ args = "! git status", range = 0 })
  H.assert_eq(captured[1].method, "op.exec", ":AI! routes to op.exec")
  H.assert_eq(captured[1].params.command, "git status", ":AI! carries the command")

  -- :AI!cmd via bang (the unabbreviated parse: bang=true, args="cmd")
  captured = {}
  ai({ args = "git diff", bang = true, range = 0 })
  H.assert_eq(captured[1].method, "op.exec", ":AI! bang form routes to op.exec")
  H.assert_eq(captured[1].params.command, "git diff", ":AI! bang form carries the command")

  -- :AI no prefix
  captured = {}
  ai({ args = "plain", range = 0 })
  H.assert_eq(captured[1].params.prompt, "plain", ":AI plain text")

  -- :AI with @file refs → loop.run.openPaths (daemon foists turn-0 READs, #260)
  captured = {}
  ai({ args = ": summarize @src/a.ts and @docs/b.md", range = 0 })
  H.assert_eq(captured[1].method, "loop.run", "@file: routes to loop.run")
  H.assert_truthy(captured[1].params.openPaths, "@file: openPaths present")
  H.assert_eq(captured[1].params.openPaths[1], "src/a.ts", "@file: first ref")
  H.assert_eq(captured[1].params.openPaths[2], "docs/b.md", "@file: second ref")

  -- :AI?? on a workspace-attached buffer: drops the bound connection and
  -- creates a NEW workspace by rebinding the connection in place
  -- (§13.5-rebind, v0.17.0 — no reconnect).
  local stops = 0
  captured = {}
  require("plurnk.config").setup({ files_items = 5 })
  ai({ args = "?? new chat", range = 0 })
  H.assert_eq(stops, 0, ":AI?? rebinds in place, never drops the socket")
  H.assert_eq(captured[1].method, "workspace.create", ":AI?? creates a new workspace")
  H.assert_eq(captured[1].params.settings.client, "plurnk.nvim", ":AI?? workspace.create carries the client id (#249)")
  H.assert_eq(captured[1].params.settings.filesItems, 5, "filesItems rides workspace.create when configured (svc#231, CLI convergence)")
  local lr = find(captured, "loop.run")
  H.assert_truthy(lr, ":AI?? then loop.run")
  H.assert_eq(lr.params.prompt, "new chat", ":AI?? carries prompt")

  -- :AI?? on a fresh buffer with no workspace: workspace.create then loop.run.
  -- Move to a fresh empty buffer so no plurnk_workspace is bound here.
  vim.cmd("enew")
  require("plurnk.state").set_active_workspace_name(nil)
  captured = {}
  ai({ args = "?? fresh chat", range = 0 })
  H.assert_eq(captured[1].method, "workspace.create", ":AI?? creates workspace when none attached")
  local lr2 = find(captured, "loop.run")
  H.assert_truthy(lr2, ":AI?? then loop.run")
  H.assert_eq(lr2.params.prompt, "fresh chat", ":AI?? carries prompt after workspace.create")

  -- :AI/stop with an active workspace — cancels the run's loop over the
  -- wire (loop.cancel landed in plurnk-service 0.8.0).
  captured = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(captured[1].method, "loop.cancel", ":AI/stop sends loop.cancel")

  -- :AI/stop with NO workspace — proposal cleanup only, no RPC.
  vim.cmd("enew")
  require("plurnk.state").set_active_workspace_name(nil)
  vim.b.plurnk_workspace = nil
  captured = {}
  ai({ args = "/stop", range = 0 })
  H.assert_eq(#captured, 0, ":AI/stop without workspace sends nothing")

  -- #268 — config.auto_read_agents flows to workspace.create as settings.autoReadAgents.
  require("plurnk.config").setup({ auto_read_agents = false })
  vim.cmd("enew")
  require("plurnk.state").set_active_workspace_name(nil)
  vim.b.plurnk_workspace = nil
  captured = {}
  ai({ args = "?? off-agents", range = 0 })
  local sc = find(captured, "workspace.create")
  H.assert_eq(sc.params.settings.autoReadAgents, false, "auto_read_agents=false → settings.autoReadAgents")
  H.assert_eq(sc.params.settings.client, "plurnk.nvim", "client id still present alongside the override")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
