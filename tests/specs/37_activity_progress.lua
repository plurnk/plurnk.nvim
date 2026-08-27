-- -- Derivation progress collapses into the shared edge percentage — NOT a
-- per-tick waterfall line — and engine:turn liveness is
-- dropped entirely. The nvim used to spam every
-- "recounting tokens N/M" tick into the worker tab (operator, 2026-07-10).
local NAME = "37_activity_progress"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local state = require("plurnk.state")
  local worker_tab = require("plurnk.worker_tab")
  local runtime_status = require("plurnk.runtime_status")
  local workspace = "activity"
  state.set_workspace_id(workspace, 1)
  local _, gauge = runtime_status.reduce(nil, {
    type = "STATE_SNAPSHOT",
    snapshot = {
      plurnk = { status = {
        lifecycle = "idle",
        model = vim.NIL,
        loopId = vim.NIL,
        packetCount = 0,
        activity = vim.NIL,
      } },
      budget = {},
    },
  })
  local function apply_delta(value)
    local handled, next_gauge = runtime_status.reduce(gauge, {
      type = "STATE_DELTA",
      delta = { { op = "replace", path = "/plurnk/status/activity", value = value } },
    })
    H.assert_eq(handled, true, "runtime activity delta is handled")
    gauge = next_gauge
    dispatch.handle_loop_packet({ gauge = gauge }, workspace)
  end
  dispatch.handle_loop_packet({ gauge = gauge }, workspace)

  -- Capture every waterfall append so we can prove progress ticks DON'T land there.
  local appended = {}
  worker_tab.append_line = function(_, line) appended[#appended + 1] = line end

  -- Mid-recount (12/65) → progress active, and NOT a single waterfall line.
  apply_delta({ kind = "derivation", phase = "indexing", completed = 12, total = 65, percent = 18, message = "recounting tokens 12/65" })
  dispatch.handle_notice_event({ notice = { source = "engine:derivation", kind = "embed_progress", level = "info", completed = 12, total = 65, percent = 18, message = "recounting tokens 12/65" } }, workspace)
  H.assert_eq(state.get_runtime_status(workspace).activity.percent, 18, "AG-UI state owns derivation percentage")
  H.assert_eq(#appended, 0, "progress ticks never hit the waterfall")

  -- Another tick while already active — still no line, no churn.
  apply_delta({ kind = "derivation", phase = "indexing", completed = 40, total = 65, percent = 61, message = "recounting tokens 40/65" })
  dispatch.handle_notice_event({ notice = { source = "engine:derivation", kind = "embed_progress", level = "info", completed = 40, total = 65, percent = 61 } }, workspace)
  H.assert_eq(#appended, 0, "subsequent ticks add no lines")

  -- Recount complete (65/65) → compact progress off.
  apply_delta(vim.NIL)
  dispatch.handle_notice_event({ notice = { source = "engine:derivation", kind = "embed_progress", level = "info", phase = "complete", completed = 65, total = 65, percent = 100 } }, workspace)
  H.assert_eq(state.get_runtime_status(workspace).activity, nil, "terminal AG-UI state clears compact progress")

  -- engine:turn liveness → dropped (it's the activity slot, not a line).
  dispatch.handle_notice_event({ notice = { source = "engine:turn", kind = "turn_generated", level = "info", message = "parsing model response" } }, workspace)
  H.assert_eq(#appended, 0, "engine:turn liveness is never a waterfall line")

  -- A non-progress Notice still rides the waterfall.
  dispatch.handle_notice_event({ notice = { source = "grammar", kind = "parse_advisory", message = "boom", level = "warn" } }, workspace)
  vim.wait(300, function() return #appended > 0 end)
  H.assert_eq(#appended, 1, "a non-progress Notice still renders its line")
  H.assert_match(appended[1], "^📡", "Notice glyph begins at the shared left edge")

  -- Unknown progress falls back to the shared activity hourglass.
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].plurnk_workspace = workspace
  apply_delta({ kind = "derivation", phase = "indexing", completed = 0, total = 0, percent = vim.NIL, message = "indexing" })
  H.assert_eq(require("plurnk.statusline").text(), "indexing", "unknown active progress keeps its authoritative activity label")
  apply_delta(vim.NIL)
  H.assert_eq(require("plurnk.statusline").text(), "", "activity slot clears when idle")

  -- Search acquisition uses the same no-waterfall compact-state contract.
  dispatch.handle_notice_event({ notice = { source = "exec:search", kind = "search_progress", level = "info", phase = "fetching", percent = 42, completed = 5, total = 12 } }, workspace)
  H.assert_eq(state.get_search_progress(workspace), 42, "search progress stores the producer's aggregate percent")
  H.assert_eq(#appended, 1, "search progress adds no waterfall lines")
  H.assert_eq(require("plurnk.statusline").text(), "42%", "search uses the shared compact percentage")
  dispatch.handle_notice_event({ notice = { source = "exec:search", kind = "search_progress", level = "info", phase = "complete", percent = 100 } }, workspace)
  H.assert_eq(state.get_search_progress(workspace), nil, "terminal search progress clears the edge state")
  H.assert_eq(require("plurnk.statusline").text(), "", "search gauge gone when complete")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
