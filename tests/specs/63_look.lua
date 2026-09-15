-- {§nvim-inspection}: :AI/look, K on a waterfall row, and a typed LOOK fence are one human
-- READ through op.look — content in a scratch split named for the address, an empty result in
-- the daemon's words, a Problem as a notice. Pure module path; stubs client.send.
local NAME = "63_look"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local look = require("plurnk.look")
  local sent = {}
  local answer = { status = 200, content = "alpha\nbeta\n" }
  require("plurnk.client").send = function(method, params, _, cb)
    sent[#sent + 1] = { method = method, params = params }
    if cb then cb(answer) end
  end
  local notices = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level, opts)
    notices[#notices + 1] = msg
    return original_notify(msg, level, opts)
  end

  H.assert_eq(look.fence("worker:///note.md <1,20> /x/"), "```LOOK (worker:///note.md) <1,20> /x/```", "the address takes its parentheses; scope and pattern ride as typed")
  H.assert_eq(look.fence("(worker:///note.md)"), "```LOOK (worker:///note.md)```", "a parenthesized address passes through")
  H.assert_eq(look.fence("  "), nil, "nothing to look at")
  H.assert_eq(look.heading("````LOOK (worker:///x)\n~needle\n````"), "LOOK (worker:///x)", "the heading without its fence or body")

  -- /look: content into a scratch split that takes focus.
  local origin = vim.api.nvim_get_current_win()
  look.run("worker:///note.md")
  H.assert_eq(sent[1].method, "op.look", "the verb submits one observation")
  H.assert_eq(sent[1].params.text, "```LOOK (worker:///note.md)```", "as the composed LOOK fence")
  vim.wait(500, function() return vim.fn.bufnr("plurnk-nvim://look/worker____note.md") ~= -1 end, 10)
  local buf = vim.fn.bufnr("plurnk-nvim://look/worker____note.md")
  H.assert_truthy(buf ~= -1, "the content opens in a scratch buffer named for the address")
  H.assert_eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "alpha\nbeta", "the content, verbatim")
  H.assert_eq(vim.api.nvim_win_get_buf(0), buf, "the split takes focus: the user asked to read")
  H.assert_truthy(vim.api.nvim_get_current_win() ~= origin, "in its own split")
  H.assert_eq(vim.bo[buf].filetype, "markdown", "filetype follows the address's extension")

  -- An empty result says so in the daemon's words.
  answer = { status = 204, content = "", detail = "No path matched pets_*.md" }
  look.run("pets_*.md")
  vim.wait(500, function() return vim.fn.bufnr("plurnk-nvim://look/pets_*.md") ~= -1 end, 10)
  local empty = vim.fn.bufnr("plurnk-nvim://look/pets_*.md")
  H.assert_truthy(empty ~= -1, "an empty look still opens its buffer")
  H.assert_eq(vim.api.nvim_buf_get_lines(empty, 0, -1, false)[1], "(No path matched pets_*.md)", "with the daemon's own words")

  -- A Problem is a notice, never a silent nothing and never a buffer.
  answer = { status = 404, problem = { type = "x", title = "Entry not found", status = 404, detail = "No entry exists at worker:///missing.md.", recovery = "Check the address." } }
  local before = #notices
  look.run("worker:///missing.md")
  vim.wait(500, function() return #notices > before end, 10)
  H.assert_match(notices[#notices], "LOOK %(worker:///missing%.md%) — Entry not found — No entry exists at worker:///missing%.md%.", "the notice carries the Problem's title and detail")
  H.assert_match(notices[#notices], "Check the address%.", "and its recovery")
  H.assert_eq(vim.fn.bufnr("plurnk-nvim://look/worker____missing.md"), -1, "a failed look opens nothing")

  -- K on a waterfall row inspects that row's authored target.
  local worker_tab = require("plurnk.worker_tab")
  require("plurnk.state").set_workspace_id("looks", 1)
  worker_tab.open("looks")
  local rec = worker_tab.get_record("looks")
  worker_tab.append_history("looks", {
    { id = 1, worker_id = 7, loop_seq = 1, turn_seq = 1, sequence = 1, op = "READ", origin = "model", status_rx = 200,
      scheme = nil, pathname = "/AGENTS.md", lineMarker = { marks = { 17, -1 } }, tx = { target = { raw = "AGENTS.md" } }, rx = {} },
  })
  vim.api.nvim_set_current_win(rec.waterfall_win)
  vim.api.nvim_win_set_cursor(rec.waterfall_win, { 1, 0 })
  answer = { status = 200, content = "# Agents\n" }
  local before_k = #sent
  vim.api.nvim_feedkeys("K", "x", false)
  H.assert_eq(#sent, before_k + 1, "K submits one look")
  H.assert_eq(sent[#sent].params.text, "```LOOK (AGENTS.md)```", "for the row's authored target, plain")
  vim.wait(500, function() return vim.fn.bufnr("plurnk-nvim://look/AGENTS.md") ~= -1 end, 10)
  H.assert_truthy(vim.fn.bufnr("plurnk-nvim://look/AGENTS.md") ~= -1, "and reads it in a split")

  -- A typed LOOK fence in the input buffer takes the same path.
  local input = require("plurnk.input")
  vim.api.nvim_buf_set_lines(rec.input_buf, 0, -1, false, { "```LOOK (worker:///plan.md)```" })
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(rec.input_buf, "n")) do
    if m.lhs == "<CR>" and m.callback then vim.api.nvim_set_current_win(rec.input_win); m.callback() end
  end
  H.assert_eq(sent[#sent].params.text, "```LOOK (worker:///plan.md)```", "the fence goes to op.look unchanged")
  H.assert_eq(table.concat(vim.api.nvim_buf_get_lines(rec.input_buf, 0, -1, false), ""), "", "and the composer clears")
  local _ = input

  vim.notify = original_notify
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
