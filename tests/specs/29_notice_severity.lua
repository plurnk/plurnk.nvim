-- -- notice/event severity coloring off the producer-set notice.level (grammar
-- error → ErrorMsg (red), warn → WarningMsg (yellow),
-- info → Comment (dim). Mirrors the npm client (#110) — no kind heuristic.
local NAME = "29_notice_severity"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local dispatch = require("plurnk.dispatch")
  local render = require("plurnk.render")

  H.assert_eq(render.render_diagnostic({
    source = "grammar", kind = "parse_advisory", level = "warn", message = "boom",
    position = { type = "content-offset", line = 2, column = 4 },
    snippet = "bad line", hints = { "repair it" },
  }), '📡 grammar:parse_advisory L2 col4 "boom"\n   bad line\n   repair it',
    "Notice projection matches the terminal client")
  H.assert_eq(render.render_diagnostic({
    type = "https://problems.plurnk.xyz/client/render/failure",
    title = "render failure", status = 500, detail = "could not render",
    source = "client:render", kind = "failure", recovery = "inspect the source",
  }), '📡 client:render:failure "could not render"\n   inspect the source',
    "Problem projection matches the terminal client")

  -- Capture the highlight group safe_echo hands nvim_echo.
  local captured
  vim.api.nvim_echo = function(chunks) captured = chunks and chunks[1] end

  local function hl_for(level)
    captured = nil
    dispatch.handle_notice_event({ notice = { source = "grammar", kind = "parse_advisory", level = level, message = "x" } }, nil)
    vim.wait(200, function() return captured ~= nil end)  -- flush the vim.schedule
    return captured and captured[2]
  end

  H.assert_eq(hl_for("error"), "ErrorMsg", "level error → ErrorMsg (red)")
  H.assert_eq(hl_for("warn"), "WarningMsg", "level warn → WarningMsg (yellow)")
  H.assert_eq(hl_for("info"), "Comment", "level info → Comment (dim)")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
