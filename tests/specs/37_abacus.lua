-- The abacus: engine:derivation embed_progress collapses to a single edge-toggled
-- 🧮 on the statusline — NOT a per-tick waterfall line — and engine:turn liveness is
-- dropped entirely. Mirrors the TUI (tui.ts onTelemetry). The nvim used to spam every
-- "recounting tokens N/M" tick into the run tab (operator, 2026-07-10).
local NAME = "37_abacus"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local run_tab = require("plurnk.run_tab")
  local session = "abacus"
  state.set_session_id(session, 1)

  -- Capture every waterfall append so we can prove progress ticks DON'T land there.
  local appended = {}
  run_tab.append_line = function(_, line) appended[#appended + 1] = line end

  -- Mid-recount (12/65) → abacus ON, and NOT a single waterfall line.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 12, total = 65, message = "recounting tokens 12/65" } }, session)
  H.assert_eq(state.is_embedding(session), true, "embed_progress 12/65 toggles the abacus ON")
  H.assert_eq(#appended, 0, "progress ticks NEVER hit the waterfall — the 🧮 replaces the spam")

  -- Another tick while already active — still no line, no churn.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 40, total = 65 } }, session)
  H.assert_eq(#appended, 0, "subsequent ticks add no lines")

  -- Recount complete (65/65) → abacus OFF.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 65, total = 65 } }, session)
  H.assert_eq(state.is_embedding(session), false, "embed_progress 65/65 toggles the abacus OFF")

  -- engine:turn liveness → dropped (it's the ⏳ gutter, not a line).
  dispatch.handle_telemetry_event({ event = { source = "engine:turn", kind = "turn_generated", message = "parsing model response" } }, session)
  H.assert_eq(#appended, 0, "engine:turn liveness is never a waterfall line")

  -- A REAL telemetry event (a parse error) still rides the waterfall.
  dispatch.handle_telemetry_event({ event = { source = "grammar", kind = "parse_error", message = "boom", level = "error" } }, session)
  vim.wait(300, function() return #appended > 0 end)
  H.assert_eq(#appended, 1, "non-progress telemetry still renders its line")

  -- The statusline carries 🧮 while embedding, and drops it when done.
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_session = session
  state.set_embedding(session, true)
  H.assert_eq(require("plurnk.statusline").text():find("🧮") ~= nil, true, "statusline shows the abacus while embedding")
  state.set_embedding(session, false)
  H.assert_eq(require("plurnk.statusline").text():find("🧮") == nil, true, "abacus gone when idle")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
