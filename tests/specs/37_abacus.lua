-- [§nvim-abacus]
-- The abacus: engine:derivation embed_progress collapses to a single edge-toggled
-- 🧮 on the statusline — NOT a per-tick waterfall line — and engine:turn liveness is
-- dropped entirely. Mirrors the TUI (tui.ts onTelemetry). The nvim used to spam every
-- "recounting tokens N/M" tick into the worker tab (operator, 2026-07-10).
local NAME = "37_abacus"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local workspace = "abacus"
  state.set_workspace_id(workspace, 1)

  -- Capture every waterfall append so we can prove progress ticks DON'T land there.
  local appended = {}
  worker_tab.append_line = function(_, line) appended[#appended + 1] = line end

  -- Mid-recount (12/65) → abacus ON, and NOT a single waterfall line.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 12, total = 65, message = "recounting tokens 12/65" } }, workspace)
  H.assert_eq(state.is_embedding(workspace), true, "embed_progress 12/65 toggles the abacus ON")
  H.assert_eq(#appended, 0, "progress ticks NEVER hit the waterfall — the 🧮 replaces the spam")

  -- Another tick while already active — still no line, no churn.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 40, total = 65 } }, workspace)
  H.assert_eq(#appended, 0, "subsequent ticks add no lines")

  -- Recount complete (65/65) → abacus OFF.
  dispatch.handle_telemetry_event({ event = { source = "engine:derivation", kind = "embed_progress", completed = 65, total = 65 } }, workspace)
  H.assert_eq(state.is_embedding(workspace), false, "embed_progress 65/65 toggles the abacus OFF")

  -- engine:turn liveness → dropped (it's the ⏳ gutter, not a line).
  dispatch.handle_telemetry_event({ event = { source = "engine:turn", kind = "turn_generated", message = "parsing model response" } }, workspace)
  H.assert_eq(#appended, 0, "engine:turn liveness is never a waterfall line")

  -- A REAL telemetry event (a parse error) still rides the waterfall.
  dispatch.handle_telemetry_event({ event = { source = "grammar", kind = "parse_error", message = "boom", level = "error" } }, workspace)
  vim.wait(300, function() return #appended > 0 end)
  H.assert_eq(#appended, 1, "non-progress telemetry still renders its line")

  -- The statusline carries 🧮 while embedding, and drops it when done.
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = workspace
  state.set_embedding(workspace, true)
  H.assert_eq(require("plurnk.statusline").text():find("🧮") ~= nil, true, "statusline shows the abacus while embedding")
  state.set_embedding(workspace, false)
  H.assert_eq(require("plurnk.statusline").text():find("🧮") == nil, true, "abacus gone when idle")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
