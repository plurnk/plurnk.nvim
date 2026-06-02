-- Glyph-based waterfall renderer, mirroring @plurnk/plurnk's src/render.ts
-- (TUI mode). Same op / origin / sub-status glyphs so the visual vocabulary
-- is shared across CLI, TUI, and Neovim clients.
--
-- Color is *not* applied here. The session buffer's filetype is "plurnk_log"
-- and highlight groups (PlurnkOk / PlurnkWarn / PlurnkErr / PlurnkPath /
-- PlurnkDim) are defined in highlights.lua so colorschemes can override.

local M = {}

M.OP_GLYPHS = {
  FIND = "🔍",
  READ = "📖",
  EDIT = "✏️ ",
  COPY = "📋",
  MOVE = "📦",
  SHOW = "➕",
  HIDE = "➖",
  SEND = "✉️ ",
  EXEC = "⚙️ ",
}

M.ORIGIN_GLYPHS = {
  model = "🤖",
  client = "👤",
  system = "⚙️ ",
  plugin = "🔌",
}

local SEND_SUB = {
  [102] = "⏳",
  [200] = "✅",
  [201] = "✅",
  [202] = "✅",
  [410] = "🗑",
  [499] = "✋",
}

M.send_sub_glyph = function(status)
  if not status then return "" end
  if SEND_SUB[status] then return SEND_SUB[status] end
  if status >= 200 and status < 300 then return "✅" end
  if status >= 400 and status < 500 then return "⚠️ " end
  if status >= 500 and status < 600 then return "🔥" end
  return ""
end

local function ellipsize(s, n)
  if not s or #s <= n then return s or "" end
  return s:sub(1, n - 1) .. "…"
end

-- Extract the trailing context for an entry, op-specific.
-- Same shapes as the npm client's buildExtra.
local function build_extra(entry)
  local tx = type(entry.tx) == "table" and entry.tx or nil

  if entry.op == "EDIT" or entry.op == "EXEC" then
    if not tx then return "" end
    local body = type(tx.body) == "string" and tx.body or ""
    if body == "" then return "" end
    return '"' .. ellipsize(body:gsub("\n", " "), 40) .. '"'
  end

  if entry.op == "READ" then
    local rx = entry.rx
    local content = type(rx) == "table" and type(rx.content) == "string" and rx.content or ""
    if content == "" then return "" end
    return '"' .. ellipsize(content:gsub("\n", " "), 40) .. '"'
  end

  if entry.op == "FIND" then
    local rx = entry.rx
    local results = type(rx) == "table" and type(rx.results) == "string" and rx.results or ""
    local count = 0
    if results ~= "" then
      for line in results:gmatch("[^\n]+") do
        if line ~= "" then count = count + 1 end
      end
    end
    return string.format("→ %d result%s", count, count == 1 and "" or "s")
  end

  if entry.op == "COPY" or entry.op == "MOVE" then
    if not tx then return "" end
    local body = type(tx.body) == "table" and tx.body or nil
    if body == nil then return "(deleted)" end
    return "→ " .. (body.raw or "")
  end

  if entry.op == "SEND" then
    if entry.scheme == nil and entry.pathname ~= nil then
      return "→ " .. entry.pathname
    end
    if entry.scheme ~= nil then
      return "→ " .. entry.scheme .. "://" .. (entry.pathname or "")
    end
  end

  return ""
end

-- Render the broadcast SEND (op=SEND, no path) as ONE line, body inlined
-- with newlines collapsed to spaces and ellipsized. Mirrors the trace-line
-- pattern used for every other op so the waterfall stays one-line-per-op.
-- (The npm TUI multi-line block is appropriate for a chat REPL; in the
-- nvim run_tab the user already has the full transcript via :PlurnkLog
-- and other surfaces — here we want a tight visual log.)
M.render_broadcast = function(entry)
  local origin = M.ORIGIN_GLYPHS[entry.origin] or "?"
  local op_glyph = M.OP_GLYPHS.SEND
  local sub_glyph = M.send_sub_glyph(entry.signal)
  local status = tostring(entry.status_rx or "?")

  -- tx.body per plurnk-grammar SendBody: { raw, json } | null.
  local body_text = ""
  local tx = entry.tx
  if type(tx) == "table" and type(tx.body) == "table" then
    body_text = type(tx.body.raw) == "string" and tx.body.raw or ""
  elseif type(tx) == "table" and type(tx.body) == "string" then
    body_text = tx.body
  end
  local body_inline = ""
  if body_text ~= "" then
    body_inline = '  "' .. ellipsize(body_text:gsub("[\r\n]+", " "), 80) .. '"'
  end

  local parts = { "  ", origin, " ", op_glyph }
  if sub_glyph ~= "" then table.insert(parts, " " .. sub_glyph) end
  table.insert(parts, " " .. status)
  if body_inline ~= "" then table.insert(parts, body_inline) end
  return { table.concat(parts) }
end

-- Render a regular (non-broadcast) trace line.
-- Returns a list of strings (always 1 for non-broadcast, multi for broadcast).
M.render_log_entry = function(entry)
  if entry.op == "SEND" and entry.scheme == nil and entry.pathname == nil then
    return M.render_broadcast(entry)
  end

  local origin = M.ORIGIN_GLYPHS[entry.origin] or "?"
  local op_glyph = M.OP_GLYPHS[entry.op] or "?"
  local sub_glyph = entry.op == "SEND" and M.send_sub_glyph(entry.signal) or ""

  -- Path: render whatever the daemon supplied. file:// has scheme=null with
  -- pathname set; render the bare pathname (no synthesis).
  local path = ""
  if entry.pathname ~= nil then
    if entry.scheme ~= nil then
      path = string.format("%s://%s%s%s",
        entry.scheme,
        entry.hostname or "",
        entry.pathname,
        entry.fragment and ("#" .. entry.fragment) or "")
    else
      path = entry.pathname
    end
  end

  local extra = build_extra(entry)
  local status = tostring(entry.status_rx or "?")

  -- Layout: `INDENT ORIGIN OP [SUB] STATUS PATH  EXTRA`
  local parts = { "  ", origin, " ", op_glyph }
  if sub_glyph ~= "" then table.insert(parts, " " .. sub_glyph) end
  table.insert(parts, " " .. status)
  if path ~= "" then table.insert(parts, " " .. path) end
  if extra ~= "" then table.insert(parts, "  " .. extra) end

  return { table.concat(parts) }
end

-- Render the per-loop summary line.
-- Same shape as the npm client's renderSummary.
M.render_summary = function(turns, wall_ms, tokens, final_status, hit_max_turns)
  local tag
  if hit_max_turns then
    tag = "maxTurns"
  elseif final_status == 200 then
    tag = "done"
  else
    tag = "final " .. tostring(final_status)
  end
  local ms
  if wall_ms and wall_ms >= 1000 then
    ms = string.format("%.2fs", wall_ms / 1000)
  else
    ms = tostring(wall_ms or 0) .. "ms"
  end
  return string.format("  %s · %d turn%s · %s · %d tokens",
    tag, turns or 0, (turns == 1) and "" or "s", ms, tokens or 0)
end

return M
