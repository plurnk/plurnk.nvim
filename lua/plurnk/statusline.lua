-- Statusline component. Reports the active session and the live state
-- that flows in from log/entry / loop/terminated notifications: model
-- alias, current loop id, turn, final status, cost, pending proposals,
-- YOLO toggle. Mirrors the visual vocabulary of the npm client TUI.
local M = {}
local state = require("plurnk.state")

-- Mirror of @plurnk/plurnk src/subcommands.ts formatCost.
local function format_cost(pico)
  if not pico or pico == 0 then return nil end
  local usd = pico / 1e12
  if usd < 0.01 then return string.format("$%.4f%s", usd * 100, "c") end
  return string.format("$%.4f", usd)
end

local function status_glyph(final)
  if not final then return "⏳" end
  if final == 200 then return "✅" end
  if final >= 400 and final < 500 then return "⚠️" end
  if final >= 500 then return "🔥" end
  return "·"
end

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local session = vim.b[buf].plurnk_session
  if not session then return "" end

  local parts = { "plurnk[" .. session .. "]" }

  local model = state.get_model_alias(session)
  if model then parts[#parts+1] = "🤖 " .. model end

  local loop_id = state.get_current_loop_id(session)
  local turn = state.get_current_turn(session)
  if loop_id then
    if turn then parts[#parts+1] = string.format("L%s·T%s", tostring(loop_id), tostring(turn))
    else parts[#parts+1] = "L" .. tostring(loop_id) end
  end

  local final = state.get_final_status(session)
  parts[#parts+1] = status_glyph(final) .. (final and (" " .. tostring(final)) or "")

  local cost = format_cost(state.get_cost_pico(session))
  if cost then parts[#parts+1] = cost end

  local ok_diff, diff = pcall(require, "plurnk.diff")
  if ok_diff and diff.is_yolo and diff.is_yolo() then parts[#parts+1] = "YOLO" end

  return table.concat(parts, " · ")
end

M.setup_highlights = function() end
return M
