-- Stream-window parity (#16 phase 2): channel prefixes + interleave,
-- batched flush (one entry.read per tick burst), partial-line hold,
-- conclusion footer, and BufWipeout → SEND[499] cancel.
-- Pure module path; stubs transport.send.
local NAME = "16_stream_render"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local stream = require("plurnk.stream")

  local content = { stdout = "", stderr = "" }
  local reads, sends = 0, {}
  require("plurnk.client").send = function(method, params, _, cb)
    if method == "entry.read" then
      reads = reads + 1
      local channels = {}
      for name, c in pairs(content) do
        channels[name] = { content = c, mimetype = "text/plain", tokens = 0, state = "active" }
      end
      if cb then cb({ status = 200, entry = { channels = channels } }) end
      return
    end
    table.insert(sends, { method = method, params = params })
  end

  local function tick(len)
    stream.on_event({ entryId = 1, target = "exec://demo", channel = "stdout",
      state = "active", contentLength = len })
  end

  local function buf_lines()
    local buf = vim.fn.bufnr("plurnk://stream/exec___demo")
    H.assert_truthy(buf ~= -1, "stream buffer exists")
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  -- ── Batching: three ticks in one window → one entry.read ───────────
  content.stdout = "hello\nwor"
  content.stderr = "oops\n"
  tick(5); tick(7); tick(9)
  vim.wait(400, function() return reads >= 1 end, 10)
  H.assert_eq(reads, 1, "tick burst coalesced into one entry.read")

  local lines = buf_lines()
  H.assert_eq(lines[1], "1│ hello", "stdout line carries 1│ prefix")
  H.assert_eq(lines[2], "2│ oops", "stderr line carries 2│ prefix")
  H.assert_eq(#lines, 2, "trailing partial ('wor') held back")

  -- ── Partial completes on a later tick ───────────────────────────────
  content.stdout = "hello\nworld\n"
  tick(12)
  vim.wait(400, function() return reads >= 2 end, 10)
  lines = buf_lines()
  H.assert_eq(lines[3], "1│ world", "completed partial renders once whole")

  -- ── Conclusion: footer + winbar + tracking dropped ─────────────────
  content.stdout = "hello\nworld\ntail-no-newline"
  stream.on_concluded({ entryId = 1, target = "exec://demo", subscriptionId = 1,
    scheme = "exec", closeStatus = 200, summary = "demo done", wakeAction = "no-op-active-loop" })
  vim.wait(400, function()
    local ls = buf_lines()
    return ls[#ls] and ls[#ls]:match("concluded") ~= nil
  end, 10)
  lines = buf_lines()
  H.assert_eq(lines[4], "1│ tail-no-newline", "held partial flushed at conclusion")
  H.assert_match(lines[#lines], "── concluded · 200 · demo done ──", "conclusion footer")

  -- Wipe AFTER conclusion → no cancel goes out.
  vim.cmd("bwipeout! " .. vim.fn.bufnr("plurnk://stream/exec___demo"))
  H.assert_eq(#sends, 0, "wipeout after conclusion sends nothing")

  -- ── Wipeout of a LIVE stream cancels the subscription ──────────────
  content.stdout = "running\n"
  content.stderr = ""
  stream.on_event({ entryId = 2, target = "exec://live", channel = "stdout",
    state = "active", contentLength = 8 })
  vim.wait(400, function() return vim.fn.bufnr("plurnk://stream/exec___live") ~= -1 and reads >= 3 end, 10)
  vim.cmd("bwipeout! " .. vim.fn.bufnr("plurnk://stream/exec___live"))
  H.assert_eq(sends[1].method, "op.send", "wipeout of live stream cancels")
  H.assert_eq(sends[1].params.status, 499, "cancel is SEND[499]")
  H.assert_eq(sends[1].params.recipient, "exec://live", "cancel addressed to the stream URI")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
