-- Glyph-based waterfall renderer, mirroring @plurnk/plurnk's src/render.ts
-- (TUI mode). Same op / origin / sub-status glyphs so the visual vocabulary
-- is shared across CLI, TUI, and Neovim clients.

local M = {}

M.OP_GLYPHS = {
  FIND = "🔍",
  READ = "📖",
  EDIT = "📝",
  COPY = "📋",
  MOVE = "📦",
  SHOW = "➕",
  HIDE = "➖",
  OPEN = "➕",
  FOLD = "➖",
  SEND = "💬",
  EXEC = "🔧",
}

M.ORIGIN_GLYPHS = {
  model = "🤖",
  client = "👤",
  plurnk = "🧰",   -- the runtime actor (§14.7)
  plugin = "🔌",
}

-- Aligned to the grammar's terminal SEND set [102, 200, 202, 300, 499]
-- (plurnk-grammar plurnk.md) + directed-SEND/error families. The glyph carries
-- the state, the color carries the class. Converged with @plurnk/plurnk
-- sendSubGlyph. All EAW width-2, VS16-free (column-stable).
local STATUS_GLYPHS = {
  [102] = "⏳",   -- continuing — more turns coming
  [120] = "⏳",
  [200] = "✅",   -- success / final
  [201] = "✅",
  [202] = "💤",   -- parked/waiting on an external event (NOT generic 2xx)
  [300] = "❓",   -- needs a decision (multiple choices)
  [410] = "💥",   -- directed SEND to a gone resource
  [499] = "✋",   -- failed / aborted / cancelled
}

-- Status sub-glyph used for EVERY op (not just SEND). SEND's `signal` is
-- itself the HTTP status, so use it as the primary code; everything else
-- reads `status_rx`. 4xx and 5xx both render ❌ so the user gets a single
-- failure signal in the alignment column.
M.status_glyph = function(status_rx, signal)
  local code
  if type(signal) == "number" then code = signal else code = status_rx end
  if type(code) ~= "number" then return "" end
  if STATUS_GLYPHS[code] then return STATUS_GLYPHS[code] end
  if code >= 200 and code < 300 then return "✅" end
  if code >= 400 and code < 600 then return "❌" end
  return ""
end

-- Back-compat alias for v0.3 callers.
M.send_sub_glyph = function(status) return M.status_glyph(nil, status) end

local function ellipsize(s, n)
  if not s or #s <= n then return s or "" end
  return s:sub(1, n - 1) .. "…"
end

-- Extract the trailing context for an entry, op-specific.
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
    -- Non-broadcast SEND (path target). Broadcast handled by render_broadcast.
    if entry.scheme == nil and entry.pathname ~= nil then
      return "→ " .. entry.pathname
    end
    if entry.scheme ~= nil then
      return "→ " .. entry.scheme .. "://" .. (entry.pathname or "")
    end
  end

  return ""
end

-- BROADCAST_INLINE_LIMIT: short single-line bodies inline after the status;
-- anything longer or multi-line falls through to the indented block form.
-- Picked to comfortably fit "Paris", "4", "yes", short markdown phrases.
local BROADCAST_INLINE_LIMIT = 80

