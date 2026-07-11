-- [§nvim-exec-e2e]
-- :AI! end-to-end against a real daemon: op.exec dispatches through the
-- engine, the exec scheme streams stdout over stream/event, and the
-- stream split renders prefixed lines. The launch demo, asserted.
local NAME = "17_exec_live"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  -- EXEC is proposal-gated (202 → loop/proposal); auto-accept via client
  -- YOLO so the headless run doesn't wait on a review keypress.
  require("plurnk.diff").set_yolo(true)
  local ai = require("plurnk.commands").ai
  ai({ args = "! echo alpha && echo beta", range = 0 })

  local function stream_lines()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("^plurnk://stream/") then
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      end
    end
    return nil
  end

  H.wait_for(function()
    local lines = stream_lines()
    if not lines then return false end
    local seen_alpha, seen_beta = false, false
    for _, ln in ipairs(lines) do
      if ln == "1│ alpha" then seen_alpha = true end
      if ln == "1│ beta" then seen_beta = true end
    end
    return seen_alpha and seen_beta
  end, 20000, "exec output rendered with 1│ prefix")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
