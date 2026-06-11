-- Streaming-channel rendering for plurnk's stream/event + stream/concluded
-- notifications (plurnk-service SPEC §7.1 / §13.6). #16 phase 2: rummy
-- stream-window parity, daemon-owned.
--
-- One scratch buffer per entry. Channels interleave with rummy's column
-- prefixes (`1│` stdout, `2│` stderr, `·│` anything else); stderr lines
-- highlight DiagnosticError. stream/event ticks coalesce through a 100ms
-- flush timer into one entry.read per entry (the daemon's notification is
-- metadata-only; content is pulled). Only complete lines render — a
-- trailing partial is held until its newline arrives or the stream
-- concludes. Every window showing the buffer auto-scrolls unless it's the
-- current window (don't yank the cursor from a reading user). Wiping the
-- buffer of a LIVE stream cancels the subscription the way the DSL does:
-- SEND[499] at the stream's URI (§7.7).

local M = {}

local ns = vim.api.nvim_create_namespace("plurnk_stream")
local FLUSH_MS = 100

-- entry_id → {
--   buf, win, target,
--   read    = { [channel] = bytes already consumed },
--   partial = { [channel] = trailing text awaiting its newline },
--   dirty, timer_running, concluded,
-- }
local streams = {}

local CHANNEL_PREFIX = { stdout = "1│ ", stderr = "2│ " }
local CHANNEL_HL = { stderr = "DiagnosticError" }

local function get_or_create(entry_id, target)
  local st = streams[entry_id]
  if st and st.buf and vim.api.nvim_buf_is_valid(st.buf) then return st end

  local buf = vim.api.nvim_create_buf(true, true)
  local safe = (target or ("entry-" .. entry_id)):gsub("[:/%%]", "_")
  pcall(vim.api.nvim_buf_set_name, buf, "plurnk://stream/" .. safe)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  st = { buf = buf, target = target, read = {}, partial = {},
         dirty = false, timer_running = false, concluded = false }
  streams[entry_id] = st

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      if not st.concluded then
        require("plurnk.transport").send("op.send", { status = 499, recipient = st.target }, false)
      end
      streams[entry_id] = nil
    end,
  })
  return st
end

-- Open (or find) the stream split: below the session waterfall when one
-- exists, else below the current window. Focus stays where the user is.
local function ensure_window(st)
  if st.win and vim.api.nvim_win_is_valid(st.win)
     and vim.api.nvim_win_get_buf(st.win) == st.buf then return end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == st.buf then st.win = w; return end
  end
  local origin = vim.api.nvim_get_current_win()
  vim.cmd("belowright 10split")
  vim.api.nvim_win_set_buf(0, st.buf)
  st.win = vim.api.nvim_get_current_win()
  vim.wo[st.win].wrap = true
  vim.wo[st.win].number = false
  vim.wo[st.win].relativenumber = false
  vim.wo[st.win].cursorline = false
  vim.wo[st.win].signcolumn = "no"
  pcall(vim.api.nvim_set_option_value, "winbar",
    " stream: " .. (st.target or "") .. " ", { win = st.win })
  if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
end

-- Append prefixed lines for one channel; highlight per CHANNEL_HL.
local function append_lines(st, channel, lines)
  if #lines == 0 then return end
  local prefix = CHANNEL_PREFIX[channel] or "·│ "
  local rendered = {}
  for i, ln in ipairs(lines) do rendered[i] = prefix .. ln end

  vim.bo[st.buf].modifiable = true
  local current = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  local start_row
  if #current == 1 and current[1] == "" then
    vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, rendered)
    start_row = 0
  else
    start_row = #current
    vim.api.nvim_buf_set_lines(st.buf, -1, -1, false, rendered)
  end
  vim.bo[st.buf].modifiable = false

  local hl = CHANNEL_HL[channel]
  if hl then
    for i = 0, #rendered - 1 do
      pcall(vim.api.nvim_buf_set_extmark, st.buf, ns, start_row + i, 0,
        { end_row = start_row + i + 1, hl_eol = true, hl_group = hl })
    end
  end
end

-- Consume the unread tail of a channel's content; render complete lines,
-- hold the trailing partial.
local function append_channel_delta(st, channel, content)
  local consumed = st.read[channel] or 0
  if #content <= consumed then return end
  local delta = content:sub(consumed + 1)
  st.read[channel] = #content

  local text = (st.partial[channel] or "") .. delta
  local lines = vim.split(text, "\n", { plain = true })
  st.partial[channel] = table.remove(lines)
  append_lines(st, channel, lines)