-- `01/02/03 ` coordinate prefix — the model's log://L/T/S address,
-- zero-padded min-2 for alignment. Empty until the wire carries the
-- seqs (plurnk-service#208); DB ids are NOT the user's loop/turn
-- numbers and are never substituted.
-- Every wire log entry carries the coordinate (loops⋈turns JOIN, #208);
-- render it directly — a missing ordinal is a contract violation that
-- should surface, not be masked with a blank.
local function coord_prefix(entry)
  return string.format("%02d/%02d/%02d ", entry.loop_seq, entry.turn_seq, entry.sequence)
end

-- Render the broadcast SEND (op=SEND, no path). For short single-line
-- bodies, inline after the status. For multi-line or long bodies, header
-- line + body lines indented under the speaker.
M.render_broadcast = function(entry)
  local origin = M.ORIGIN_GLYPHS[entry.origin] or "?"
  local op_glyph = M.OP_GLYPHS.SEND
  local sub_glyph = M.status_glyph(entry.status_rx, entry.signal)
  local status = tostring(entry.status_rx or "?")

  local header_parts = { coord_prefix(entry), origin, " ", op_glyph }
  if sub_glyph ~= "" then table.insert(header_parts, " " .. sub_glyph) end
  table.insert(header_parts, " " .. status)
  local header = table.concat(header_parts)

  local body_text = ""
  local tx = entry.tx
  if type(tx) == "table" and type(tx.body) == "table" then
    body_text = type(tx.body.raw) == "string" and tx.body.raw or ""
  elseif type(tx) == "table" and type(tx.body) == "string" then
    body_text = tx.body
  end
  if body_text == "" then return { header } end

  -- Short and single-line: inline.
  if not body_text:find("\n", 1, true) and #body_text <= BROADCAST_INLINE_LIMIT then
    return { header .. "  " .. body_text }
  end

  local lines = { header }
  for chunk in (body_text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines+1] = "   " .. chunk
  end
  if lines[#lines] == "   " then table.remove(lines) end
  return lines
end

-- The user's prompt is conversation, not an op record. The engine writes
-- it as a plurnk-origin EDIT to plurnk://prompt/<loop>/<turn> (service
-- SPEC §15); render it as the user speaking — 👤 💬 with the prompt body
-- — instead of an EDIT trace. Arrives on hydration/log.read today; live
-- the moment plurnk-service#198 (prompt broadcast) lands.
M.is_prompt_entry = function(entry)
  return entry.op == "EDIT" and entry.scheme == "plurnk"
    and type(entry.pathname) == "string" and entry.pathname:sub(1, 7) == "prompt/"
end

M.render_prompt = function(entry)
  local body = type(entry.tx) == "table" and type(entry.tx.body) == "string" and entry.tx.body or ""
  local header = coord_prefix(entry) .. M.ORIGIN_GLYPHS.client .. " " .. M.OP_GLYPHS.SEND
  if body == "" then return { header } end
  if not body:find("\n", 1, true) and #body <= BROADCAST_INLINE_LIMIT then
    return { header .. "  " .. body }
  end
  local lines = { header }
  for chunk in (body .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines+1] = "   " .. chunk
  end
  if lines[#lines] == "   " then table.remove(lines) end
  return lines
end

-- Render a regular (non-broadcast) trace line.
M.render_log_entry = function(entry)
  if entry.op == "SEND" and entry.scheme == nil and entry.pathname == nil then
    return M.render_broadcast(entry)
  end
  if M.is_prompt_entry(entry) then
    return M.render_prompt(entry)
  end

  local origin = M.ORIGIN_GLYPHS[entry.origin] or "?"
  local op_glyph = M.OP_GLYPHS[entry.op] or "?"
  local sub_glyph = M.status_glyph(entry.status_rx, entry.signal)
  local status = tostring(entry.status_rx or "?")

  -- EXEC: signal carries the executor name per grammar SPEC §3 — show it
  -- in the path column as `[<executor>]`. The synthetic exec:// URI the
  -- daemon stamps on EXEC entries is noise from the user's perspective.
  local path = ""
  if entry.op == "EXEC" then
    if entry.signal ~= nil then path = "[" .. tostring(entry.signal) .. "]" end
  elseif entry.pathname ~= nil then
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

  -- Layout: ORIGIN OP SUB STATUS PATH  EXTRA  (no leading indent)
  local parts = { coord_prefix(entry), origin, " ", op_glyph }
  if sub_glyph ~= "" then table.insert(parts, " " .. sub_glyph) end
  table.insert(parts, " " .. status)
  if path ~= "" then table.insert(parts, " " .. path) end
  if extra ~= "" then table.insert(parts, "  " .. extra) end

  return { table.concat(parts) }
end

-- Per-loop summary line (still used by callers; the run_tab waterfall no
-- longer emits "loop terminated" since SEND[200] already carries that
-- signal).
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
  return string.format("%s · %d turn%s · %s · %d tokens",
    tag, turns or 0, (turns == 1) and "" or "s", ms, tokens or 0)
end

return M
