-- Renderer unit test: every op type produces the right glyph layout.
-- Pure module; no daemon required.
local NAME = "06_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local r = require("plurnk.render")
local ok, err = pcall(function()
  -- READ with content extra
  local read_lines = r.render_log_entry({
    op = "READ", origin = "model", scheme = "known", pathname = "/x",
    status_rx = 200, rx = { content = "Paris" },
  })
  H.assert_eq(#read_lines, 1, "READ single line")
  H.assert_match(read_lines[1], "📖", "READ glyph")
  H.assert_match(read_lines[1], "Paris", "READ content")

  -- FIND with count
  local find_lines = r.render_log_entry({
    op = "FIND", origin = "model", scheme = "known", pathname = "/**",
    status_rx = 200, rx = { results = "a\nb\nc" },
  })
  H.assert_match(find_lines[1], "🔍", "FIND glyph")
  H.assert_match(find_lines[1], "→ 3 results", "FIND count")

  -- Broadcast SEND renders 2+ lines
  local bc = r.render_log_entry({
    op = "SEND", origin = "model", scheme = nil, pathname = nil,
    status_rx = 200, signal = 200,
    tx = { body = { raw = "hi\nthere" } },
  })
  H.assert_truthy(#bc >= 2, "broadcast multi-line")
  H.assert_match(bc[1], "✉", "SEND glyph")
  H.assert_match(bc[1], "✅", "SEND ✅ sub-glyph")

  -- Origin glyph fallback
  local client_line = r.render_log_entry({
    op = "EDIT", origin = "client", scheme = nil, pathname = "/x",
    status_rx = 202, tx = { body = "ok" },
  })
  H.assert_match(client_line[1], "👤", "client glyph")

  -- Summary
  H.assert_match(r.render_summary(3, 850, 200, 200, false), "done", "summary tag")
  H.assert_match(r.render_summary(3, 1500, 200, 200, false), "1.50s", "summary seconds")
  H.assert_match(r.render_summary(5, 100, 200, 200, true), "maxTurns", "summary maxTurns")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
