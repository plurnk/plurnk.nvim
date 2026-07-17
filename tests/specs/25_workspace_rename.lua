-- [§nvim-workspace-rename]
-- workspace.rename (svc#248): a workspace's name is a mutable handle on the world
-- (a worker's is immutable). Rekeys local state + the worker tab in place.
local NAME = "25_workspace_rename"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.client").send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if method == "workspace.rename" and cb then cb({ id = 9, name = params.name }) end
  end
  require("plurnk.client").check_daemon_once = function() end
  require("plurnk.client").consume_selected_alias = function() return nil end
  require("plurnk.client").get_workspace_model = function() return nil end

  local state = require("plurnk.state")
  state.set_active_workspace_name("old")
  state.set_workspace_id("old", 9)

  local cmds = require("plurnk.commands")

  -- /rename → workspace.rename with the new name; local state adopts it.
  cmds.workspace_rename({ args = "fresh" })
  local r
  for i = #sent, 1, -1 do if sent[i].method == "workspace.rename" then r = sent[i]; break end end
  H.assert_truthy(r ~= nil, "workspace.rename was sent")
  H.assert_eq(r.params.name, "fresh", "carries the new name")
  H.assert_eq(state.get_active_workspace_name(), "fresh", "active workspace adopts the new name")
  H.assert_eq(state.get_workspace_id("fresh"), 9, "workspace id follows the rename")

  -- empty name → no rpc
  sent = {}
  cmds.workspace_rename({ args = "" })
  H.assert_eq(#sent, 0, "empty name sends nothing")

  -- The open tab's buffers follow the rename. The input buffer's URI carries
  -- the workspace, and the tab/statusline `%f` reads that name — so it must stop
  -- showing plurnk://input/<old>/… after a rename (operator bug, 2026-06-20).
  local worker_tab = require("plurnk.worker_tab")
  worker_tab.reset()
  worker_tab.open("renameme")
  local rec = worker_tab.get_record("renameme")
  H.assert_truthy(rec and rec.input_buf, "open created an input buffer")
  H.assert_match(vim.api.nvim_buf_get_name(rec.input_buf), "plurnk://input/renameme/", "input URI carries the workspace")
  worker_tab.rename("renameme", "renamed")
  local nm = vim.api.nvim_buf_get_name(rec.input_buf)
  H.assert_match(nm, "plurnk://input/renamed/", "input URI follows the rename")
  H.assert_truthy(not nm:match("/renameme/"), "no stale old-workspace URI in the input buffer name")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
