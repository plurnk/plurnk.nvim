-- {§nvim-active-worker}: the tab you are in is the active worker. Entering a worker tab makes its
-- worker the workspace's active worker — the one every plurnk command speaks to, from inside the
-- tab or from any other buffer — until another worker tab is entered. A code buffer's statusline
-- names that destination; inside a worker tab the winbar's lineage already does.
local NAME = "59_active_worker"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local statusline = require("plurnk.statusline")
  worker_tab.setup()
  state.set_workspace_id("ws", 7)
  state.set_active_workspace_name("ws")
  state.set_worker_label("ws", 1, "main")
  state.set_worker_label("ws", 2, "recheck")
  state.set_worker_directory("ws", {
    { id = 1, name = "main", created_at = "2026-09-08T00:01:00Z", origin = "model", parentWorkerId = vim.NIL },
    { id = 2, name = "recheck", created_at = "2026-09-08T00:02:00Z", origin = "model", parentWorkerId = 1 },
  })

  -- two worker tabs on one workspace
  state.set_worker_id("ws", 1)
  worker_tab.open("ws", 1)
  local main_tab = vim.api.nvim_get_current_tabpage()
  state.set_worker_id("ws", 2)
  worker_tab.open("ws", 2)
  local recheck_tab = vim.api.nvim_get_current_tabpage()
  H.assert_truthy(main_tab ~= recheck_tab, "each worker has its own tab")
  H.assert_eq(state.get_worker_id("ws"), 2, "the tab just opened is the active worker")
  H.assert_match(worker_tab.winbar_text("ws", 2), "%[/main/~recheck%]", "the child's tab shows its lineage")

  -- entering the other tab activates its worker; nothing else is touched
  vim.api.nvim_set_current_tabpage(main_tab)
  vim.wait(200, function() return state.get_worker_id("ws") == 1 end, 10)
  H.assert_eq(state.get_worker_id("ws"), 1, "entering a worker tab makes its worker active")
  H.assert_match(worker_tab.winbar_text("ws", 1), "%[/~main%]", "the root's tab shows it is the root")
  H.assert_truthy(not statusline.text():match("~main"), "inside a worker tab the statusline does not repeat the winbar's identity")

  vim.api.nvim_set_current_tabpage(recheck_tab)
  vim.wait(200, function() return state.get_worker_id("ws") == 2 end, 10)
  H.assert_eq(state.get_worker_id("ws"), 2, "and back")

  -- a code buffer elsewhere: commands go to the last worker tab entered, and the statusline says so
  vim.cmd("tabnew")
  local code = vim.api.nvim_get_current_buf()
  H.assert_truthy(worker_tab.binding_for_tabpage(vim.api.nvim_get_current_tabpage()) == nil, "a plain tab is bound to no worker")
  H.assert_eq(state.get_worker_id("ws"), 2, "leaving for a code buffer keeps the last worker tab's worker active")
  H.assert_eq(statusline.text(), "~recheck", "a code buffer's statusline names the destination worker")
  vim.b[code].plurnk_workspace = "ws"
  H.assert_eq(require("plurnk.workspace_context").active(), "ws", "the code buffer's commands address the active workspace")
  H.assert_eq(statusline.text(), "~recheck", "an associated code buffer names the same destination")
end)
if not ok then H.fail(NAME, err) end
H.finish(NAME)
