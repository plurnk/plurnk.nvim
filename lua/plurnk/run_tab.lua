-- Session-tab UI scaffold. Mirrors rummy.nvim/main/lua/rummy/run_tab.lua:
-- each session lives in its own tabpage with two windows —
--   top:    the waterfall scratch buffer (log/entry stream)
--   bottom: a 3-line input scratch buffer; <CR> submits a prompt
-- so the user can read what's happening while composing the next line.
--
-- ensure_buffer is idempotent per session_name; opening the tab again just
-- focuses the existing one.

local M = {}

local buffers = {}  -- session → waterfall bufnr
local tabs    = {}  -- session → { tabpage, waterfall_win, input_win, input_buf }

local function ensure_buffer(session_name)
  local buf = buffers[session_name]
  if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, "plurnk://" .. session_name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].plurnk_session = session_name
  buffers[session_name] = buf
  return buf
end

M.current_alias = function()
  local buf = vim.api.nvim_get_current_buf()
  return vim.b[buf].plurnk_session
end

-- Find a valid record for this session, dropping it if its tabpage went
-- away (user `:tabclose`d it).
local function valid_record(session_name)
  local rec = tabs[session_name]
  if not rec then return nil end
  if not vim.api.nvim_tabpage_is_valid(rec.tabpage) then
    tabs[session_name] = nil
    return nil
  end
  return rec
end

-- Configure the top (waterfall) window: wrap on, no number column, a
-- winbar with the session glyph + name.
local function decorate_waterfall_win(win, session_name)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].scrolloff = 3
  pcall(vim.api.nvim_set_option_value, "winbar",
    " ⚡ " .. session_name .. " ", { win = win })
end

-- Open (or focus) the session tabpage. Creates the bottom input split
-- on first open. Focuses the input window so the user can start typing.
M.open = function(session_name)
  if not session_name then return end

  local rec = valid_record(session_name)
  if rec then
    vim.api.nvim_set_current_tabpage(rec.tabpage)
    if rec.input_win and vim.api.nvim_win_is_valid(rec.input_win) then
      vim.api.nvim_set_current_win(rec.input_win)
      vim.cmd("startinsert")
    end
    return
  end

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wf_win = vim.api.nvim_get_current_win()
  local wf_buf = ensure_buffer(session_name)
  vim.api.nvim_win_set_buf(wf_win, wf_buf)
  decorate_waterfall_win(wf_win, session_name)

  -- Scroll waterfall to bottom if there's history.
  local total = vim.api.nvim_buf_line_count(wf_buf)
  pcall(vim.api.nvim_win_set_cursor, wf_win, { math.max(total, 1), 0 })

  -- Bottom input split, takes focus.
  local input_buf, input_win = require("plurnk.input").create_in_tab(session_name)

  tabs[session_name] = {
    tabpage = tabpage,
    waterfall_win = wf_win,
    waterfall_buf = wf_buf,
    input_win = input_win,
    input_buf = input_buf,
  }
end

-- Auto-scroll the waterfall window for this session, if it exists in
-- the current Neovim instance. Doesn't steal focus.
local function autoscroll_waterfall(session_name, buf)
  local rec = valid_record(session_name)
  if not rec then return end
  if not vim.api.nvim_win_is_valid(rec.waterfall_win) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, rec.waterfall_win, { math.max(total, 1), 0 })
end

-- Append-or-replace: replace the initial empty line on the first write
-- so the buffer doesn't carry a leading blank, then append after that.
local function write_lines(buf, lines)
  vim.bo[buf].modifiable = true
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #current == 1 and current[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  end
  vim.bo[buf].modifiable = false
end

M.append_history = function(session_name, entries)
  if not session_name or not entries or #entries == 0 then return end
  local buf = ensure_buffer(session_name)
  local render = require("plurnk.render")
  local lines = {}
  for _, entry in ipairs(entries) do
    for _, ln in ipairs(render.render_log_entry(entry)) do
      lines[#lines+1] = ln
    end
  end
  write_lines(buf, lines)
  autoscroll_waterfall(session_name, buf)
end

M.append_line = function(session_name, text)
  if not session_name or not text or text == "" then return end
  local buf = ensure_buffer(session_name)
  write_lines(buf, vim.split(text, "\n", { plain = true }))
  autoscroll_waterfall(session_name, buf)
end

-- The terminal SEND[200] line already signals loop end (and abnormal
-- terminations get a ❌ on whatever the last entry was). No extra
-- separator — the statusline carries the rest.
M.close_document = function(_) end

M.update_status = function(_) end  -- statusline polls; no-op here

M.setup = function() end

-- Expose the tab record for the input module (so submit can stay focused
-- on the input window, not jump to the waterfall).
M.get_record = function(session_name) return valid_record(session_name) end

return M
