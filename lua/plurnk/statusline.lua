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

-- Delegate to render.lua's aligned STATUS_GLYPHS so the statusline's final-
-- status glyph matches the waterfall (and the TUI). No final yet = in flight.
local function status_glyph(final)
  if not final then return "⏳" end
  local g = require("plurnk.render").status_glyph(final)
  return g ~= "" and g or "·"
end

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local session = vim.b[buf].plurnk_session
  if not session then return "" end

  -- Session·run pair — the session is the workspace, the run is the
  -- conversation; neither alone identifies what you're looking at.
  local run = state.get_run_name(session)
  local parts = { "plurnk[" .. session .. (run and ("·" .. run) or "") .. "]" }

  local model = state.get_active_model(session)
  if model then parts[#parts+1] = "🤖 " .. model end

  local loop_id = state.get_current_loop_id(session)
  local turn = state.get_current_turn(session)
  if loop_id then
    if turn then parts[#parts+1] = string.format("L%s·T%s", tostring(loop_id), tostring(turn))
    else parts[#parts+1] = "L" .. tostring(loop_id) end
  end

  local final = state.get_final_status(session)
  parts[#parts+1] = status_glyph(final) .. (final and (" " .. tostring(final)) or "")

  -- The LAST loop's usage (↑prompt ↓completion + cost) — NOT a session total.
  -- The session lifetime total is the daemon's (svc#254), shown in
  -- `session list`, never reconstructed here. Two money figures only: the
  -- specific loop's cost and the account balance.
  local function fmt_count(n)
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
  end
  local usage = state.get_usage(session)
  if usage and (usage.prompt > 0 or usage.completion > 0) then
    parts[#parts+1] = "↑" .. fmt_count(usage.prompt) .. " ↓" .. fmt_count(usage.completion)
  end

  -- Money: loop (this loop's cost) | session (daemon's authoritative total,
  -- svc#254) | remaining (account balance, svc#252). Each shown ONLY when
  -- available — session/remaining are nil until the daemon pushes them. The
  -- client renders all three; it aggregates none of them.
  local function fmt_usd(pico) return string.format("$%.2f", pico / 1e12) end
  local money = {}
  local loop_cost = state.get_cost_pico(session)
  if type(loop_cost) == "number" and loop_cost > 0 then money[#money+1] = "loop: " .. fmt_usd(loop_cost) end
  local sess = state.get_session_cost_pico(session)
  if type(sess) == "number" then money[#money+1] = "session: " .. fmt_usd(sess) end
  local bal = state.get_balance_pico(session)
  if type(bal) == "number" then money[#money+1] = "remaining: " .. fmt_usd(bal) end
  if #money > 0 then parts[#parts+1] = table.concat(money, " | ") end

  local ok_diff, diff = pcall(require, "plurnk.diff")
  if ok_diff and diff.is_yolo and diff.is_yolo() then parts[#parts+1] = "YOLO" end

  return table.concat(parts, " · ")
end

M.setup_highlights = function() end
return M
