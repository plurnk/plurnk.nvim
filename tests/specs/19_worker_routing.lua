-- Worker-keyed waterfalls: entries route to their worker's buffer by
-- entry.worker_id (no interleaving), the pending record (created before the
-- worker id is known) is adopted by the first worker seen, and hydrate replaces
-- a worker's buffer with canonical history.
-- Pure module path; no daemon round-trip.
local NAME = "19_worker_routing"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local function entry(id, worker_id, path)
  return {
    id = id, worker_id = worker_id, loop_id = 1, turn_id = 1,
    loop_seq = 1, turn_seq = 1, sequence = 1,
    op = "READ", origin = "model", signal = nil,
    scheme = "known", pathname = path or ("/e" .. id), hostname = nil,
    fragment = nil, status_rx = 200,
    tx = { op = "READ", body = nil }, rx = { status = 200 },
  }
end

local ok, err = pcall(function()
  local rt = require("plurnk.worker_tab")
  local state = require("plurnk.state")
  state.set_workspace_id("topo", 5)

  -- Open before the worker id is known → pending record.
  rt.open("topo")
  local rec = rt.get_record("topo")
  H.assert_truthy(rec, "pending record exists")
  H.assert_match(vim.api.nvim_buf_get_name(rec.waterfall_buf), "plurnk%-nvim://topo/pending", "pending title")

  -- First entry carries worker_id 42 → pending adopted: rekeyed, renamed,
  -- and 42 becomes the workspace's current worker.
  rt.append_history("topo", { entry(1, 42) })
  H.assert_eq(state.get_worker_id("topo"), 42, "first worker seen claims current")
  local adopted = rt.get_record("topo")
  H.assert_eq(adopted.waterfall_buf, rec.waterfall_buf, "pending record adopted, not replaced")
  H.assert_match(vim.api.nvim_buf_get_name(adopted.waterfall_buf), "plurnk%-nvim://topo/worker#42", "renamed to worker key")
  H.assert_eq(vim.b[adopted.waterfall_buf].plurnk_worker_id, 42, "buffer stamped with worker id")

  -- A second worker's entries land in a separate buffer — never interleaved.
  rt.append_history("topo", { entry(2, 43, "/other-run") })
  local lines42 = vim.api.nvim_buf_get_lines(adopted.waterfall_buf, 0, -1, false)
  H.assert_eq(#lines42, 1, "worker 42 buffer has only its own entry")
  local buf43
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("plurnk%-nvim://topo/worker#43") then buf43 = b end
  end
  H.assert_truthy(buf43, "worker 43 got its own buffer")
  H.assert_match(table.concat(vim.api.nvim_buf_get_lines(buf43, 0, -1, false), "\n"),
    "/other%-run", "worker 43 entry landed in worker 43 buffer")

  -- Hydrate replaces a worker's waterfall with canonical history.
  rt.hydrate("topo", 43, { entry(7, 43, "/hydrated-a"), entry(8, 43, "/hydrated-b") })
  local hydrated = table.concat(vim.api.nvim_buf_get_lines(buf43, 0, -1, false), "\n")
  H.assert_match(hydrated, "/hydrated%-a", "hydrated entry present")
  H.assert_truthy(not hydrated:match("/other%-run"), "stale content replaced")

  -- Labels: once a run has a name, titles and winbars use it.
  state.set_worker_label("topo", 44, "feature-pass")
  rt.append_history("topo", { entry(9, 44) })
  local found
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("plurnk%-nvim://topo/feature%-pass") then found = b end
  end
  H.assert_truthy(found, "named run uses its label in the buffer title")

  -- {§nvim-readable-reasoning}: live deltas update one region, which becomes
  -- one native, initially closed fold at completion.
  local before = vim.api.nvim_buf_line_count(adopted.waterfall_buf)
  rt.begin_reasoning("topo", 42, "1/1/2/SEND/reasoning")
  rt.append_reasoning_delta("topo", 42, "1/1/2/SEND/reasoning", "first line")
  H.assert_eq(vim.api.nvim_buf_get_lines(adopted.waterfall_buf, before, -1, false)[1], "💭 first line", "first delta is visible before completion")
  rt.append_reasoning_delta("topo", 42, "1/1/2/SEND/reasoning", "\nsecond line\nthird line")
  local reasoning_lines = vim.api.nvim_buf_get_lines(adopted.waterfall_buf, before, -1, false)
  H.assert_eq(table.concat(reasoning_lines, "\n"), "💭 first line\n   second line\n   third line", "reasoning block is appended verbatim")
  rt.end_reasoning("topo", 42, "1/1/2/SEND/reasoning")
  local fold_start = before + 1
  local closed = vim.api.nvim_win_call(adopted.waterfall_win, function()
    return vim.fn.foldclosed(fold_start)
  end)
  H.assert_eq(closed, fold_start, "multiline reasoning starts folded")
  local fold_text = vim.api.nvim_win_call(adopted.waterfall_win, function()
    return vim.fn.foldtextresult(fold_start)
  end)
  H.assert_match(fold_text, "💭 first line", "custom fold text preserves the block identity")
  H.assert_match(fold_text, "3 lines", "custom fold text reports its extent")
  H.assert_truthy(not fold_text:match("^%+%-%-"), "Neovim's default fold gutter is absent")
  local count = vim.api.nvim_buf_line_count(adopted.waterfall_buf)
  rt.append_reasoning("topo", 42, "1/1/2/SEND/reasoning", "duplicate")
  H.assert_eq(vim.api.nvim_buf_line_count(adopted.waterfall_buf), count, "message identity prevents duplicate reasoning")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
