-- Session-tab UI scaffold for v0.1.
--
-- For each session, holds a single scratch buffer that the log/entry
-- waterfall appends to. The richer rummy session-tab features (split
-- with chat input, persistent transcript across sessions, etc.) are
-- not yet ported; this is the minimum viable surface so dispatch.lua's
-- append_history calls have somewhere to write.

local M = {}

local buffers = {}  -- keyed by session name → bufnr

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

-- Return the session name associated with the current tab/buffer, or
-- nil. (Used by commands.lua to detect "this buffer is already in a
-- plurnk session.")
M.current_alias = function()
  local buf = vim.api.nvim_get_current_buf()
  return vim.b[buf].plurnk_session
end

-- Open the session's buffer in a new tab. Idempotent: if a window is
-- already showing it, just focus that window.
M.open = function(session_name)
  if not session_name then return end
  local buf = ensure_buffer(session_name)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_set_current_tabpage(tab)
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end
  vim.cmd("tabnew")
  vim.api.nvim_set_current_buf(buf)
end

-- Render a list of log entries (or a single one) into the session buf.
-- Format mirrors the npm plurnk CLI's plain trace:
--   `[<status>] <origin> <op>[<sub>] <path>`
M.append_history = function(session_name, entries)
  if not session_name or not entries or #entries == 0 then return end
  local buf = ensure_buffer(session_name)
  local lines = {}
  for _, entry in ipairs(entries) do
    local sub = ""
    if entry.op == "SEND" and type(entry.signal) == "number" then
      sub = "[" .. tostring(entry.signal) .. "]"
    end
    local path = ""
    if entry.pathname then
      if entry.scheme then
        path = string.format(" %s://%s%s", entry.scheme, entry.hostname or "", entry.pathname)
      else
        path = " " .. entry.pathname
      end
    end
    lines[#lines+1] = string.format("[%s] %s %s%s%s",
      tostring(entry.status_rx or "?"),
      tostring(entry.origin or "?"),
      tostring(entry.op or "?"),
      sub,
      path)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Reflect terminal-status state in the buffer title or status bar.
-- For v0.1 just a horizontal-rule separator marking the boundary.
M.close_document = function(session_name)
  if not session_name then return end
  local buf = buffers[session_name]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "── loop terminated ──", "" })
  vim.bo[buf].modifiable = false
end

M.update_status = function(_) end  -- statusline polls; no-op here

M.setup = function() end

return M
