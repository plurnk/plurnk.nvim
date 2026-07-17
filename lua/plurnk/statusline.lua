-- Statusline component — deliberately LEAN (operator, 2026-06-20). The
-- statusline is shared ecosystem real estate (the user's own bar, next to
-- file/git/LSP), so plurnk spends exactly one glance here: 🐹 + a live status
-- emoji (⏳ running, else the last final's glyph) + a 🔥 when YOLO is armed.
-- The rich detail — identity, model, L·T, tokens, and the persistent money
-- trio — lives in the winbar (plurnk's OWN window header; see worker_tab.lua).
local M = {}
local state = require("plurnk.state")

-- ⏳ while a loop is in flight; else render.lua's aligned final-status glyph
-- (matches the waterfall and the TUI), falling back to · for an unmapped code.
local function status_glyph(workspace)
  if state.is_loop_inflight(workspace) then return "⏳" end
  local final = state.get_final_status(workspace)
  if not final then return nil end
  local g = require("plurnk.render").status_glyph(final)
  return (g ~= "" and g) or "·"
end

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local workspace = vim.b[buf].plurnk_workspace
  if not workspace then return "" end

  local parts = { "🐹" }
  local glyph = status_glyph(workspace)
  if glyph then parts[#parts + 1] = glyph end

  -- The abacus: re-embedding in progress (token recount) — one glyph, edge-toggled.
  if state.is_embedding(workspace) then parts[#parts + 1] = "🧮" end

  local ok_diff, diff = pcall(require, "plurnk.diff")
  if ok_diff and diff.is_yolo and diff.is_yolo() then parts[#parts + 1] = "🔥" end

  return table.concat(parts, " ")
end

M.setup_highlights = function() end
return M
