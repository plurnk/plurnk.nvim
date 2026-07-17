-- [§nvim-worker-tab]
-- :AI opens a workspace tabpage with TWO windows: waterfall on top, input
-- at the bottom. Submitting from the input populates the waterfall and
-- leaves focus on the input. Drives against the live daemon.
local NAME = "13_worker_tab_layout"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
require("plurnk").apply_default_keymaps()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local terminated = nil
  local orig = dispatch.handle_loop_terminated
  dispatch.handle_loop_terminated = function(p, sn) terminated = p; orig(p, sn) end

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

  -- Type + submit via the <CR> mapping.
  vim.api.nvim_buf_set_lines(rec.input_buf, 0, -1, false, { "? What is the capital of France?" })
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(rec.input_buf, "n")) do
    if m.lhs == "<CR>" and m.callback then m.callback() end
  end

  -- Model latency varies — and the model sometimes explores (search →
  -- FIND → …) before answering, at ~30s/turn on local hardware. Budget
  -- for a wandering loop, not just a direct answer.
  -- 9 minutes: dramatically generous so a failure is unambiguously a real hang,
  -- never "the model was slow" (under the runner's 600s SIGKILL).
  H.wait_for(function() return terminated ~= nil end, 540000, "loop terminated")
  vim.wait(300, function() return false end, 50)

  -- Waterfall renders the loop's rows; input was cleared; focus stayed on input.
  -- Layout spec, not a model-quality spec: the terminal 💡 200 answer assert was
  -- the hard-200 class the operator rejected as flaky for 39_ask_steer (95f711d) —
  -- the model may wander an empty workspace past any budget. Pin what the TAB
  -- promises: the loop concluded (waited above) and its activity rendered.
  local wf = table.concat(vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false), "\n")
  H.assert_match(wf, "plurnk:///prompt/", "waterfall shows the prompt row (the loop ran HERE)")
  H.assert_truthy(type(terminated) == "table", "loop/terminated delivered a payload")
  local input_lines = vim.api.nvim_buf_get_lines(rec.input_buf, 0, -1, false)
  H.assert_eq(table.concat(input_lines, ""), "", "input cleared after submit")
  H.assert_eq(vim.api.nvim_get_current_win(), rec.input_win, "focus stayed on input")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
