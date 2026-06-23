-- telemetry/event severity coloring: error kinds → ErrorMsg (red), warnings
-- → WarningMsg (yellow), neutral → Comment (dim). Mirrors the npm client.
local NAME = "29_telemetry_severity"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  -- Capture the highlight group safe_echo hands nvim_echo.
  local captured
  vim.api.nvim_echo = function(chunks) captured = chunks and chunks[1] end

  local function hl_for(source, kind)
    captured = nil
    dispatch.handle_telemetry_event({ event = { source = source, kind = kind, message = "x" } }, nil)
    vim.wait(200, function() return captured ~= nil end)  -- flush the vim.schedule
    return captured and captured[2]
  end

  H.assert_eq(hl_for("client:connection", "refused"), "ErrorMsg", "refused → ErrorMsg (red)")
  H.assert_eq(hl_for("grammar", "parse_error"), "ErrorMsg", "parse_error → ErrorMsg (red)")
  H.assert_eq(hl_for("engine:rail", "action_failure"), "ErrorMsg", "action_failure → ErrorMsg")
  H.assert_eq(hl_for("client:connection", "daemon_stale"), "WarningMsg", "stale → WarningMsg (yellow)")
  H.assert_eq(hl_for("client:proposal", "edits_blocked"), "WarningMsg", "blocked → WarningMsg")
  H.assert_eq(hl_for("engine", "graceful"), "Comment", "graceful → Comment (dim, neutral)")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
