-- [§nvim-telemetry-severity]
-- telemetry/event severity coloring off the producer-set event.level (grammar
-- 0.74.29+ / svc#276): error → ErrorMsg (red), warn → WarningMsg (yellow),
-- info/absent → Comment (dim). Mirrors the npm client (#110) — no kind heuristic.
local NAME = "29_telemetry_severity"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  -- Capture the highlight group safe_echo hands nvim_echo.
  local captured
  vim.api.nvim_echo = function(chunks) captured = chunks and chunks[1] end

  local function hl_for(level)
    captured = nil
    dispatch.handle_telemetry_event({ event = { source = "engine:rail", kind = "strike", level = level, message = "x" } }, nil)
    vim.wait(200, function() return captured ~= nil end)  -- flush the vim.schedule
    return captured and captured[2]
  end

  H.assert_eq(hl_for("error"), "ErrorMsg", "level error → ErrorMsg (red)")
  H.assert_eq(hl_for("warn"), "WarningMsg", "level warn → WarningMsg (yellow)")
  H.assert_eq(hl_for("info"), "Comment", "level info → Comment (dim)")
  H.assert_eq(hl_for(nil), "Comment", "absent level → Comment (neutral fallback, no kind heuristic)")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
