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
  SEND = "💬",
  EXEC = "🔧",
  BARE = "🔮",
}

M.PLAN_STATUS_GLYPHS = {
  completed = "✅",
  in_progress = "🚧",
  pending = "⬜",
}
M.PLAN_MEMORY_GLYPH = "💾"

M.ORIGIN_GLYPHS = {
  model = "🤖",
  client = "❯",
  _plurnk = "🧰",
  plugin = "🔌",
}

-- A SEND's lifecycle is its one human-facing identity. Numeric SEND
-- codes remain wire truth but do not repeat beside these glyphs.
M.send_lifecycle_glyph = function(status)
  if status == 102 then return "▶️" end
  if status == 202 then return "💤" end
  if status == 300 then return "🤔" end
  if status == 499 then return "✋" end
  if type(status) == "number" and status >= 200 and status < 300 then return "⏹️" end
  if type(status) == "number" and status >= 400 and status < 600 then return "❌" end
  return "⏹️"
end

-- Aligned to the grammar's terminal SEND set [102, 200, 202, 300, 499]
-- (plurnk-grammar plurnk.md) + directed-SEND/error families. The glyph carries
-- the state, the color carries the class. Converged with @plurnk/plurnk
-- sendSubGlyph. All EAW width-2, VS16-free (column-stable).
local STATUS_GLYPHS = {
  [102] = "⏳",   -- continuing — more turns coming
  [120] = "⏳",
  [200] = "  ",   -- routine success badges NOTHING — reserved blank keeps the column
  [201] = "  ",
  [202] = "💤",   -- parked/waiting on an external event (NOT generic 2xx)
  [300] = "🤔",   -- needs a decision
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
  if code >= 200 and code < 300 then return "  " end
  if code >= 400 and code < 600 then return "❌" end
  return "  "   -- reserve the lane — never a width-shifting empty
end

-- Back-compat alias for v0.3 callers.
M.send_sub_glyph = function(status) return M.status_glyph(nil, status) end

local function ellipsize(s, n)
  if not s or #s <= n then return s or "" end
  return s:sub(1, n - 1) .. "…"
end

local function annotation(entry)
  local tx = type(entry.tx) == "table" and entry.tx or nil
  local raw = tx and type(tx.annotation) == "string" and tx.annotation or ""
  local plain = raw:gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("%c+", " "):gsub("%s+", " ")
  return plain:gsub("^%s+", ""):gsub("%s+$", "")
end

local function diagnostic_position(position)
  if type(position) ~= "table" then return "" end
  if position.type == "content-offset" then
    return "L" .. tostring(position.line) .. " col" .. tostring(position.column)
  end
  if position.type == "log-coordinate" then
    local coordinate = tostring(position.coordinate or "")
    return type(position.op) == "string" and coordinate .. " (" .. position.op .. ")" or coordinate
  end
  return ""
end

-- RFC 9457 Problems and Notices retain distinct contracts while sharing the
-- terminal client's exact human projection.
M.render_diagnostic = function(diagnostic)
  if type(diagnostic) ~= "table" then error("diagnostic must be a table") end
  local problem = type(diagnostic.type) == "string"
    and type(diagnostic.title) == "string"
    and type(diagnostic.status) == "number"
    and type(diagnostic.detail) == "string"
  local source = type(diagnostic.source) == "string" and diagnostic.source or "problem"
  local kind = type(diagnostic.kind) == "string" and diagnostic.kind
    or (problem and diagnostic.title or "notice")
  local message = problem and diagnostic.detail
    or (type(diagnostic.message) == "string" and diagnostic.message or "")
  local parts = { "📡", source .. ":" .. kind }
  local position = diagnostic_position(diagnostic.position)
  if position ~= "" then parts[#parts + 1] = position end
  if message ~= "" then parts[#parts + 1] = '"' .. message .. '"' end
  local lines = { table.concat(parts, " ") }
  if type(diagnostic.snippet) == "string" and diagnostic.snippet ~= "" then
    for line in (diagnostic.snippet .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = "   " .. line end
  end
  if problem and type(diagnostic.recovery) == "string" then
    lines[#lines + 1] = "   " .. diagnostic.recovery
  end
  if type(diagnostic.hints) == "table" then
    for _, hint in ipairs(diagnostic.hints) do
      if type(hint) == "string" then lines[#lines + 1] = "   " .. hint end
    end
  end
  return table.concat(lines, "\n")
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
    local results = type(rx) == "table" and rx.results or nil
    local count = 0
    if type(results) == "table" then
      count = #results
    elseif type(results) == "string" and results ~= "" then
      for line in results:gmatch("[^\n]+") do
        if line ~= "" then count = count + 1 end
      end
    end
    return string.format("→ %d result%s", count, count == 1 and "" or "s")
  end

  if entry.op == "COPY" or entry.op == "MOVE" then
    if not tx then return "" end
    local destination = type(tx.destination) == "table" and tx.destination or nil
    local target = destination and type(destination.target) == "table" and destination.target or nil
    return target and type(target.raw) == "string" and "→ " .. target.raw or ""
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

-- A common model-authored inline-math spelling with an exact editor glyph.
-- This is typographic normalization, not a claim of general LaTeX support.
local function normalize_prose(text)
  return text:gsub("%$\\rightarrow%$", "→")
end

-- Provider reasoning is neither PLAN nor speech. Preserve its line structure
-- in one quiet block without inventing a log coordinate or status code.
M.render_reasoning = function(content)
  if type(content) ~= "string" or content == "" then return {} end
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = (#lines == 0 and "💭 " or "   ") .. line
  end
  return lines
end

-- The human waterfall carries no log coordinates or routine status codes.
-- Failed operations retain diagnostic codes; SEND lifecycle
-- codes remain exact on the wire without repeating in human output.

local function plan_entry(entry)
  local projected_memory = entry.status == "completed"
    and type(entry.content) == "string"
    and entry.content:sub(1, 8) == "Memory: "
  local glyph = projected_memory and M.PLAN_MEMORY_GLYPH or M.PLAN_STATUS_GLYPHS[entry.status]
  if glyph == nil or type(entry.content) ~= "string" then
    error("PLAN row carries a noncanonical Plan entry")
  end
  if entry.priority ~= "medium" and entry.priority ~= "high" and entry.priority ~= "low" then
    error("PLAN row carries a noncanonical ACP Plan priority")
  end
  local content = entry.content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if projected_memory then content = content:sub(9) end
  if entry.priority ~= "medium" then content = "[" .. entry.priority .. "] " .. content end
  return glyph, content
end

local function render_plan(entry)
  local tx = type(entry.tx) == "table" and entry.tx or nil
  local plan = tx and type(tx.body) == "table" and tx.body or nil
  if plan == nil or type(plan.entries) ~= "table" then
    error("PLAN row must carry its canonical Plan body")
  end

  -- A routine PLAN carries no code; a failed one keeps its glyph + code on
  -- the first row.
  local status = tostring(entry.status_rx or "?")
  local failed = type(entry.status_rx) == "number" and entry.status_rx >= 400
  local first_slot = failed and (M.status_glyph(entry.status_rx, entry.signal) .. " " .. status .. " ") or ""
  local later_slot = failed and string.rep(" ", 3 + #status + 1) or ""
  local rows = {}
  for _, item in ipairs(plan.entries) do
    local glyph, text = plan_entry(item)
    rows[#rows + 1] = { glyph = glyph, text = text }
  end
  if #rows == 0 then rows[1] = { glyph = "📭", text = "no entries" } end

  local lines = {}
  for index, row in ipairs(rows) do
    local prefix
    if index == 1 then
      prefix = row.glyph .. " " .. first_slot
    else
      prefix = row.glyph .. " " .. later_slot
    end
    lines[index] = prefix .. row.text
  end
  local note = annotation(entry)
  if note ~= "" then lines[1] = lines[1] .. " — " .. note end
  return lines
end

local function broadcast_content(entry)
  -- One actor or lifecycle glyph, converged with the TUI. The exact status
  -- remains on the wire; repeating it beside the lifecycle glyph is noise.
  local signal = type(entry.signal) == "number" and entry.signal or entry.status_rx
  local glyph = M.send_lifecycle_glyph(signal)
  local note = annotation(entry)
  local header = glyph
  if note ~= "" then header = header .. " — " .. note end

  local body_text = ""
  local tx = entry.tx
  if type(tx) == "table" and type(tx.body) == "table" then
    body_text = type(tx.body.raw) == "string" and tx.body.raw or ""
  elseif type(tx) == "table" and type(tx.body) == "string" then
    body_text = tx.body
  end
  body_text = normalize_prose(body_text)
  return header, body_text
end

-- Pure source projection used by renderer tests and non-waterfall callers.
-- The worker-tab presentation may replace a Markdown body with a width-aware
-- projection, but the wire-derived source remains the block's authority.
M.render_broadcast = function(entry)
  local header, body_text = broadcast_content(entry)
  if body_text == "" then return { header } end

  -- Neovim owns wrapping at the live window width, so every source-level
  -- single line stays inline and soft-wraps natively when necessary.
  if not body_text:find("\n", 1, true) then
    return { header .. " " .. body_text }
  end

  local raw_lines = {}
  for chunk in (body_text .. "\n"):gmatch("([^\n]*)\n") do
    raw_lines[#raw_lines + 1] = chunk
  end
  local lines = { header }
  for _, chunk in ipairs(raw_lines) do
    lines[#lines+1] = "   " .. chunk
  end
  if lines[#lines] == "   " then table.remove(lines) end
  return lines
end

-- The user's prompt is conversation, not an op record. It arrives as an
-- actionless lowercase prompt row with its body in rx.content.
M.is_prompt_entry = function(entry)
  return entry.op == "prompt" and entry.scheme == "prompt"
end

M.render_prompt = function(entry)
  local body = type(entry.rx) == "table" and type(entry.rx.content) == "string" and entry.rx.content or ""
  local header = "❯"
  if body == "" then return { header } end
  if not body:find("\n", 1, true) then
    return { header .. " " .. body }
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
  if entry.op == "PLAN" then
    return render_plan(entry)
  end

  -- Operation rows retain an outcome slot. SEND rows use only their actor or
  -- lifecycle glyph: adding a second state repeats one fact.
  local op_glyph = M.OP_GLYPHS[entry.op] or "?"
  local signal = type(entry.signal) == "number" and entry.signal or entry.status_rx
  local primary_glyph = entry.op == "SEND"
    and M.send_lifecycle_glyph(signal)
    or op_glyph
  local sub_glyph = M.status_glyph(entry.status_rx)
  local status = tostring(entry.status_rx or "?")

  -- EXEC: the authored `[executor]` slot rides the statement (tx.executor); show it
  -- in the path column as the model wrote it. A bare shell EXEC shows nothing — the
  -- runtime-tag stream entry the daemon stamps is noise from the user's perspective.
  local path = ""
  if entry.op == "EXEC" then
    local tx = entry.tx
    if type(tx) == "table" and type(tx.executor) == "string" then path = "[" .. tx.executor .. "]" end
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

  local scope = ""
  if type(entry.lineMarker) == "table" and type(entry.lineMarker.marks) == "table" then
    local marks = {}
    for index, mark in ipairs(entry.lineMarker.marks) do marks[index] = tostring(mark) end
    scope = "<" .. table.concat(marks, ",") .. ">"
  end

  local extra = build_extra(entry)

  -- SEND lifecycle glyphs suppress routine protocol codes. A failed directed
  -- SEND retains its code like any other failed operation.
  local directed_send = entry.op == "SEND" and entry.pathname ~= nil
  local show_status = type(entry.status_rx) == "number" and entry.status_rx >= 400
    and (entry.op ~= "SEND" or directed_send)
  local parts = entry.op == "SEND" and { primary_glyph } or { primary_glyph, sub_glyph }
  if show_status then table.insert(parts, status) end
  if path ~= "" then table.insert(parts, path) end
  if scope ~= "" then table.insert(parts, scope) end
  if extra ~= "" then table.insert(parts, extra) end
  local note = annotation(entry)
  if note ~= "" then table.insert(parts, "— " .. note) end

  return { table.concat(parts, " ") }
end

-- A rendered waterfall block. Control rows remain literal Plurnk UI; only a
-- broadcast SEND body is interpreted as Markdown, preventing one body's syntax
-- state from styling later control rows. The caller owns the source entry and
-- may project it again at a different live window width.
M.render_log_block = function(entry, width, on_change)
  if entry.op ~= "SEND" or entry.scheme ~= nil or entry.pathname ~= nil then
    return { lines = M.render_log_entry(entry) }
  end

  local header, body = broadcast_content(entry)
  local markdown = require("plurnk.markdown")
  if body == "" or not markdown.looks_like_markdown(body) then
    return { lines = M.render_broadcast(entry) }
  end

  local projected = markdown.render(body, math.max(20, (width or 80) - 3), "   ", on_change)
  local content = { lines = { header } }
  for _, line in ipairs(projected.lines or {}) do content.lines[#content.lines + 1] = line end
  return content
end

-- Per-loop summary line (still used by callers; the worker_tab waterfall no
-- longer emits "loop terminated" since the terminal SEND already carries
-- signal 200).
-- Terminal loop status → label (converge client #70). plurnk-service 0.42.0
-- split the flat 499 into distinct verdicts: 499 is the model/actor give-up or
-- external KILL/cancel; 413/429/500/508 are ENGINE verdicts. Labelled so a
-- ceiling reads differently from an abandonment, not a bare "final N".
M.terminal_status_label = function(status)
  local labels = { [200] = "done", [413] = "budget overflow", [429] = "turn ceiling",
    [499] = "cancelled", [500] = "strike-out", [508] = "loop detected" }
  return labels[status] or ("final " .. tostring(status))
end

M.render_summary = function(turns, wall_ms, tokens, final_status, hit_max_turns)
  local tag = hit_max_turns and "maxTurns" or M.terminal_status_label(final_status)
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
