-- HUD: transient floating toast, bottom-right, auto-dismissing. Ported
-- from rummy.nvim hud.lua (part of the addictive feel — exec exits, yolo
-- applies, and mode toggles land here without stealing focus or piling
-- up in :messages the way vim.notify does). Headless falls back to
-- vim.notify so pipelines and specs still observe the message.
local M = {}

local HUD_DURATION_MS = 3000
local MAX_WIDTH = 80

local hud_buf, hud_win, hud_timer

local function close_hud()
  if hud_timer then
    pcall(function() hud_timer:stop(); hud_timer:close() end)
    hud_timer = nil
  end
  if hud_win and vim.api.nvim_win_is_valid(hud_win) then
    pcall(vim.api.nvim_win_close, hud_win, true)
  end
  if hud_buf and vim.api.nvim_buf_is_valid(hud_buf) then
    pcall(vim.api.nvim_buf_delete, hud_buf, { force = true })
  end
  hud_win = nil
  hud_buf = nil
end

M.show = function(text, duration_ms)
  close_hud()
  if not text or text == "" then return end
  if #vim.api.nvim_list_uis() == 0 then
    vim.notify(text, vim.log.levels.INFO)
    return
  end

  duration_ms = duration_ms or HUD_DURATION_MS
  local inner = MAX_WIDTH - 2

  -- Word-wrap, then pad to a clean box.
  local lines = {}
  local remaining = text:gsub("\n", " ")
  while #remaining > inner do
    local break_at = remaining:sub(1, inner):match(".*()%s") or inner
    lines[#lines + 1] = " " .. remaining:sub(1, break_at):gsub("%s+$", "") .. " "
    remaining = remaining:sub(break_at + 1):gsub("^%s+", "")
  end
  if #remaining > 0 then lines[#lines + 1] = " " .. remaining .. " " end
  local widest = 0
  for _, l in ipairs(lines) do widest = math.max(widest, vim.fn.strdisplaywidth(l)) end
  for i, l in ipairs(lines) do
    lines[i] = l .. string.rep(" ", widest - vim.fn.strdisplaywidth(l))
  end

  hud_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hud_buf, 0, -1, false, lines)
  vim.bo[hud_buf].buftype = "nofile"

  local width = math.min(widest, MAX_WIDTH)
  local height = #lines
  hud_win = vim.api.nvim_open_win(hud_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(vim.o.lines - height - 4, 0),
    col = math.max(vim.o.columns - width - 4, 0),
    style = "minimal",
    border = "rounded",
    title = " plurnk ",
    title_pos = "center",
    focusable = false,
    noautocmd = true,
  })
  pcall(vim.api.nvim_set_option_value, "winhl",
    "Normal:PlurnkHudText,FloatBorder:PlurnkHudBorder", { win = hud_win })

  hud_timer = vim.uv.new_timer()
  hud_timer:start(duration_ms, 0, vim.schedule_wrap(close_hud))
end

M.is_open = function()
  return hud_win ~= nil and vim.api.nvim_win_is_valid(hud_win)
end

M.clear_all_virtual_text = function() end
M.mark_buffer = function(_, _) end

M.setup_highlights = function()
  pcall(vim.api.nvim_set_hl, 0, "PlurnkHudText", { fg = "#aaaaaa", bg = "#1a1a1a", default = true })
  pcall(vim.api.nvim_set_hl, 0, "PlurnkHudBorder", { fg = "#444444", bg = "#1a1a1a", default = true })
end

return M
