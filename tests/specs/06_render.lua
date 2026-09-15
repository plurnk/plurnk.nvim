-- -- Renderer unit test: every row is the operation as written, styled by highlight spans,
-- never a glyph column ({§nvim-waterfall-rows}). Pure module; no daemon required.
local NAME = "06_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local r = require("plurnk.render")
-- Every wire log entry carries the coordinate (#208); fixtures model wire
-- entries, so default the ordinals unless a test sets them explicitly.
local function R(t, override)
  t.loop_seq = t.loop_seq or 1
  t.turn_seq = t.turn_seq or 1
  t.sequence = t.sequence or 1
  return r.render_log_entry(t, override)
end
local function joined(lines) return table.concat(lines, "\n") end
local function groups(block, line)
  local names = {}
  for _, hl in ipairs(block.highlights) do
    if hl[1] == (line or 1) then names[#names + 1] = hl[4] end
  end
  return names
end
local function has_group(block, group, line)
  for _, name in ipairs(groups(block, line)) do
    if name == group then return true end
  end
  return false
end

local ok, err = pcall(function()
  -- ── Figures shared with the terminal client ─────────────────────────
  H.assert_eq(r.abbreviated_count(582300), "582k", "counts read at a glance")
  H.assert_eq(r.abbreviated_count(1234567), "1.2M", "millions keep one decimal")
  H.assert_eq(r.abbreviated_count(980), "980", "below a thousand, the number itself")
  H.assert_eq(r.abbreviated_count(nil), "?", "an unknown count is a question mark")
  H.assert_eq(r.money("3333.3333"), "3,333.3333", "spend groups thousands")
  H.assert_eq(r.money("0.024"), "0.0240", "spend to the hundredth of a cent")

  -- ── Operation rows: the authored heading as literal text ────────────
  H.assert_eq(R({ op = "READ", origin = "model", scheme = "known", pathname = "/x", status_rx = 200, rx = { content = "Paris" } })[1],
    "READ (known:///x)", "a row is the operation and its target; no glyph, no code, no preview")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/AGENTS.md", lineMarker = { marks = { 17, -1 } }, status_rx = 200,
    tx = { target = { raw = "AGENTS.md" } } })[1], "READ (AGENTS.md) <17,-1>", "the authored target text in its parentheses, then the canonical scope")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/plurnk-core/SPEC.md", status_rx = 200,
    tx = { target = { raw = "plurnk-core/SPEC.md" }, matcher = { raw = "/^#{1,2} /" } }, rx = { lineOrdinals = { 1, 5, 9 } } })[1],
    "READ (plurnk-core/SPEC.md) /^#{1,2} / {3}", "a pattern READ counts its matched lines; the pattern is not a heading")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/README.md", status_rx = 200,
    tx = { target = { raw = "README.md" } }, rx = { range = { returned = { 1, 40 } } } })[1], "READ (README.md) {40}", "an exact READ counts the lines it returned")
  H.assert_eq(R({ op = "FIND", origin = "model", scheme = nil, pathname = "/", status_rx = 200,
    tx = { target = { raw = "*.md" }, aside = "what the new package contains" }, rx = { range = { returned = { 1, 7 }, total = 7 } } })[1],
    "FIND (*.md) {7} what the new package contains", "a FIND counts its returned items; the aside follows as literal text; *.md is not emphasis")
  H.assert_eq(R({ op = "FIND", origin = "model", scheme = nil, pathname = "/", status_rx = 204,
    tx = { target = { raw = "src/**/*.ts" } }, rx = { range = { total = 0 }, detail = "No entry matched." } })[1], "FIND (src/**/*.ts) {0}", "a 204 FIND is {0}, not a failure")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/pets_*.md", status_rx = 204,
    tx = { target = { raw = "pets_*.md" } }, rx = { detail = "No path matched pets_*.md" } })[1],
    "READ (pets_*.md) — No path matched pets_*.md", "a glob READ that matched nothing carries the daemon's detail")
  local failed = r.render_log_block({ op = "READ", origin = "model", scheme = nil, pathname = "/plurnk-parser/README.md", lineMarker = { marks = { 1, -1 } },
    status_rx = 404, tx = { target = { raw = "plurnk-parser/README.md" } }, rx = { status = 404, problem = { type = "x", title = "Entry not member", status = 404 } } })
  H.assert_eq(failed.lines[1], "READ (plurnk-parser/README.md) <1,-1> — Entry not member", "an unsuccessful outcome names the Problem title at the right")
  H.assert_truthy(has_group(failed, "PlurnkOpFailed"), "the op of a failed row is pink")
  H.assert_truthy(has_group(failed, "PlurnkFailure"), "the failure text is pink")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/x", status_rx = 500, tx = { target = { raw = "x" } }, rx = { detail = "exploded" } })[1],
    "READ (x) — exploded", "without a title, the detail; without either, the bare status")
  local plain = r.render_log_block({ op = "EDIT", origin = "model", scheme = "worker", pathname = "/manifest.json", status_rx = 201, tx = { body = "{}" } })
  H.assert_eq(plain.lines[1], "EDIT (worker:///manifest.json)", "an EDIT row carries no body")
  H.assert_truthy(has_group(plain, "PlurnkOp"), "the op of a successful row is green")
  local with_aside = r.render_log_block({ op = "sh", origin = "model", status_rx = 200, tx = { runtime = "sh", aside = "Lists **issues**\27[31m", body = "{}" } })
  H.assert_eq(with_aside.lines[1], "sh Lists **issues**", "an execution row is its runtime and its aside as literal text, control sequences stripped")
  H.assert_truthy(has_group(with_aside, "PlurnkAside"), "the aside is styled, never interpreted")
  H.assert_eq(R({ op = "COPY", origin = "model", scheme = "worker", pathname = "/source", status_rx = 200,
    tx = { source = { target = { raw = "worker:///source" }, lineMarker = { marks = { 3, 9 } } }, destination = { target = { raw = "worker:///destination" } } } })[1],
    "COPY (worker:///source) <3,9> (worker:///destination)", "COPY names both operands, each scope beside its own path")
  H.assert_eq(R({ op = "MOVE", origin = "model", scheme = "worker", pathname = "/source", status_rx = 200, tx = {} })[1], "MOVE", "an operand-less transfer invents nothing")
  for _, op in ipairs({ "KILL", "WORK", "FORK" }) do
    H.assert_eq(R({ op = op, origin = "model", scheme = "worker", hostname = "reviewer", pathname = "/", status_rx = 200, tx = {}, rx = { status = 200 } })[1],
      op .. " (worker://reviewer/)", op .. " names its worker")
  end
  local coorded = R({ op = "READ", origin = "model", scheme = "known", pathname = "/x", status_rx = 200,
    loop_seq = 1, turn_seq = 2, sequence = 3, loop_id = 38, turn_id = 412, tx = {}, rx = {} })
  H.assert_truthy(not coorded[1]:match("01/02/03") and not coorded[1]:match("38/412"), "no coordinate gutter on human rows")
  H.assert_eq(R({ op = "SEND", origin = "model", scheme = "worker", pathname = "/child", status_rx = 200, signal = 200,
    tx = { target = { raw = "worker:///child" }, body = { raw = "Continue." } } })[1], "SEND (worker:///child)", "a directed SEND is a row, its body unshown")
  H.assert_eq(R({ op = "SEND", origin = "model", scheme = "worker", pathname = "/gone", status_rx = 410, signal = 410,
    tx = { target = { raw = "worker:///gone" }, body = { raw = "Gone." } }, rx = { problem = { title = "Worker gone" } } })[1],
    "SEND (worker:///gone) — Worker gone", "a failed directed SEND names its Problem")

  -- ── Executions: one row at the conclusion; grey while open ──────────
  local launch = { op = "sh", origin = "model", status_rx = 200, loop_seq = 1, turn_seq = 1, sequence = 8,
    tx = { runtime = "sh", aside = "list the files" }, rx = { status = 200, outcome = "started" }, attrs = { runtime = "sh", stream = "sh:///1a2b3c4d" } }
  H.assert_eq(r.stream_address(launch), "sh:///1a2b3c4d", "a started execution carries its stream address")
  H.assert_eq(r.stream_address({ op = "sh", origin = "model", status_rx = 501, tx = { runtime = "sh" }, attrs = { runtime = "sh" } }), nil,
    "an execution the daemon refused carries no stream")
  local concluded = r.render_execution_block(launch, { entryId = 8, workerId = 7, target = "sh:///1a2b3c4d", scheme = "sh",
    result = { status = 200 }, summary = "sh:///1a2b3c4d completed (exit 0)" })
  H.assert_eq(concluded.lines[1], "sh list the files", "a concluded execution is its fence, once, with no outcome text")
  H.assert_truthy(has_group(concluded, "PlurnkOp"), "a successful conclusion is green")
  local crashed = r.render_execution_block(launch, { target = "sh:///1a2b3c4d", scheme = "sh",
    result = { status = 500, problem = { title = "Command failed" } }, summary = "sh:///1a2b3c4d failed (exit 2)" })
  H.assert_eq(crashed.lines[1], "sh list the files — Command failed", "a failed conclusion names the Problem title")
  H.assert_truthy(has_group(crashed, "PlurnkOpFailed"), "a failed conclusion is pink")
  local summarized = r.render_execution_block(launch, { target = "sh:///1a2b3c4d", scheme = "sh",
    result = { status = 500 }, summary = "sh:///1a2b3c4d failed (exit 2); stderr=41 bytes" })
  H.assert_eq(summarized.lines[1], "sh list the files — failed (exit 2); stderr=41 bytes", "without a title, the summary's own words after the target")
  local orphan = r.render_execution_block(nil, { target = "python:///0c0ffee1", scheme = "python",
    result = { status = 500 }, summary = "python:///0c0ffee1 failed (exit 2)" })
  H.assert_eq(orphan.lines[1], "python (python:///0c0ffee1) — failed (exit 2)", "a conclusion whose launch was never seen is its scheme and address")
  local pending = r.render_pending_block(launch)
  H.assert_eq(pending.lines[1], "sh list the files", "a pending row is the fence with no outcome")
  H.assert_eq(groups(pending)[1], "PlurnkPending", "and it is grey")
  H.assert_eq(#pending.highlights, 1, "grey replaces every other style on a pending row")

  -- ── Fan-out facts ride attrs ─────────────────────────────────────────
  H.assert_eq(r.fanout_of({ attrs = { fanout = { target = "pets_*.md", matched = 3, index = 2, count = 3 } } }).count, 3, "fanout is read from the wire")
  H.assert_eq(r.fanout_of({ attrs = { fanout = { target = "pets_*.md" } } }), nil, "a partial fanout is no fanout")
  H.assert_eq(R({ op = "READ", origin = "model", scheme = nil, pathname = "/pets_b.md", status_rx = 200,
    tx = { target = { raw = "pets_*.md" } }, rx = { range = { returned = { 1, 12 } } },
    attrs = { fanout = { target = "pets_*.md", matched = 3, index = 2, count = 3 } } },
    { target = "pets_*.md", count = 3, failed = false, settled = true })[1], "READ (pets_*.md) {3}", "a collapsed glob READ counts the paths it read")

  -- ── TASK: the lead line, then the inventory as a status-column table ─
  local task = r.render_log_block({ op = "TASK", origin = "model", status_rx = 102, signal = 102, loop_seq = 1, turn_seq = 1, sequence = 9,
    tx = { body = { entries = {
      { content = "Contract settled.", priority = "medium", status = "completed" },
      { content = "Memory: One baseline owns the schema.", priority = "medium", status = "completed" },
      { content = "Update\nclients.", priority = "high", status = "in_progress" },
      { content = "Run drills.", priority = "low", status = "pending" },
      { content = "Waiting: Child results", priority = "medium", status = "in_progress", _meta = { ["plurnk.xyz/status"] = "waiting" } },
      { content = "Failed: Command failed", priority = "medium", status = "completed", _meta = { ["plurnk.xyz/status"] = "failed" } },
    } } } }, 240)
  H.assert_eq(task.lines[1], "", "a routine TASK leads with a blank line: no keyword, no glyph, no code")
  H.assert_match(task.lines[2], "^┌", "the inventory is outlined")
  H.assert_match(task.lines[3], "^│ todo +│ in_progress +│ waiting +│ completed +│ failed +│$",
    "columns are the statuses present, in the stable order, pending shown as todo")
  H.assert_match(task.lines[5], "%[low%] Run drills%.", "a low priority renders as [low]")
  H.assert_match(task.lines[5], "%[high%] Update clients%.", "entry whitespace collapses to one line; high renders as [high]")
  H.assert_match(task.lines[5], "Waiting: Child results", "waiting keeps its visible label")
  H.assert_match(task.lines[5], "Failed: Command failed", "failed keeps its visible label")
  H.assert_match(task.lines[5], "Contract settled%.", "the first completed entry")
  H.assert_match(task.lines[6], "Memory: One baseline owns the schema%.", "the second completed entry, source order")
  H.assert_eq(#task.lines, 7, "lead, outline, head, rule, two entry rows, outline")
  H.assert_match(task.lines[7], "^└", "the table closes")
  H.assert_truthy(has_group(task, "PlurnkTableBorder", 2), "the outline is green")
  H.assert_truthy(has_group(task, "PlurnkTaskCompleted", 3), "a completed column's head is green")
  H.assert_truthy(has_group(task, "PlurnkTaskFailed", 3), "a failed column's head is pink")
  H.assert_truthy(has_group(task, "PlurnkTaskHead", 3), "heads are bold")
  H.assert_truthy(has_group(task, "PlurnkTaskCompleted", 6), "a completed column's entries are green")
  H.assert_eq(task.fold_label, "todo 1 · in_progress 1 · waiting 1 · completed 2 · failed 1", "a folded inventory names its columns")
  H.assert_truthy(not joined(task.lines):match("✅") and not joined(task.lines):match("🚧") and not joined(task.lines):match("▶️"), "no entry or lifecycle glyphs")
  local deferred = r.render_log_block({ op = "TASK", origin = "model", status_rx = 202,
    tx = { aside = "all done", body = { entries = { { content = "Compose.", priority = "medium", status = "completed" } } } },
    rx = { status = 202, detail = "Completion deferred: 1 operation failed in the same turn" } }, 80)
  H.assert_eq(deferred.lines[1], "Completion deferred: 1 operation failed in the same turn all done", "a deferral states the receipt's detail, then the aside")
  H.assert_truthy(has_group(deferred, "PlurnkAside"), "the aside on the lead line is styled")
  local refused = r.render_log_block({ op = "TASK", origin = "model", status_rx = 400, tx = { body = { entries = {} } },
    rx = { status = 400, problem = { title = "Disposition rejected" } } }, 80)
  H.assert_eq(refused.lines[1], "Disposition rejected", "an unsuccessful TASK puts its Problem title on the lead line")
  H.assert_truthy(has_group(refused, "PlurnkFailure"), "in pink")
  H.assert_eq(#refused.lines, 1, "an empty inventory is the lead line alone")
  H.assert_eq(#r.render_log_block({ op = "TASK", origin = "_plurnk", status_rx = 102,
    tx = { body = { entries = { { content = "Address the prompt.", priority = "medium", status = "pending" } } } } }, 80).lines, 6,
    "runtime inventory follows the same projection")
  H.assert_truthy(not pcall(R, { op = "TASK", origin = "model", status_rx = 102,
    tx = { body = { entries = { { content = "Internal memory", priority = "medium", status = "memory" } } } } }), "the client rejects non-ACP task statuses")
  local narrow = r.render_log_block({ op = "TASK", origin = "model", status_rx = 102,
    tx = { body = { entries = { { content = "A rather long inventory entry that will not fit in a narrow column", priority = "medium", status = "in_progress" } } } } }, 30)
  H.assert_truthy(#narrow.lines > 6, "entries wrap to the live width")
  for _, line in ipairs(narrow.lines) do
    H.assert_truthy(vim.fn.strdisplaywidth(line) <= 30, "no table line exceeds the width: " .. line)
  end

  -- ── SEND: the lead line, then the body at column zero ───────────────
  H.assert_eq(joined(R({ op = "SEND", origin = "model", status_rx = 200, tx = { body = { raw = "Update." } } })), "\nUpdate.",
    "a delivered message is its body under a blank lead line")
  local answer = r.render_log_block({ op = "SEND", origin = "model", status_rx = 200, tx = { body = { raw = "hi\nthere" } } })
  H.assert_eq(joined(answer.lines), "\nhi\nthere", "body lines stay at column zero")
  H.assert_truthy(has_group(answer, "PlurnkAnswer", 2) and has_group(answer, "PlurnkAnswer", 3), "a delivered response is bold")
  H.assert_eq(answer.fold_label, "hi", "a folded message names its first line of prose")
  H.assert_eq(joined(R({ op = "SEND", origin = "model", status_rx = 200, tx = { aside = "Answer ready", body = { raw = "Paris" } } })), "Answer ready\nParis",
    "the aside stands on the lead line")
  H.assert_eq(joined(R({ op = "SEND", origin = "model", status_rx = 400, tx = { body = { raw = "Undelivered." } }, rx = { problem = { title = "Not delivered" } } })),
    "Not delivered\nUndelivered.", "a failed message puts its Problem title on the lead line")
  H.assert_eq(joined(R({ op = "SEND", origin = "model", status_rx = 200 })), "", "empty message content is the lead line alone")
  H.assert_match(R({ op = "SEND", origin = "model", status_rx = 200, tx = { body = { raw = "loading $\\rightarrow$ running" } } })[2], "loading → running",
    "inline right arrow uses its editor glyph")
  H.assert_match(joined(R({ op = "SEND", origin = "model", status_rx = 200, tx = { body = { raw = "before\n```mermaid\ngraph TD\n  a --> b\n```\nafter" } } })),
    "```mermaid", "the pure renderer retains Mermaid source")
  local inherited = r.render_log_block({ op = "SEND", origin = "model", status_rx = 200, inherited_history = 1, tx = { body = { raw = "old" } } })
  H.assert_truthy(not has_group(inherited, "PlurnkAnswer", 2), "an inherited message is not this run's response")

  H.assert_truthy(r.is_response_message({ op = "SEND", origin = "model", status_rx = 200 }), "own delivered SEND is a response")
  for _, row in ipairs({
    { op = "TASK", origin = "model", status_rx = 200 },
    { op = "SEND", origin = "_plurnk", status_rx = 200 },
    { op = "SEND", origin = "model", status_rx = 400 },
    { op = "SEND", origin = "model", status_rx = 200, source = 9 },
    { op = "SEND", origin = "model", status_rx = 200, inherited_history = 1 },
    { op = "SEND", origin = "model", status_rx = 200, scheme = "worker", pathname = "/" },
  }) do H.assert_truthy(not r.is_response_message(row), "not an own delivered response: " .. vim.inspect(row)) end

  -- ── Prompt, reasoning, summary: unchanged lanes ─────────────────────
  H.assert_eq(R({ op = "prompt", origin = "_plurnk", scheme = "prompt", pathname = "/3/1", status_rx = 200,
    rx = { content = "What is the capital of France?" } })[1], "❯ What is the capital of France?", "durable prompt uses a neutral user marker")
  local long_prompt = R({ op = "prompt", origin = "_plurnk", scheme = "prompt", pathname = "/3/1", status_rx = 200, rx = { content = "line one\nline two" } })
  H.assert_eq(#long_prompt, 3, "multi-line prompt = header + body lines")
  local reasoning = r.render_reasoning("first line\nsecond line")
  H.assert_eq(reasoning[1], "💭 first line", "reasoning has its own compact identity")
  H.assert_eq(reasoning[2], "   second line", "continuation aligns below reasoning content")
  H.assert_match(r.render_summary(3, 850, 200, 200, false), "done", "summary tag")
  H.assert_match(r.render_summary(3, 1500, 200, 200, false), "1.50s", "summary seconds")
  H.assert_match(r.render_summary(5, 100, 200, 200, true), "maxTurns", "summary maxTurns")
  H.assert_eq(r.terminal_status_label(413), "budget overflow", "413 → budget overflow")
  H.assert_eq(r.terminal_status_label(429), "turn ceiling", "429 → turn ceiling")
  H.assert_eq(r.terminal_status_label(499), "cancelled", "499 → cancelled")
  H.assert_eq(r.terminal_status_label(500), "strike-out", "500 → strike-out")
  H.assert_eq(r.terminal_status_label(508), "loop detected", "508 → loop detected")
  H.assert_eq(r.terminal_status_label(418), "final 418", "unmapped → final N")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
