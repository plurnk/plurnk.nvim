-- {§nvim-markdown-projection}: model Markdown remains semantic source in the
-- editor. An available plurnk render filter projects it asynchronously; an
-- absent filter leaves the source faithful and block-local.
local NAME = "51_markdown_presentation"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local markdown = require("plurnk.markdown")
  H.assert_eq(markdown.looks_like_markdown("1. first\n2. second"), true, "ordered-list admission matches the TUI")
  H.assert_eq(markdown.looks_like_markdown("~~~json\n{}\n~~~"), true, "tilde-fence admission matches the TUI")
  H.assert_eq(markdown.looks_like_markdown("An ordinary sentence."), false, "ordinary prose stays ordinary prose")
  local source = table.concat({
    "## Task list",
    "",
    "- [x] Boot the terminal",
    "- [ ] Render the table",
    "",
    "| Surface | Use |",
    "| --- | --- |",
    "| Neovim | Delegated presentation. |",
  }, "\n")

  local original_path = vim.env.PATH
  local fixture_root = vim.fn.tempname()
  local calls = fixture_root .. "/calls"
  vim.fn.mkdir(fixture_root, "p")
  vim.fn.writefile({
    "#!/bin/sh",
    "if test \"$1\" = render && test \"$2\" = --help; then",
    "  printf 'usage: plurnk render [--width <columns>]\\n'",
    "  exit 0",
    "fi",
    "test \"$1\" = render || exit 64",
    "test \"$2\" = --width || exit 64",
    "printf '%s\\n' \"$3\" >> \"" .. calls .. "\"",
    "cat >/dev/null",
    "printf 'projection at width %s\\n' \"$3\"",
  }, fixture_root .. "/plurnk")
  vim.fn.setfperm(fixture_root .. "/plurnk", "rwxr-xr-x")
  vim.env.PATH = fixture_root .. ":" .. original_path
  markdown.reset()

  local changed = false
  local initial = markdown.render(source, 48, "   ", function() changed = true end)
  H.assert_match(table.concat(initial.lines, "\n"), "## Task list", "source is immediately available while projection runs")
  H.wait_for(function() return changed end, 5000, "plurnk render projection")

  local projected = markdown.render(source, 48, "   ", function() end)
  H.assert_eq(table.concat(projected.lines, "\n"), "   projection at width 48", "cached filter output replaces source")
  H.assert_eq(#vim.fn.readfile(calls), 1, "a source+width projection runs once")
  markdown.render(source, 48, "   ", function() end)
  H.assert_eq(#vim.fn.readfile(calls), 1, "a repeated projection uses the cache")

  local resized = false
  markdown.render(source, 80, "", function() resized = true end)
  H.wait_for(function() return resized end, 5000, "width-specific projection")
  H.assert_eq(table.concat(markdown.render(source, 80, "", function() end).lines, "\n"),
    "projection at width 80", "a new width gets its own projection")
  H.assert_eq(#vim.fn.readfile(calls), 2, "width participates in the cache key")

  local unsafe_calls = fixture_root .. "/unsafe-calls"
  vim.fn.writefile({
    "#!/bin/sh",
    "if test \"$1\" = render && test \"$2\" = --help; then",
    "  printf 'usage: plurnk [prompt...]\\n'",
    "  exit 0",
    "fi",
    "printf 'invoked\\n' >> \"" .. unsafe_calls .. "\"",
    "exit 99",
  }, fixture_root .. "/plurnk")
  vim.fn.setfperm(fixture_root .. "/plurnk", "rwxr-xr-x")
  markdown.reset()
  local incompatible = markdown.render(source, 48, "", function() error("incompatible client must not schedule") end)
  H.assert_match(table.concat(incompatible.lines, "\n"), "## Task list", "an incompatible client preserves source")
  H.assert_eq(vim.fn.filereadable(unsafe_calls), 0, "an unproven render verb is never given model content")

  vim.env.PATH = "/usr/bin:/bin"
  markdown.reset()
  local fallback = markdown.render(source, 48, "   ", function() error("absent renderer must not schedule") end)
  H.assert_eq(table.concat(fallback.lines, "\n"),
    "   " .. source:gsub("\n", "\n   "), "an absent filter preserves the semantic source")
  H.assert_eq(markdown.available(), false, "renderer discovery reports the faithful fallback")

  local worker_tab = require("plurnk.worker_tab")
  require("plurnk.state").set_workspace_id("markdown", 1)
  worker_tab.open("markdown")
  local rec = worker_tab.get_record("markdown")
  H.assert_eq(vim.bo[rec.waterfall_buf].syntax, "", "the mixed waterfall is not one Markdown document")
  worker_tab.append_history("markdown", {
    {
      id = 1, worker_id = 7, loop_id = 1, turn_id = 1,
      loop_seq = 1, turn_seq = 1, sequence = 1,
      op = "SEND", origin = "model", status_rx = 200,
      tx = { body = { raw = source } }, rx = {},
    },
    {
      id = 2, worker_id = 7, loop_id = 1, turn_id = 1,
      loop_seq = 1, turn_seq = 1, sequence = 2,
      op = "READ", origin = "model", status_rx = 200,
      scheme = "known", pathname = "/after.md", tx = {}, rx = {},
    },
  })
  local rows = vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false)
  H.assert_match(rows[#rows], "/after%.md", "a later Plurnk row remains outside the Markdown source block")

  vim.env.PATH = original_path
  vim.fn.delete(fixture_root, "rf")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
