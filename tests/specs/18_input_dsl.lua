-- [§nvim-input-dsl]
-- Input-buffer raw DSL passthrough (TUI parity): `<<…` lines go to
-- op.parse verbatim; plain text still routes to loop.run.
-- Pure module path; stubs client.send.
local NAME = "18_input_dsl"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.bridge").run = function(_t, prompt, opts, on_done)
    local fwd = (opts and opts.forwardedProps) or {}
    table.insert(sent, { method = "loop.run", params = vim.tbl_extend("force", { prompt = prompt }, fwd) })
    if on_done then on_done(200) end
    return nil
  end
  require("plurnk.client").send = function(method, params, _, _cb)
    table.insert(sent, { method = method, params = params })
  end

  require("plurnk.run_tab").open("smoke")
  local buf = vim.api.nvim_get_current_buf()
  H.assert_match(vim.api.nvim_buf_get_name(buf), "plurnk://input/smoke", "input focused")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "<<SEND[200]:hi:SEND" })
  vim.api.nvim_feedkeys("\r", "x", false)
  H.assert_eq(sent[1].method, "op.parse", "<< input routes to op.parse")
  H.assert_eq(sent[1].params.text, "<<SEND[200]:hi:SEND", "raw DSL passes verbatim")
  H.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "", "input cleared after submit")

  require("plurnk.state").set_session_id("smoke", 1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello there" })
  vim.api.nvim_feedkeys("\r", "x", false)
  local last = sent[#sent]
  H.assert_eq(last.method, "loop.run", "plain input routes to loop.run")
  H.assert_eq(last.params.prompt, "hello there", "prompt carries the text")
  H.assert_eq(last.params.flags, nil, "plain input is act (no flags)")

  -- `? ` prefix is ASK — flags.mode=ask rides loop.run.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "? what changed" })
  vim.api.nvim_feedkeys("\r", "x", false)
  last = sent[#sent]
  H.assert_eq(last.method, "loop.run", "? input routes to loop.run")
  H.assert_eq(last.params.flags and last.params.flags.mode, "ask", "? input sends mode=ask")
  H.assert_eq(last.params.prompt, "what changed", "? stripped from prompt")

  -- `! ` prefix execs through the daemon.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "! git status" })
  vim.api.nvim_feedkeys("\r", "x", false)
  last = sent[#sent]
  H.assert_eq(last.method, "op.exec", "! input routes to op.exec")
  H.assert_eq(last.params.command, "git status", "! carries the command")

  -- `/` prefix is the verb surface — the input buffer IS the TUI in vim.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/ping" })
  vim.api.nvim_feedkeys("\r", "x", false)
  last = sent[#sent]
  H.assert_eq(last.method, "ping", "/verb input routes through :AI/ dispatch")
  H.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "", "input cleared after /verb")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
