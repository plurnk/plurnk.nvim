-- Renderer unit test: every op type produces the right glyph layout.
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
  -- READ with content extra + universal status sub-glyph (✅ on 200).
  local read_lines = R({
    op = "READ", origin = "model", scheme = "known", pathname = "/x",
    status_rx = 200, rx = { content = "Paris" },
  })
  H.assert_eq(#read_lines, 1, "READ single line")
  H.assert_match(read_lines[1], "📖", "READ glyph")
  H.assert_match(read_lines[1], "✅", "READ ✅ sub-glyph on 200")
  H.assert_match(read_lines[1], "Paris", "READ content")
  -- No leading indent
  H.assert_truthy(read_lines[1]:sub(1, 1) ~= " ", "no leading indent")

  -- EXEC: executor name from signal renders as [executor]; failure → ❌.
  local exec_lines = R({
    op = "EXEC", origin = "model", scheme = "exec", pathname = "/1/1/2/EXEC",
    status_rx = 501, signal = "search",
    tx = { body = "capital of France" },
  })
  H.assert_eq(#exec_lines, 1, "EXEC single line")
  H.assert_match(exec_lines[1], "🔧", "EXEC glyph")
  H.assert_match(exec_lines[1], "❌", "EXEC ❌ on 5xx")
  H.assert_match(exec_lines[1], "%[search%]", "EXEC shows executor in brackets")
  H.assert_match(exec_lines[1], "capital of France", "EXEC shows command body")

  -- FIND with count
  local find_lines = R({
    op = "FIND", origin = "model", scheme = "known", pathname = "/**",
    status_rx = 200, rx = { results = "a\nb\nc" },
  })
  H.assert_match(find_lines[1], "🔍", "FIND glyph")
  H.assert_match(find_lines[1], "→ 3 results", "FIND count")

  -- Broadcast SEND[200] short body — inline.
  local bc_short = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "Paris" } },
  })
  H.assert_eq(#bc_short, 1, "short broadcast inline")
  H.assert_match(bc_short[1], "💬", "SEND glyph")
  H.assert_match(bc_short[1], "✅", "SEND ✅ sub-glyph")
  H.assert_match(bc_short[1], "200  Paris", "200 then 2sp then body")

  -- Broadcast SEND[200] multi-line body — header + indented body lines.
  local bc_multi = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "hi\nthere" } },
  })
  H.assert_eq(#bc_multi, 3, "multi broadcast header + 2 body lines")
  H.assert_eq(bc_multi[2], "   hi", "body line 1 indented 3")
  H.assert_eq(bc_multi[3], "   there", "body line 2 indented 3")

  -- Broadcast SEND with no body — header only.
  local empty = R({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
  })
  H.assert_eq(#empty, 1, "empty broadcast = header only")

  -- Origin glyph fallback
  local client_line = R({
    op = "EDIT", origin = "client", scheme = nil, pathname = "/x",
    status_rx = 202, tx = { body = "ok" },
  })
  H.assert_match(client_line[1], "👤", "client glyph")

  -- Prompt entry (plurnk://prompt/*) renders as USER SPEECH, not an EDIT trace.
  local prompt_block = R({
    op = "EDIT", origin = "plurnk", scheme = "plurnk", pathname = "prompt/3/1",
    status_rx = 201, tx = { body = "What is the capital of France?" },
  })
  H.assert_match(prompt_block[1], "👤", "prompt speaks as the user")
  H.assert_match(prompt_block[1], "💬", "prompt is speech, not an op")
  H.assert_match(prompt_block[1], "What is the capital", "short prompt inlines")
  H.assert_truthy(not prompt_block[1]:match("📝"), "no EDIT glyph on prompts")

  local long_prompt = R({
    op = "EDIT", origin = "plurnk", scheme = "plurnk", pathname = "prompt/3/1",
    status_rx = 201, tx = { body = "line one\nline two" },
  })
  H.assert_eq(#long_prompt, 3, "multi-line prompt = header + body lines")
  H.assert_match(long_prompt[2], "line one", "prompt body present")

  -- Non-prompt plurnk:// EDIT stays an op trace.
  local manifest = R({
    op = "EDIT", origin = "plurnk", scheme = "plurnk", pathname = "manifest.json",
    status_rx = 201, tx = { body = "{}" },
  })
  H.assert_match(manifest[1], "📝", "non-prompt plurnk EDIT keeps the EDIT glyph")

  -- Coordinate prefix (svc#208): rendered from the wire ordinals
  -- (loop_seq/turn_seq), padded; DB ids (loop_id/turn_id) never used.
  local coorded = R({
    op = "READ", origin = "model", scheme = "known", pathname = "/x",
    status_rx = 200, loop_seq = 1, turn_seq = 2, sequence = 3,
    loop_id = 38, turn_id = 412, tx = {}, rx = {},
  })
  H.assert_match(coorded[1], "01/02/03 ", "coordinate prefix renders padded ordinals")
  H.assert_truthy(not coorded[1]:match("38/412"), "DB ids never masquerade as coordinates")

  -- Summary
  H.assert_match(r.render_summary(3, 850, 200, 200, false), "done", "summary tag")
  H.assert_match(r.render_summary(3, 1500, 200, 200, false), "1.50s", "summary seconds")
  H.assert_match(r.render_summary(5, 100, 200, 200, true), "maxTurns", "summary maxTurns")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
