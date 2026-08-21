-- -- :AI opens a workspace tabpage with TWO windows: waterfall on top, input
-- at the bottom. Submitting from the input reaches the bridge, clears the input,
-- and leaves focus there. Workspace binding is real; inference is irrelevant.
local NAME = "13_worker_tab_layout"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  vim.cmd("AI")

  -- Wait for workspace.create round-trip + worker_tab.open.
  local rec, active
  H.wait_for(function()
    active = require("plurnk.state").get_active_workspace_name()
    if active then rec = require("plurnk.worker_tab").get_record(active) end
    return rec ~= nil
  end, 8000, "worker_tab record")

  H.assert_truthy(rec, "tab record exists")
  H.assert_eq(#vim.api.nvim_tabpage_list_wins(rec.tabpage), 2, "tab has 2 windows")
  H.assert_truthy(vim.api.nvim_win_is_valid(rec.waterfall_win), "waterfall_win valid")
  H.assert_truthy(vim.api.nvim_win_is_valid(rec.input_win), "input_win valid")
  H.assert_eq(vim.api.nvim_get_current_win(), rec.input_win, "focus is on input")

  local submitted
  local bridge = require("plurnk.bridge")
  local original_run = bridge.run
  bridge.run = function(workspace, prompt, opts, on_done)
    submitted = { workspace = workspace, prompt = prompt, opts = opts }
    if on_done then on_done(200) end
    return nil
  end

  -- Type + submit via the <CR> mapping.
  vim.api.nvim_buf_set_lines(rec.input_buf, 0, -1, false, { "? What is the capital of France?" })
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(rec.input_buf, "n")) do
    if m.lhs == "<CR>" and m.callback then m.callback() end
  end

  H.wait_for(function() return submitted ~= nil end, 8000, "bridge submission")
  bridge.run = original_run

  H.assert_eq(submitted.workspace, active, "input submits through the bound workspace")
  H.assert_match(submitted.prompt, "What is the capital of France", "input reaches the bridge unchanged")
  local input_lines = vim.api.nvim_buf_get_lines(rec.input_buf, 0, -1, false)
  H.assert_eq(table.concat(input_lines, ""), "", "input cleared after submit")
  H.assert_eq(vim.api.nvim_get_current_win(), rec.input_win, "focus stayed on input")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
