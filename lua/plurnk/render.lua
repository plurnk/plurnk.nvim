-- Waterfall row grammar, converged with @plurnk/plurnk's src/render.ts
-- ({§nvim-waterfall-rows}). An operation row is the authored heading,
-- `OP (target) <scope> /pattern/ {n} aside — problem title`, rendered as literal text with
-- this module's own highlights and never through Markdown; only delivered SEND bodies are
-- Markdown. Rows carry no bodies, glyphs, numeric codes, or coordinates.
--
-- A rendered block is `{ lines, highlights, fold_label }`; a highlight is
-- `{ line, col_start, col_end, group }` (1-based line within the block, byte columns).

local M = {}

-- ── Figures shared with the terminal client ─────────────────────────────

-- 582300 → "582k", 1234567 → "1.2M"; below a thousand, the number itself; unknown → "?".
M.abbreviated_count = function(value)
  if type(value) ~= "number" then return "?" end
  if value >= 1000000 then
    local millions = string.format("%.1f", value / 1000000):gsub("%.0$", "")
    return millions .. "M"
  end
  if value >= 1000 then return tostring(math.floor(value / 1000 + 0.5)) .. "k" end
  return tostring(value)
end

-- "3333.3333" → "3,333.3333", "0.024" → "0.0240": spend to the hundredth of a cent.
M.money = function(usd)
  local amount = tonumber(usd)
  if amount == nil then return tostring(usd) end
  local fixed = string.format("%.4f", amount)
  local whole, fraction = fixed:match("^(-?%d+)(%.%d+)$")
  local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^(-?),", "%1")
  return grouped .. fraction
end

-- ── Wire helpers ────────────────────────────────────────────────────────

local function present(value)
  if value == vim.NIL then return nil end
  return value
end

-- A wire field that may arrive as JSON text or as the decoded object.
M.object_of = function(value)
  value = present(value)
  if type(value) == "string" then
    local ok, decoded = pcall(vim.json.decode, value, { luanil = { object = true, array = true } })
    value = ok and decoded or nil
  end
  if type(value) ~= "table" then return nil end
  if next(value) ~= nil and vim.islist(value) then return nil end
  return value
end

-- Terminal control sequences and control characters never reach a row.
local function plain(text)
  local cleaned = tostring(text):gsub("\27%[[%d;?]*[ -/]*[@-~]", ""):gsub("%c", " ")
  return cleaned
end

M.entry_aside = function(entry)
  local tx = M.object_of(entry.tx)
  local raw = tx and present(tx.aside)
  if type(raw) ~= "string" then return nil end
  local collapsed = plain(raw):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if collapsed == "" then return nil end
  return collapsed
end

-- Machine acquisition is durable ambience, not a live action trace.
M.is_entry_materialization = function(entry)
  local attrs = M.object_of(entry.attrs)
  return entry.origin == "_plurnk" and entry.op == "EDIT" and attrs ~= nil and attrs.kind == "entry_materialized"
end

-- The target URI a log entry addressed, or the bare pathname when the scheme is null.
M.entry_target = function(entry)
  local pathname = present(entry.pathname)
  if pathname == nil then return nil end
  local scheme = present(entry.scheme)
  if scheme == nil then return pathname end
  local fragment = present(entry.fragment)
  return scheme .. "://" .. (present(entry.hostname) or "") .. pathname .. (fragment ~= nil and ("#" .. fragment) or "")
end

-- The authored target text when the wire carries it; the daemon's address otherwise.
M.authored_target = function(entry)
  local tx = M.object_of(entry.tx)
  local target = tx and M.object_of(tx.target)
  local raw = target and present(target.raw)
  if type(raw) == "string" then return raw end
  return M.entry_target(entry)
end

-- The matcher as authored on the heading (`/regex/i`, `~query`, `&symbol`, a bare glob).
M.authored_pattern = function(entry)
  local tx = M.object_of(entry.tx)
  local matcher = tx and M.object_of(tx.matcher)
  local raw = matcher and present(matcher.raw)
  if type(raw) == "string" and raw ~= "" then return raw end
  return nil
end

