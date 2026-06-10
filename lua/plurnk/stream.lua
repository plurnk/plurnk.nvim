-- Streaming-channel rendering for plurnk's stream/event + stream/concluded
-- notifications (plurnk-service SPEC §7.1 / §13.6).
--
-- The daemon owns the subprocess (exec scheme, etc.); we receive notifications
-- when a channel's content grows or its state transitions. The notification
-- carries metadata only (entryId, target URI, channel name, state,
-- contentLength) — we fetch the actual content with entry.read({target}).
-- `target` arrived in plurnk-service #179 (the upstream request we filed);
-- no entry_id → URI lookup is needed anymore.

local M = {}

local stream_state = {}     -- entry_id (number)  → { last_length, channel, buf, win }

local function get_or_create_buf(entry_id, target, channel)
  local st = stream_state[entry_id]
  if st and st.buf and vim.api.nvim_buf_is_valid(st.buf) then return st end

  local buf = vim.api.nvim_create_buf(true, true)
  local safe = (target or ("entry-" .. entry_id)):gsub("[:/%%]", "_")
  pcall(vim.api.nvim_buf_set_name, buf, "plurnk://stream/" .. safe)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  st = { last_length = 0, channel = channel, buf = buf, target = target }
  stream_state[entry_id] = st
  return st
end

-- Open (or focus) the streaming buffer in a horizontal split below.
local function ensure_window(st)
  if st.win and vim.api.nvim_win_is_valid(st.win) then return st.win end
  -- Find any existing window already showing this buf.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == st.buf then st.win = w; return w end
  end
  -- Open one beside the current window.
  vim.cmd("belowright 10split")
  vim.api.nvim_win_set_buf(0, st.buf)
  st.win = vim.api.nvim_get_current_win()
  vim.wo[st.win].wrap = true
  vim.wo[st.win].number = false
  vim.wo[st.win].relativenumber = false
  vim.wo[st.win].cursorline = false
  pcall(function() vim.wo[st.win].winbar = " stream: " .. (st.target or "") .. " " end)
  return st.win
end

-- stream/event: a channel grew or transitioned state. Metadata-only —
-- we fetch the body via entry.read on the carried target URI.
M.on_event = function(params, _session_name)
  if not params or type(params.entryId) ~= "number" then return end
  if type(params.target) ~= "string" or #params.target == 0 then return end
  local entry_id = params.entryId
  local target = params.target

  local content_length = tonumber(params.contentLength) or 0
  local st = get_or_create_buf(entry_id, target, params.channel)
  st.target = target

  if content_length == 0 or content_length <= st.last_length then
    return  -- nothing new since last fetch
  end

  local transport = require("plurnk.transport")
  transport.send("entry.read", { target = target }, false, function(result)
    if type(result) ~= "table" or type(result.entry) ~= "table" then return end
    local entry = result.entry
    -- entry.read returns the full entry. Channels live under entry.channels
    -- keyed by name; for v0.1.1 we look at the named channel (params.channel)
    -- if present, otherwise fall back to entry.body.
    local content = nil
    if entry.channels and params.channel and entry.channels[params.channel] then
      content = entry.channels[params.channel].content or entry.channels[params.channel]
    elseif type(entry.body) == "string" then
      content = entry.body
    end
    if type(content) ~= "string" then return end

    -- Append only the delta since last_length so the buffer doesn't redraw
    -- the world on every tick.
    if #content <= st.last_length then return end
    local delta = content:sub(st.last_length + 1)
    st.last_length = #content

    vim.schedule(function()
      ensure_window(st)
      vim.bo[st.buf].modifiable = true
      local existing = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
      -- Append by splitting delta on newlines and concatenating to the last
      -- line if it was partial (no trailing newline).
      local last_line = existing[#existing] or ""
      local new_lines = vim.split(last_line .. delta, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(st.buf, math.max(#existing - 1, 0), -1, false, new_lines)
      vim.bo[st.buf].modifiable = false
    end)
  end)
end

-- stream/concluded: the underlying subscription closed. Mark the buffer
-- with a one-liner summary; drop tracking.
M.on_concluded = function(params, _session_name)
  if not params or type(params.entryId) ~= "number" then return end
  local entry_id = params.entryId
  local st = stream_state[entry_id]
  if not st or not vim.api.nvim_buf_is_valid(st.buf) then
    -- Best-effort even if no buffer was ever rendered.
    return
  end
  local summary = tostring(params.summary or "(no summary)")
  local close = tostring(params.closeStatus or "?")
  vim.schedule(function()
    vim.bo[st.buf].modifiable = true
    vim.api.nvim_buf_set_lines(st.buf, -1, -1, false, {
      "",
      "── concluded · " .. close .. " · " .. summary .. " ──",
    })
    vim.bo[st.buf].modifiable = false
  end)
  stream_state[entry_id] = nil
end

-- Test/teardown hook.
M.reset = function()
  stream_state = {}
end

return M
