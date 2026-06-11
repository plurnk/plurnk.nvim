-- Phase 3 cockpit: statusline token accumulation (session-total, from
-- log/entry rows) and the HUD headless fallback. Pure module path.
local NAME = "21_cockpit"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  state.set_session_id("gauge", 3)
  state.set_active_session_name("gauge")
  vim.b.plurnk_session = "gauge"

  local entry = function(id, tokens)
    return { entry = { id = id, run_id = 1, loop_id = 1, turn_id = 1, tokens = tokens,
      op = "READ", origin = "model", status_rx = 200, scheme = "known", pathname = "/x",
      tx = {}, rx = {} }, sessionId = 3 }
  end
  dispatch.handle_log_entry(entry(1, 700), "gauge")
  dispatch.handle_log_entry(entry(2, 800), "gauge")
  H.assert_eq(state.get_tokens("gauge"), 1500, "tokens accumulate per session")

  local line = require("plurnk.statusline").text()
  H.assert_match(line, "1%.5k tok", "statusline shows the k-formatted gauge")
  H.assert_match(line, "plurnk%[gauge", "statusline names the session")

  -- Zero-token session shows NO gauge (no fake zeros).
  vim.cmd("enew")
  vim.b.plurnk_session = "empty"
  state.set_session_id("empty", 4)
  H.assert_truthy(not require("plurnk.statusline").text():match("tok"),
    "no token segment without data")

  -- HUD: headless (no UI) falls back to vim.notify — message still lands.
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg) table.insert(notes, msg) end
  require("plurnk.hud").show("✓ exec://demo → 200")
  vim.notify = orig
  H.assert_eq(notes[1], "✓ exec://demo → 200", "headless HUD falls back to notify")
  H.assert_truthy(not require("plurnk.hud").is_open(), "no float without a UI")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