M.entry_scope = function(entry)
  local marker = M.object_of(entry.lineMarker)
  if marker == nil or type(marker.marks) ~= "table" then return nil end
  local marks = {}
  for index, mark in ipairs(marker.marks) do marks[index] = tostring(mark) end
  return "<" .. table.concat(marks, ",") .. ">"
end

-- One COPY/MOVE operand keeps its own target, scope, and matcher together.
local function selection_text(selection)
  local operand = M.object_of(selection)
  if operand == nil then return nil end
  local target = M.object_of(operand.target)
  local raw = target and present(target.raw)
  local marker = M.object_of(operand.lineMarker)
  local matcher = M.object_of(operand.matcher)
  local parts = {}
  if type(raw) == "string" then parts[#parts + 1] = "(" .. raw .. ")" end
  if marker ~= nil and type(marker.marks) == "table" then
    local marks = {}
    for index, mark in ipairs(marker.marks) do marks[index] = tostring(mark) end
    parts[#parts + 1] = "<" .. table.concat(marks, ",") .. ">"
  end
  if matcher ~= nil and type(present(matcher.raw)) == "string" then parts[#parts + 1] = matcher.raw end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

local function span_length(returned)
  returned = present(returned)
  if type(returned) ~= "table" or #returned ~= 2 then return nil end
  if type(returned[1]) ~= "number" or type(returned[2]) ~= "number" then return nil end
  return math.max(0, returned[2] - returned[1] + 1)
end

-- What the receipt returned, in the receipt's own unit: a FIND's returned items, a READ's
-- returned lines (a pattern read carries its matched lines as `lineOrdinals`). Never a body.
M.receipt_count = function(entry)
  local rx = M.object_of(entry.rx)
  if rx == nil then return nil end
  local range = M.object_of(rx.range)
  if entry.op == "READ" then
    local ordinals = present(rx.lineOrdinals)
    if type(ordinals) == "table" then return #ordinals end
    return span_length(range and range.returned)
  end
  if entry.op == "FIND" then
    local returned = span_length(range and range.returned)
    if returned ~= nil then return returned end
    local total = range and present(range.total)
    if type(total) == "number" then return total end
  end
  return nil
end

local function status_of(entry)
  return type(entry.status_rx) == "number" and entry.status_rx or 0
end

-- The structured result's own words for an unsuccessful outcome: the Problem title, else
-- the detail, else the bare status. A 204 with nothing countable carries its detail too.
M.outcome_title = function(entry)
  local rx = M.object_of(entry.rx)
  local status = status_of(entry)
  local detail = rx and present(rx.detail)
  if status >= 400 then
    local problem = rx and M.object_of(rx.problem)
    local title = problem and present(problem.title)
    if type(title) == "string" and title ~= "" then return title end
    if type(detail) == "string" and detail ~= "" then return detail end
    return tostring(status)
  end
  if status == 204 and type(detail) == "string" and M.receipt_count(entry) == nil then return detail end
  return nil
end

-- A started execution's row carries its stream address (`attrs.stream`); the row appears
-- when that stream concludes ({§nvim-waterfall-turns}).
M.stream_address = function(entry)
  local attrs = M.object_of(entry.attrs)
  local stream = attrs and present(attrs.stream)
  if type(stream) == "string" and stream ~= "" then return stream end
  return nil
end

-- A glob READ's rows carry `attrs.fanout = { target, matched, index, count }`.
M.fanout_of = function(entry)
  local attrs = M.object_of(entry.attrs)
  local fanout = attrs and M.object_of(attrs.fanout)
  if fanout == nil then return nil end
  if type(present(fanout.target)) ~= "string" or type(present(fanout.matched)) ~= "number"
      or type(present(fanout.index)) ~= "number" or type(present(fanout.count)) ~= "number" then
    return nil
  end
  return { target = fanout.target, matched = fanout.matched, index = fanout.index, count = fanout.count }
end

-- An execution's op is its lowercase runtime tag (plurnk-service#659); the engine's own
-- lowercase row ops are not executions.
M.is_execution = function(op)
  return type(op) == "string" and op:match("^[a-z]") ~= nil and op ~= "prompt" and op ~= "extension" and op ~= "error"
end

M.is_disposition = function(op)
  return op == "TASK"
end

M.is_response_message = function(entry)
  return entry.op == "SEND" and entry.origin == "model"
    and type(entry.status_rx) == "number" and entry.status_rx >= 200 and entry.status_rx < 300
    and present(entry.source) == nil and entry.inherited_history ~= 1
    and present(entry.scheme) == nil and present(entry.pathname) == nil
end

M.is_broadcast = function(entry)
  return entry.op == "SEND" and present(entry.scheme) == nil and present(entry.pathname) == nil
end

-- The user's prompt is conversation, not an op record. It arrives as an
-- actionless lowercase prompt row with its body in rx.content.
M.is_prompt_entry = function(entry)
  return entry.op == "prompt" and entry.scheme == "prompt"
end

-- ── Styled text ─────────────────────────────────────────────────────────

-- Highlight groups, converged with the terminal client's palette: bold green for a
-- successful operation, pink for anything unsuccessful, dim italic for an aside, grey for
-- a row whose outcome is not yet known. Defaults only; a colorscheme may override.
M.setup_highlights = function()
  local groups = {
    PlurnkOp = { fg = "#87d787", bold = true },
    PlurnkOpFailed = { fg = "#ff87ff", bold = true },
    PlurnkFailure = { fg = "#ff87ff" },
    PlurnkDetail = { link = "Comment" },
    PlurnkAside = { fg = "#8a8a8a", italic = true },
    PlurnkPending = { link = "Comment" },
    PlurnkTableBorder = { fg = "#87d787" },
    PlurnkTaskHead = { bold = true },
    PlurnkTaskCompleted = { fg = "#87d787" },
    PlurnkTaskFailed = { fg = "#ff87ff" },
    PlurnkAnswer = { bold = true },
  }
  for name, spec in pairs(groups) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

-- One line assembled from space-separated pieces, each optionally highlighted.
local function styled_line()
  local text, spans = "", {}
  local function push(piece, group)
    if text ~= "" then text = text .. " " end
    local start = #text
    text = text .. piece
    if group ~= nil then spans[#spans + 1] = { start, #text, group } end
  end
  local function done() return text, spans end
  return push, done
end

local function block_of(text, spans, fold_label)
  local highlights = {}
  for _, span in ipairs(spans) do highlights[#highlights + 1] = { 1, span[1], span[2], span[3] } end
  return { lines = { text }, highlights = highlights, fold_label = fold_label }
end

-- `OP (target) <scope> /pattern/ {n} aside — problem title`, one line, literal text.
-- An override carries facts the wire settled elsewhere than on this entry: a collapsed
-- fan-out (target, count) or a concluded execution (failed, failure); `settled` says the
-- outcome is the override's, not the row's.
M.operation_row = function(entry, override)
  override = override or {}
  local failed = override.failed
  if failed == nil then failed = override.failure ~= nil or status_of(entry) >= 400 end
  local push, done = styled_line()
  push(plain(entry.op), failed and "PlurnkOpFailed" or "PlurnkOp")
  local tx = M.object_of(entry.tx)
  if entry.op == "COPY" or entry.op == "MOVE" then
    for _, side in ipairs({ "source", "destination" }) do
      local operand = selection_text(tx and tx[side])
      if operand ~= nil then push(plain(operand)) end
    end
  else
    local target = override.target or M.authored_target(entry)
    if target ~= nil then push("(" .. plain(target) .. ")") end
    local scope = M.entry_scope(entry)
    if scope ~= nil then push(scope) end
    local pattern = M.authored_pattern(entry)
    if pattern ~= nil then push(plain(pattern)) end
  end
  local count = override.count
  if count == nil then count = M.receipt_count(entry) end
  if count ~= nil then push("{" .. tostring(count) .. "}") end
  local aside = M.entry_aside(entry)
  if aside ~= nil then push(aside, "PlurnkAside") end
  local outcome = override.failure
  if outcome == nil and not override.settled then outcome = M.outcome_title(entry) end
  if outcome ~= nil then push("— " .. plain(outcome), failed and "PlurnkFailure" or "PlurnkDetail") end
  return done()
end

-- An execution still open when the following turn begins, or hydrated from history where
-- the row carries no conclusion: the row once, in grey, with no outcome.
M.render_pending_block = function(entry)
  local text = M.operation_row(entry, { failed = false, settled = true })
  return block_of(text, { { 0, #text, "PlurnkPending" } })
end

-- The daemon's summary leads with the target; the remainder is the outcome in its words.
M.summary_tail = function(params)
  local summary = tostring(present(params.summary) or "")
  local target = tostring(present(params.target) or "")
  if target ~= "" and summary:sub(1, #target) == target then summary = summary:sub(#target + 1) end
  local tail = summary:gsub("^%s+", "")
  return tail
end

M.conclusion_override = function(params)
  local result = M.object_of(params.result) or {}
  local status = type(present(result.status)) == "number" and result.status or 0
  local failed = status ~= 200
  local failure = nil
  if failed then
    local problem = M.object_of(result.problem)
    local title = problem and present(problem.title)
    if type(title) == "string" and title ~= "" then
      failure = title
    else
      local tail = M.summary_tail(params)
      failure = tail ~= "" and tail or tostring(status)
    end
  end
  return { failed = failed, failure = failure, settled = true }
end

-- One row per execution, at its conclusion: the launching fence when it is known, the
-- stream's own scheme and address otherwise ({§nvim-waterfall-turns}).
M.render_execution_block = function(launch, params)
  local override = M.conclusion_override(params)
  if launch ~= nil then
    local text, spans = M.operation_row(launch, override)
    return block_of(text, spans)
  end
  local push, done = styled_line()
  push(plain(present(params.scheme) or ""), override.failed and "PlurnkOpFailed" or "PlurnkOp")
  push("(" .. plain(present(params.target) or "") .. ")")
  if override.failure ~= nil then push("— " .. plain(override.failure), "PlurnkFailure") end
  local text, spans = done()
  return block_of(text, spans)
end

-- The lead line of a TASK or SEND block: no keyword. A blank line stands where the keyword
-- was; a failure puts its Problem title there in pink, a deferred or joined completion its
-- `detail`; the sanitized aside follows either.
local function lead_line(entry, detail)
  local push, done = styled_line()
  local rx = M.object_of(entry.rx)
  local status = status_of(entry)
  local words = rx and present(rx.detail)
  if status >= 400 then
    push(plain(M.outcome_title(entry) or tostring(status)), "PlurnkFailure")
  elseif detail and status ~= 200 and type(words) == "string" and words ~= "" then
    push(plain(words))
  end
  local aside = M.entry_aside(entry)
  if aside ~= nil then push(aside, "PlurnkAside") end
  return done()
end

-- ── TASK ────────────────────────────────────────────────────────────────

local PLAN_STATUS_ORDER = { "todo", "in_progress", "waiting", "completed", "failed" }
local ACP_STATUS = { completed = true, in_progress = true, pending = true }
local STATUS_TINT = { completed = "PlurnkTaskCompleted", failed = "PlurnkTaskFailed" }

local function plan_entry(entry)
  if type(entry) ~= "table" or not ACP_STATUS[entry.status] or type(entry.content) ~= "string" then
    error("TASK row carries a noncanonical Plan entry")
  end
  if entry.priority ~= "medium" and entry.priority ~= "high" and entry.priority ~= "low" then
    error("TASK row carries a noncanonical ACP Plan priority")
  end
  local meta = M.object_of(entry._meta)
  local subtype = meta and meta["plurnk.xyz/status"] or nil
  local status = entry.status == "pending" and "todo" or entry.status
  if subtype == "waiting" and entry.status == "in_progress" then status = "waiting" end
  if subtype == "failed" and entry.status == "completed" then status = "failed" end
  local content = entry.content:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if entry.priority ~= "medium" then content = "[" .. entry.priority .. "] " .. content end
  return status, content
end

-- The inventory as status columns: the native statuses present, in the stable order
-- `todo`, `in_progress`, `waiting`, `completed`, `failed`; each column's entries in source order.
M.plan_columns = function(tx)
  local body = M.object_of(tx)
  body = body and M.object_of(body.body)
  if body == nil or type(present(body.entries)) ~= "table" then
    error("TASK row must carry its canonical Plan body")
  end
  local buckets = {}
  for _, entry in ipairs(body.entries) do
    local status, content = plan_entry(entry)
    buckets[status] = buckets[status] or {}
    table.insert(buckets[status], content)
  end
  local columns = {}
  for _, status in ipairs(PLAN_STATUS_ORDER) do
    if buckets[status] ~= nil then columns[#columns + 1] = { status = status, entries = buckets[status] } end
  end
  return columns
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

-- Word-wrap a cell to its column; a word wider than the column is split by character.
local function wrap_cell(text, width)
  local lines, current = {}, ""
  for word in text:gmatch("%S+") do
    while display_width(word) > width do
      local head = ""
      for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if head ~= "" and display_width(head .. char) > width then break end
        head = head .. char
      end
      if current ~= "" then lines[#lines + 1] = current; current = "" end
      lines[#lines + 1] = head
      word = word:sub(#head + 1)
    end
    if word ~= "" then
      if current == "" then
        current = word
      elseif display_width(current .. " " .. word) <= width then
        current = current .. " " .. word
      else
        lines[#lines + 1] = current
        current = word
      end
    end
  end
  if current ~= "" or #lines == 0 then lines[#lines + 1] = current end
  return lines
end

-- A status-column table outlined in box drawing: only the columns with entries, a
-- `completed` column green and a `failed` column pink, wrapped to the live width.
local function box_table(columns, width)
  local usable = math.max(24, (width or 80) - 1)
  local per_column = math.max(8, math.floor(usable / #columns) - 3)
  local widths, cells = {}, {}
  for index, column in ipairs(columns) do
    local widest = display_width(column.status)
    for _, entry in ipairs(column.entries) do widest = math.max(widest, display_width(entry)) end
    widths[index] = math.min(per_column, widest)
    cells[index] = {}
    for row, entry in ipairs(column.entries) do cells[index][row] = wrap_cell(entry, widths[index]) end
  end
  local lines, highlights = {}, {}
  local function border(left, middle, right)
    local parts = {}
    for index = 1, #columns do parts[index] = string.rep("─", widths[index] + 2) end
    local text = left .. table.concat(parts, middle) .. right
    lines[#lines + 1] = text
    highlights[#highlights + 1] = { #lines, 0, #text, "PlurnkTableBorder" }
  end
  local function row(values, head)
    local line = #lines + 1
    local text = "│"
    highlights[#highlights + 1] = { line, 0, #text, "PlurnkTableBorder" }
    for index, column in ipairs(columns) do
      local value = values[index] or ""
      local start = #text + 1
      text = text .. " " .. value .. string.rep(" ", widths[index] - display_width(value)) .. " "
      if value ~= "" then
        local tint = STATUS_TINT[column.status]
        if tint ~= nil then highlights[#highlights + 1] = { line, start, start + #value, tint } end
        if head then highlights[#highlights + 1] = { line, start, start + #value, "PlurnkTaskHead" } end
      end
      local bar = #text
      text = text .. "│"
      highlights[#highlights + 1] = { line, bar, #text, "PlurnkTableBorder" }
    end
    lines[line] = text
  end
  border("┌", "┬", "┐")
  local heads = {}
  for index, column in ipairs(columns) do heads[index] = column.status end
  row(heads, true)
  border("├", "┼", "┤")
  local height = 0
  for index = 1, #columns do height = math.max(height, #columns[index].entries) end
  for entry = 1, height do
    local wrapped = 0
    for index = 1, #columns do
      if cells[index][entry] ~= nil then wrapped = math.max(wrapped, #cells[index][entry]) end
    end
    for line = 1, wrapped do
      local values = {}
      for index = 1, #columns do
        values[index] = cells[index][entry] ~= nil and cells[index][entry][line] or ""
      end
      row(values, false)
    end
  end
  border("└", "┴", "┘")
  return lines, highlights
end

-- TASK: the lead line, then the inventory table ({§nvim-waterfall-rows}). An empty inventory
-- is the lead line alone.
M.render_task = function(entry, width)
  local lead, spans = lead_line(entry, true)
  local block = block_of(lead, spans)
  local columns = M.plan_columns(entry.tx)
  local labels = {}
  for index, column in ipairs(columns) do labels[index] = column.status .. " " .. tostring(#column.entries) end
  block.fold_label = #labels > 0 and table.concat(labels, " · ") or lead
  if #columns == 0 then return block end
  local lines, highlights = box_table(columns, width)
  for _, line in ipairs(lines) do block.lines[#block.lines + 1] = line end
  for _, highlight in ipairs(highlights) do
    block.highlights[#block.highlights + 1] = { highlight[1] + 1, highlight[2], highlight[3], highlight[4] }
  end
  return block
end

-- ── SEND ────────────────────────────────────────────────────────────────

-- A common model-authored inline-math spelling with an exact editor glyph.
-- This is typographic normalization, not a claim of general LaTeX support.
local function normalize_prose(text)
  local normalized = text:gsub("%$\\rightarrow%$", "→")
  return normalized
end

M.send_body = function(entry)
  local tx = M.object_of(entry.tx)
  local body = tx and present(tx.body)
  local raw = ""
  if type(body) == "table" then
    raw = type(present(body.raw)) == "string" and body.raw or ""
  elseif type(body) == "string" then
    raw = body
  end
  return normalize_prose(raw)
end

local function first_prose_line(lines)
  for _, line in ipairs(lines) do
    local text = line:gsub("%s+$", "")
    if text ~= "" then return text end
  end
  return nil
end

-- Targetless SEND: the message block. The lead line, then the body at column zero; a
-- delivered response is bold. Markdown bodies project through the shared filter when the
-- caller gives a width ({§nvim-markdown-projection}).
M.render_send = function(entry, width, on_change)
  local lead, spans = lead_line(entry, false)
  local block = block_of(lead, spans)
  local body = M.send_body(entry)
  if body == "" then
    block.fold_label = lead
    return block
  end
  local body_lines
  if width ~= nil and require("plurnk.markdown").looks_like_markdown(body) then
    body_lines = require("plurnk.markdown").render(body, math.max(20, width), "", on_change).lines or {}
  else
    body_lines = vim.split(body, "\n", { plain = true })
    if body_lines[#body_lines] == "" then table.remove(body_lines) end
  end
  local answer = M.is_response_message(entry)
  for _, line in ipairs(body_lines) do
    block.lines[#block.lines + 1] = line
    if answer and line ~= "" then block.highlights[#block.highlights + 1] = { #block.lines, 0, #line, "PlurnkAnswer" } end
  end
  block.fold_label = first_prose_line(body_lines) or lead
  return block
end

-- Pure source projection used by renderer specs and non-waterfall callers.
M.render_broadcast = function(entry)
  return M.render_send(entry, nil, nil).lines
end

M.render_prompt = function(entry)
  local rx = M.object_of(entry.rx)
  local body = rx and present(rx.content)
  body = type(body) == "string" and body or ""
  local header = "❯"
  if body == "" then return { header } end
  if not body:find("\n", 1, true) then return { header .. " " .. body } end
  local lines = { header }
  for chunk in (body .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = "   " .. chunk end
  if lines[#lines] == "   " then table.remove(lines) end
  return lines
end

-- Provider reasoning is neither task inventory nor speech. Preserve its line structure
-- in one quiet block without inventing a log coordinate or status code.
M.render_reasoning = function(content)
  if type(content) ~= "string" or content == "" then return {} end
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = (#lines == 0 and "💭 " or "   ") .. line
  end
  return lines
end

-- A rendered waterfall block: a disposition renders its table, a targetless SEND its
-- block, a prompt its speech, every other operation one literal row. The caller owns the
-- source entry and may project it again at a different live window width.
M.render_log_block = function(entry, width, on_change, override)
  if M.is_disposition(entry.op) then return M.render_task(entry, width) end
  if M.is_broadcast(entry) then return M.render_send(entry, width, on_change) end
  if M.is_prompt_entry(entry) then
    local lines = M.render_prompt(entry)
    return { lines = lines, highlights = {}, fold_label = lines[1] }
  end
  local text, spans = M.operation_row(entry, override)
  return block_of(text, spans)
end

-- Lines only, at no particular width: the renderer's pure face.
M.render_log_entry = function(entry, override)
  return M.render_log_block(entry, nil, nil, override).lines
end

-- ── Diagnostics and summaries ───────────────────────────────────────────

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

-- Terminal loop status → label (converge client #70). 499 is the model/actor give-up or
-- external KILL/cancel; 413/429/500/508 are ENGINE verdicts.
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
