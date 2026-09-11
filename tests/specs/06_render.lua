-- -- Renderer unit test: every op type produces the right glyph layout.
-- Pure module; no daemon required.
local NAME = "06_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local r = require("plurnk.render")
-- Every wire log entry carries the coordinate (#208); fixtures model wire
-- entries, so default the ordinals unless a test sets them explicitly.
local function R(t)
  t.loop_seq = t.loop_seq or 1
  t.turn_seq = t.turn_seq or 1
  t.sequence = t.sequence or 1
  return r.render_log_entry(t)
end
local ok, err = pcall(function()
  for _, case in ipairs({
    { 102, "▶️", "in_progress", "🚧" }, { 202, "💤", "in_progress", "💤", "waiting" },
    { 200, "⏹️", "completed", "✅" }, { 499, "✋", "completed", "✋", "failed" },
  }) do
    local body = { entries = { { content = "Update.", priority = "medium", status = case[3], _meta = { ["plurnk.xyz/status"] = case[5] } } } }
    local lines = R({ op = "TASK", origin = "model", status_rx = case[1], signal = case[1], tx = { body = body } })
    H.assert_eq(lines[1], case[2], "TASK carries its lifecycle")
    H.assert_eq(lines[2]:sub(1, #case[4]), case[4], "TASK carries the native entry status through ACP")
  end
  H.assert_eq(R({ op = "SEND", origin = "model", status_rx = 200, tx = { body = { raw = "Update." } } })[1], "💬 Update.", "SEND remains messaging")
  H.assert_eq(R({ op = "SEND", origin = "model", status_rx = 400, tx = { body = { raw = "Undelivered." } } })[1],
    "💬 ❌ 400 Undelivered.", "an unsuccessful targetless SEND retains its diagnostic status")
  local reasoning = r.render_reasoning("first line\nsecond line")
  H.assert_eq(#reasoning, 2, "reasoning preserves its line structure")
  H.assert_eq(reasoning[1], "💭 first line", "reasoning has its own compact identity")
  H.assert_eq(reasoning[2], "   second line", "continuation aligns below reasoning content")

  -- READ with content extra; routine 200 carries no code.
  local read_lines = R({
    op = "READ", origin = "model", scheme = "known", pathname = "/x",
    status_rx = 200, rx = { content = "Paris" },
  })
  H.assert_eq(#read_lines, 1, "READ single line")
  H.assert_match(read_lines[1], "📖", "READ glyph")
  H.assert_truthy(not read_lines[1]:match("200"), "a routine non-SEND success shows no status code")
  H.assert_match(read_lines[1], "Paris", "READ content")
  -- No leading indent
  H.assert_truthy(read_lines[1]:sub(1, 1) ~= " ", "no leading indent")

  -- EXEC: the authored executor slot renders as [executor]; failure → ❌.
  local exec_lines = R({
    op = "EXEC", origin = "model", scheme = "exec", pathname = "/1/1/2/EXEC",
    status_rx = 501,
    tx = { executor = "search", body = "capital of France" },
  })
  H.assert_eq(#exec_lines, 1, "EXEC single line")
  H.assert_match(exec_lines[1], "🔧", "EXEC glyph")
  H.assert_match(exec_lines[1], "❌", "EXEC ❌ on 5xx")
  H.assert_match(exec_lines[1], "%[search%]", "EXEC shows executor in brackets")
  H.assert_match(exec_lines[1], "capital of France", "EXEC shows command body")

  local with_aside = R({
    op = "EXEC", origin = "model", status_rx = 200,
    tx = { aside = "Lists **issues**\27[31m", body = "{}" },
  })
  H.assert_match(with_aside[1], "— Lists %*%*issues%*%*", "aside renders as literal plain text")
  H.assert_truthy(not with_aside[1]:match("%[31m"), "aside strips terminal control sequences")

  -- FIND with count
  local find_lines = R({
    op = "FIND", origin = "model", scheme = "known", pathname = "/**",
    status_rx = 200, rx = { results = { { pathname = "/a" }, { pathname = "/b" }, { pathname = "/c" } } },
  })
  H.assert_match(find_lines[1], "🔍", "FIND glyph")
  H.assert_match(find_lines[1], "→ 3 results", "FIND counts the current array result shape")

  local copy_lines = R({
    op = "COPY", origin = "model", scheme = "worker", pathname = "/source",
    status_rx = 200,
    tx = { destination = { target = { raw = "worker:///destination" } } },
  })
  H.assert_match(copy_lines[1], "📋", "COPY glyph")
  H.assert_match(copy_lines[1], "→ worker:///destination", "COPY names its destination operand")

  local incomplete_move = R({
    op = "MOVE", origin = "model", scheme = "worker", pathname = "/source",
    status_rx = 200, tx = {},
  })
  H.assert_match(incomplete_move[1], "📦", "MOVE glyph")
  H.assert_truthy(not incomplete_move[1]:match("deleted"),
    "an invalid transfer invents no retired destination-body semantics")

  -- TASK → lifecycle header followed by one line per canonical inventory entry.
  local plan_lines = R({
    op = "TASK", origin = "model", scheme = nil, pathname = nil,
    status_rx = 102,
    tx = { body = { entries = {
      { content = "Contract settled.", priority = "medium", status = "completed" },
      { content = "Memory: One baseline owns the schema.", priority = "medium", status = "completed" },
      { content = "Update\nclients.", priority = "high", status = "in_progress" },
      { content = "Run drills.", priority = "low", status = "pending" },
    } } },
  })
  H.assert_eq(#plan_lines, 5, "continuation has a header and one line per entry")
  H.assert_eq(plan_lines[1], "▶️", "continuation header owns its lifecycle")
  H.assert_eq(plan_lines[2], "✅ Contract settled.", "completed entry owns its line — no coordinate, no routine code")
  H.assert_eq(plan_lines[3], "✅ Memory: One baseline owns the schema.", "content cannot change a task's status or lose a prefix")
  H.assert_eq(plan_lines[4], "🚧 [high] Update clients.", "in-progress entry aligns below it")
  H.assert_eq(plan_lines[5], "⬜ [low] Run drills.", "pending entry aligns below it")
  H.assert_truthy(not table.concat(plan_lines, "\n"):match("🧠"), "structured PLAN has no opaque brain glyph")
  H.assert_eq(vim.fn.strdisplaywidth("✅"), 2, "completed glyph is width-stable")
  H.assert_eq(vim.fn.strdisplaywidth("🚧"), 2, "in-progress glyph is width-stable")
  H.assert_eq(vim.fn.strdisplaywidth("⬜"), 2, "pending glyph is width-stable")

  local literal_content = R({
    op = "TASK", origin = "model", scheme = nil, pathname = nil,
    status_rx = 102,
    tx = { body = { entries = {
      { content = "Memory: One baseline owns the schema.", priority = "medium", status = "completed" },
    } } },
  })
  H.assert_eq(literal_content[2], "✅ Memory: One baseline owns the schema.",
    "the client preserves literal task content")

  local native_statuses = R({ op = "TASK", origin = "model", status_rx = 102, tx = { body = { entries = {
    { content = "Waiting: Child results", priority = "medium", status = "in_progress", _meta = { ["plurnk.xyz/status"] = "waiting" } },
    { content = "Failed: Command failed", priority = "high", status = "completed", _meta = { ["plurnk.xyz/status"] = "failed" } },
    { content = "Failed: is literal prose", priority = "medium", status = "completed" },
  } } } })
  H.assert_eq(native_statuses[2], "💤 Waiting: Child results", "waiting remains waiting")
  H.assert_eq(native_statuses[3], "✋ [high] Failed: Command failed", "failed is never presented as successfully completed")
  H.assert_eq(native_statuses[4], "✅ Failed: is literal prose", "content does not infer a subtype")
  H.assert_truthy(r.is_response_message({ op = "SEND", origin = "model", status_rx = 200 }), "own delivered SEND is a response")
  for _, row in ipairs({
    { op = "TASK", origin = "model", status_rx = 200 },
    { op = "SEND", origin = "_plurnk", status_rx = 200 },
    { op = "SEND", origin = "model", status_rx = 400 },
    { op = "SEND", origin = "model", status_rx = 200, source = 9 },
    { op = "SEND", origin = "model", status_rx = 200, inherited_history = 1 },
    { op = "SEND", origin = "model", status_rx = 200, scheme = "worker", pathname = "/" },
  }) do H.assert_truthy(not r.is_response_message(row), "not an own delivered response: " .. vim.inspect(row)) end

  H.assert_truthy(not pcall(R, {
    op = "TASK", origin = "model", scheme = nil, pathname = nil,
    status_rx = 102,
    tx = { body = { entries = {
      { content = "Internal memory", priority = "medium", status = "memory" },
    } } },
  }), "the client rejects non-ACP task statuses")

  local empty_plan = R({
    op = "TASK", origin = "model", scheme = nil, pathname = nil,
    status_rx = 102, tx = { body = { entries = {} } },
  })
  H.assert_eq(empty_plan[1], "▶️", "empty continuation retains its lifecycle")
  H.assert_eq(empty_plan[2], "📭 no entries", "empty inventory remains visible without coordinate or routine code")

  local bare_lines = R({
    op = "BARE", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200,
  })
  H.assert_eq(vim.fn.strdisplaywidth("🔮"), 2, "BARE glyph occupies one stable terminal cell pair")
  H.assert_match(bare_lines[1], "🔮", "BARE has an isolated-inference glyph")
  H.assert_truthy(not bare_lines[1]:match("%?"), "BARE is not the unknown-op fallback")
  for op, glyph in pairs({ KILL = "✂️", WORK = "🐜", FORK = "👥" }) do
    local lines = r.render_log_entry({
      op = op, origin = "model", scheme = "worker", hostname = "reviewer", pathname = "/",
      status_rx = 200, tx = {}, rx = { status = 200 },
    })
    H.assert_eq(lines[1]:sub(1, #glyph), glyph, op .. " owns its glyph instead of the unknown-op fallback")
    H.assert_eq(vim.fn.strdisplaywidth(glyph), 2, "operation glyphs preserve two-column alignment")
    H.assert_match(lines[1], "worker://reviewer/", "the operation target is retained")
  end

  -- Broadcast SEND lifecycle is one glyph with no repeated protocol code.
  local bc_short = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "Paris" } },
  })
  H.assert_eq(#bc_short, 1, "short broadcast inline")
  H.assert_eq(bc_short[1], "💬 Paris", "model SEND uses its message glyph and one body separator")
  H.assert_truthy(not bc_short[1]:match("200"), "wire status is not repeated in the human waterfall")

  local bc_with_aside = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { aside = "Answer ready", body = { raw = "Paris" } },
  })
  H.assert_eq(bc_with_aside[1], "💬 — Answer ready Paris", "broadcast aside stays on its header")

  local bc_continuing = R({
    op = "TASK", origin = "model", scheme = nil, pathname = nil,
    status_rx = 102, signal = 102,
    tx = { body = { entries = { { content = "Continuing.", priority = "medium", status = "in_progress" } } } },
  })
  H.assert_eq(bc_continuing[1], "▶️", "102 uses the continuing lifecycle glyph without its code")
  H.assert_eq(bc_continuing[2], "🚧 Continuing.", "continuing inventory is structured")
  H.assert_eq(vim.fn.strdisplaywidth("▶️"), 2, "continuing lifecycle sequence is width-stable in Neovim")
  H.assert_eq(vim.fn.strdisplaywidth("⏹️"), 2, "completion lifecycle sequence is width-stable in Neovim")

  local runtime_continuing = R({
    op = "TASK", origin = "_plurnk", scheme = nil, pathname = nil,
    status_rx = 102, signal = 102,
    tx = { body = { entries = { { content = "Address the prompt.", priority = "medium", status = "pending" } } } },
  })
  H.assert_eq(runtime_continuing[1], "▶️", "continuations use lifecycle regardless of producer")
  H.assert_eq(runtime_continuing[2], "⬜ Address the prompt.", "runtime inventory follows the same projection")

  local bc_arrow = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "loading $\\rightarrow$ running" } },
  })
  H.assert_match(bc_arrow[1], "loading → running", "inline right arrow uses its editor glyph")
  H.assert_truthy(not bc_arrow[1]:match("\\rightarrow"), "inline right arrow source is not rendered literally")

  -- Broadcast SEND carrying signal 200, multi-line body — header + indented body lines.
  local bc_multi = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "hi\nthere" } },
  })
  H.assert_eq(#bc_multi, 3, "multi broadcast header + 2 body lines")
  H.assert_eq(bc_multi[1], "💬", "multi broadcast header is one message glyph")
  H.assert_eq(bc_multi[2], "   hi", "body line 1 indented 3")
  H.assert_eq(bc_multi[3], "   there", "body line 2 indented 3")

  -- Broadcast SEND with no body — header only.
  local empty = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
  })
  H.assert_eq(#empty, 1, "empty broadcast = header only")
  H.assert_eq(empty[1], "💬", "empty broadcast repeats no protocol code")

  -- Two lanes: the OP is the identity (the origin lane is gone — converged 2026-07-10)
  local client_line = R({
    op = "EDIT", origin = "client", scheme = nil, pathname = "/x",
    status_rx = 202, tx = { body = "ok" },
  })
  H.assert_match(client_line[1], "📝", "op glyph is lane 1")
  H.assert_match(client_line[1], "💤", "202 → 💤 parked status lane (aligned with @plurnk/plurnk)")

  local R2 = require("plurnk.render").status_glyph
  H.assert_eq(R2(202), "💤", "202 → 💤 parked")
  H.assert_eq(R2(300), "🤔", "300 → 🤔 decision")
  H.assert_eq(R2(499), "✋", "499 → ✋ abort")

  local scoped = R({
    op = "READ", origin = "model", scheme = "worker", pathname = "/notes.md",
    lineMarker = { marks = { "@fHtjK", 42 } }, status_rx = 200,
  })
  H.assert_match(scoped[1], "<@fHtjK,42>", "operation scope renders in canonical wire order")

  local directed = R({
    op = "SEND", origin = "model", scheme = "worker", pathname = "/child",
    status_rx = 200, signal = 200, tx = { body = { raw = "Continue." } },
  })
  H.assert_match(directed[1], "^💬", "directed SEND is a message, not a disposition")
  H.assert_truthy(not directed[1]:match("200"), "routine directed SEND suppresses its numeric status")
  local directed_failure = R({
    op = "SEND", origin = "model", scheme = "worker", pathname = "/gone",
    status_rx = 410, signal = 410, tx = { body = { raw = "Gone." } },
  })
  H.assert_match(directed_failure[1], "^💬 💥 410", "failed directed SEND retains its diagnostic status")

  -- The service's actionless prompt row renders as user speech, not an op trace.
  local prompt_block = R({
    op = "prompt", origin = "_plurnk", scheme = "prompt", pathname = "/3/1",
    status_rx = 200, rx = { content = "What is the capital of France?" },
  })
  H.assert_eq(prompt_block[1], "❯ What is the capital of France?", "durable prompt uses a neutral user marker")
  H.assert_truthy(not prompt_block[1]:match("🐹"), "the retired mascot never labels user speech")
  H.assert_truthy(not prompt_block[1]:match("📝"), "no EDIT glyph on prompts")

  local long_prompt = R({
    op = "prompt", origin = "_plurnk", scheme = "prompt", pathname = "/3/1",
    status_rx = 200, rx = { content = "line one\nline two" },
  })
  H.assert_eq(#long_prompt, 3, "multi-line prompt = header + body lines")
  H.assert_match(long_prompt[2], "line one", "prompt body present")

  -- A worker:/// entry EDIT stays an op trace (not a prompt).
  local manifest = R({
    op = "EDIT", origin = "model", scheme = "worker", pathname = "/manifest.json",
    status_rx = 201, tx = { body = "{}" },
  })
  H.assert_match(manifest[1], "📝", "a non-prompt worker:/// EDIT keeps the EDIT glyph")

  -- The human waterfall carries no coordinates; ordinals and DB
  -- ids alike stay off the row.
  local coorded = R({
    op = "READ", origin = "model", scheme = "known", pathname = "/x",
    status_rx = 200, loop_seq = 1, turn_seq = 2, sequence = 3,
    loop_id = 38, turn_id = 412, tx = {}, rx = {},
  })
  H.assert_truthy(not coorded[1]:match("01/02/03"), "no coordinate gutter on human rows")
  H.assert_truthy(not coorded[1]:match("38/412"), "DB ids never masquerade as coordinates")

  -- The pure renderer preserves authored Mermaid source. Width-aware visual
  -- projection belongs to the worker-tab presentation, never the log row.
  local mermaid_source = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "before\n```mermaid\ngraph TD\n  a --> b\n```\nafter" } },
  })
  H.assert_match(table.concat(mermaid_source, "\n"), "```mermaid", "pure renderer retains Mermaid source")

  -- Summary
  H.assert_match(r.render_summary(3, 850, 200, 200, false), "done", "summary tag")
  H.assert_match(r.render_summary(3, 1500, 200, 200, false), "1.50s", "summary seconds")
  H.assert_match(r.render_summary(5, 100, 200, 200, true), "maxTurns", "summary maxTurns")
  -- #70: differentiated terminal-status labels (was a bare "final N")
  H.assert_eq(r.terminal_status_label(413), "budget overflow", "413 → budget overflow")
  H.assert_eq(r.terminal_status_label(429), "turn ceiling", "429 → turn ceiling")
  H.assert_eq(r.terminal_status_label(499), "cancelled", "499 → cancelled")
  H.assert_eq(r.terminal_status_label(500), "strike-out", "500 → strike-out")
  H.assert_eq(r.terminal_status_label(508), "loop detected", "508 → loop detected")
  H.assert_eq(r.terminal_status_label(418), "final 418", "unmapped → final N")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
