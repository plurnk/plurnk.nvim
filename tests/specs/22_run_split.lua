-- Run-split routing (#214): only the model run (the conversation) is shown
-- in the waterfall. The conversation run is adopted from events arriving
-- while a loop is in flight (those are the model run); client-run
-- housekeeping (op.exec, arriving when no loop is in flight) is never
-- adopted and never rendered. Pure module path; no daemon.
local NAME = "22_run_split"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local function entry(run_id, path)
  return { entry = {
    id = math.random(1, 1e6), run_id = run_id, loop_id = 1, turn_id = 1,
    loop_seq = 1, turn_seq = 1, sequence = 1,
    op = "READ", origin = "model", status_rx = 200, scheme = "known",
    pathname = path or "/x", tx = {}, rx = {},
  }, sessionId = 3 }
end

local function waterfall_text(session)
  local rec = require("plurnk.run_tab").get_record(session)
  if not rec or not rec.waterfall_buf then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false), "\n")
end

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local dispatch = require("plurnk.dispatch")
  state.set_session_id("conv", 3)
  state.set_active_session_name("conv")
  vim.b.plurnk_session = "conv"
  require("plurnk.run_tab").open("conv")  -- pending tab, no run yet

  -- A client-run op.exec entry arriving while NO loop is in flight must be
  -- ignored (housekeeping) — it must not become the conversation run.
  state.set_loop_inflight("conv", false)
  dispatch.handle_log_entry(entry(99, "/client-exec"), "conv")
  vim.wait(50, function() return false end, 10)
  H.assert_eq(state.get_run_id("conv"), nil, "client-run housekeeping is not adopted")
  H.assert_truthy(not waterfall_text("conv"):match("client%-exec"), "housekeeping not rendered")

  -- Now we drive a loop: events that arrive are the model run. The first
  -- adopts the conversation run authoritatively (its run_id).
  state.set_loop_inflight("conv", true)
  dispatch.handle_log_entry(entry(42, "/model-says-hi"), "conv")
  vim.wait(500, function() return waterfall_text("conv"):match("model%-says%-hi") ~= nil end, 10)
  H.assert_eq(state.get_run_id("conv"), 42, "first in-flight event adopts the model run")
  H.assert_match(waterfall_text("conv"), "model%-says%-hi", "conversation rendered")

  -- A later wake-loop event (same model run, even if not in flight) routes.
  state.set_loop_inflight("conv", false)
  dispatch.handle_log_entry(entry(42, "/wake-reaction"), "conv")
  vim.wait(500, function() return waterfall_text("conv"):match("wake%-reaction") ~= nil end, 10)
  H.assert_match(waterfall_text("conv"), "wake%-reaction", "model-run wake event still routes")

  -- A stray client-run entry (run 99) never enters the conversation.
  dispatch.handle_log_entry(entry(99, "/more-housekeeping"), "conv")
  vim.wait(50, function() return false end, 10)
  H.assert_truthy(not waterfall_text("conv"):match("more%-housekeeping"),
    "client run stays out of the conversation once the model run is known")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