end

-- Stable channel order: stdout, stderr, then the rest alphabetically.
local function ordered_channels(channels)
  local rank = { stdout = 1, stderr = 2 }
  local names = vim.tbl_keys(channels)
  table.sort(names, function(a, b)
    local ra, rb = rank[a] or 3, rank[b] or 3
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return names
end

local function render_channels(st, channels)
  for _, name in ipairs(ordered_channels(channels)) do
    local ch = channels[name]
    if type(ch) == "table" and type(ch.content) == "string" then
      append_channel_delta(st, name, ch.content)
    end
  end
end

-- Auto-scroll every window showing the buffer — except the one the user
-- is in, so reading scrollback isn't fought.
local function autoscroll(st)
  local cur = vim.api.nvim_get_current_win()
  local total = vim.api.nvim_buf_line_count(st.buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= cur and vim.api.nvim_win_get_buf(w) == st.buf then
      pcall(vim.api.nvim_win_set_cursor, w, { math.max(total, 1), 0 })
    end
  end
end

local function flush(entry_id)
  local st = streams[entry_id]
  if not st then return end
  st.timer_running = false
  if not st.dirty or st.concluded then return end
  st.dirty = false
  require("plurnk.transport").send("entry.read", { target = st.target }, false, function(result)
    if type(result) ~= "table" or type(result.entry) ~= "table" then return end
    local channels = result.entry.channels or {}
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(st.buf) then return end
      ensure_window(st)
      render_channels(st, channels)
      autoscroll(st)
    end)
  end)
end

-- stream/event: a channel grew or transitioned state. Mark dirty; the
-- flush timer batches ticks into one entry.read.
M.on_event = function(params, _session_name)
  if not params or type(params.entryId) ~= "number" then return end
  if type(params.target) ~= "string" or #params.target == 0 then return end
  local st = get_or_create(params.entryId, params.target)
  if st.concluded then return end
  if (tonumber(params.contentLength) or 0) == 0 then return end
  st.dirty = true
  if not st.timer_running then
    st.timer_running = true
    vim.defer_fn(function() flush(params.entryId) end, FLUSH_MS)
  end
end

-- stream/concluded: final pull, flush held partials, footer + winbar +
-- toast; drop tracking (the buffer persists for reading).
M.on_concluded = function(params, _session_name)
  if not params or type(params.entryId) ~= "number" then return end
  local st = streams[params.entryId]

  local close = tostring(params.closeStatus or "?")
  local summary = tostring(params.summary or "")
  local glyph = params.closeStatus == 200 and "✓"
    or (params.closeStatus == 499 and "✋" or "✗")
  pcall(function()
    require("plurnk.hud").show(string.format("%s %s → %s%s", glyph,
      tostring(params.target or (st and st.target) or ("entry " .. params.entryId)),
      close, summary ~= "" and (" · " .. summary) or ""))
  end)

  if not st then return end
  st.concluded = true
  if not vim.api.nvim_buf_is_valid(st.buf) then
    streams[params.entryId] = nil
    return
  end

  require("plurnk.transport").send("entry.read", { target = st.target }, false, function(result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(st.buf) then streams[params.entryId] = nil; return end
      if type(result) == "table" and type(result.entry) == "table" then
        render_channels(st, result.entry.channels or {})
      end
      -- The stream won't send these partials' newlines now — render them.
      for name, tail in pairs(st.partial) do
        if tail and tail ~= "" then append_lines(st, name, { tail }) end
      end
      st.partial = {}
      vim.bo[st.buf].modifiable = true
      vim.api.nvim_buf_set_lines(st.buf, -1, -1, false, {
        "",
        "── concluded · " .. close .. (summary ~= "" and (" · " .. summary) or "") .. " ──",
      })
      vim.bo[st.buf].modifiable = false
      if st.win and vim.api.nvim_win_is_valid(st.win) then
        pcall(vim.api.nvim_set_option_value, "winbar",
          " stream: " .. (st.target or "") .. " · concluded " .. close .. " ", { win = st.win })
      end
      autoscroll(st)
      streams[params.entryId] = nil
    end)
  end)
end

-- Test/teardown hook.
M.reset = function()
  streams = {}
end

return M
