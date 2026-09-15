-- {§nvim-waterfall-turns}: rows render as they arrive, a turn's TASK takes the head of its
-- turn, a started execution appears at its conclusion and once in grey if the model moves
-- on, fanned-out rows collapse, and hydrated history shows a started execution grey.
-- Pure worker-tab exercise; no daemon.
local NAME = "62_waterfall_turns"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local worker_tab = require("plurnk.worker_tab")
  local state = require("plurnk.state")
  state.set_workspace_id("turns", 1)
  worker_tab.open("turns")
  local rec = worker_tab.get_record("turns")
  local ns = vim.api.nvim_create_namespace("plurnk_waterfall")
  local function lines() return vim.api.nvim_buf_get_lines(rec.waterfall_buf, 0, -1, false) end
  local function groups_at(row)
    local names = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(rec.waterfall_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      names[mark[4].hl_group] = true
    end
    return names
  end
  local function entry(over)
    return vim.tbl_extend("force", { worker_id = 7, origin = "model", status_rx = 200, loop_seq = 1, turn_seq = 1, sequence = 1, tx = {}, rx = {} }, over)
  end

  worker_tab.append_history("turns", { entry({ id = 1, op = "READ", scheme = "known", pathname = "/a.md", sequence = 1 }) })
  H.assert_eq(lines()[1], "READ (known:///a.md)", "a row renders as it arrives")
  H.assert_truthy(groups_at(1)["PlurnkOp"], "with its highlight")
  worker_tab.append_history("turns", { entry({ id = 2, op = "sh", sequence = 2, tx = { runtime = "sh", aside = "list the files" },
    rx = { status = 200, outcome = "started" }, attrs = { runtime = "sh", stream = "sh:///1a2b3c4d" } }) })
  H.assert_eq(#lines(), 1, "a started execution renders nothing yet")
  worker_tab.append_history("turns", { entry({ id = 3, op = "TASK", sequence = 3, status_rx = 102,
    tx = { body = { entries = { { content = "Read a.", priority = "medium", status = "completed" } } } } }) })
  local rows = lines()
  H.assert_eq(rows[1], "", "the turn's TASK takes the head of its turn")
  H.assert_match(rows[2], "^┌", "its table follows")
  H.assert_eq(rows[#rows], "READ (known:///a.md)", "and the turn's rows follow the table")
  H.assert_truthy(groups_at(#rows)["PlurnkOp"], "the row keeps its highlight after the reproject")
  H.assert_truthy(groups_at(2)["PlurnkTableBorder"], "the table outline is highlighted")

  -- The next turn begins while the execution is still open.
  worker_tab.append_history("turns", { entry({ id = 4, op = "READ", scheme = "known", pathname = "/b.md", loop_seq = 1, turn_seq = 2, sequence = 1 }) })
  rows = lines()
  H.assert_eq(rows[#rows - 1], "sh list the files", "an execution still open when the next turn begins shows once, in grey")
  H.assert_truthy(groups_at(#rows - 1)["PlurnkPending"], "grey")
  H.assert_eq(rows[#rows], "READ (known:///b.md)", "then the new turn's row")
  worker_tab.append_history("turns", { entry({ id = 5, op = "READ", scheme = "known", pathname = "/c.md", loop_seq = 1, turn_seq = 3, sequence = 1 }) })
  rows = lines()
  H.assert_eq(rows[#rows - 1], "READ (known:///b.md)", "a greyed execution is not greyed again at the following turn")

  worker_tab.conclude_execution("turns", { entryId = 2, workerId = 7, target = "sh:///1a2b3c4d", subscriptionId = 1, scheme = "sh",
    result = { status = 200 }, summary = "sh:///1a2b3c4d completed (exit 0)", wakeAction = "no-op-active-loop" })
  rows = lines()
  H.assert_eq(rows[#rows], "sh list the files", "the conclusion renders the launching fence once more, settled")
  H.assert_truthy(groups_at(#rows)["PlurnkOp"], "green: it succeeded")
  worker_tab.conclude_execution("turns", { entryId = 9, workerId = 7, target = "python:///0c0ffee1", subscriptionId = 2, scheme = "python",
    result = { status = 500 }, summary = "python:///0c0ffee1 failed (exit 2)", wakeAction = "no-op-active-loop" })
  H.assert_eq(lines()[#lines()], "python (python:///0c0ffee1) — failed (exit 2)", "a conclusion whose launch was never seen is its scheme and address")
  worker_tab.conclude_execution("turns", { entryId = 10, workerId = 99, target = "sh:///deadbeef", subscriptionId = 3, scheme = "sh",
    result = { status = 200 }, summary = "", wakeAction = "no-op-active-loop" })
  H.assert_eq(#lines(), #rows + 1, "another worker's conclusion renders nothing here")

  -- Non-model rows are immediate and never reordered; ambience never renders.
  worker_tab.append_history("turns", { entry({ id = 11, op = "prompt", origin = "_plurnk", scheme = "prompt", pathname = "/2/1",
    loop_seq = 2, turn_seq = 1, sequence = 1, rx = { content = "next?" } }) })
  H.assert_eq(lines()[#lines()], "❯ next?", "the durable prompt row is user speech, immediate")
  local before = #lines()
  worker_tab.append_history("turns", { entry({ id = 12, op = "EDIT", origin = "_plurnk", scheme = "https", pathname = "/x",
    loop_seq = 2, turn_seq = 1, sequence = 2, attrs = { kind = "entry_materialized" } }) })
  H.assert_eq(#lines(), before, "machine acquisition is ambience, not a row")

  -- A glob READ collapses to the authored statement when its last row lands.
  worker_tab.append_history("turns", { entry({ id = 13, op = "READ", scheme = nil, pathname = "/pets_a.md", loop_seq = 2, turn_seq = 2, sequence = 1,
    tx = { target = { raw = "pets_*.md" } }, rx = { range = { returned = { 1, 3 } } }, attrs = { fanout = { target = "pets_*.md", matched = 2, index = 0, count = 2 } } }) })
  H.assert_eq(#lines(), before, "a fanned-out row waits for the last of its glob")
  worker_tab.append_history("turns", { entry({ id = 14, op = "READ", scheme = nil, pathname = "/pets_b.md", loop_seq = 2, turn_seq = 2, sequence = 2, status_rx = 404,
    tx = { target = { raw = "pets_*.md" } }, rx = { status = 404, problem = { title = "Entry not found" } }, attrs = { fanout = { target = "pets_*.md", matched = 2, index = 1, count = 2 } } }) })
  H.assert_eq(lines()[#lines()], "READ (pets_*.md) {2} — Entry not found", "the glob collapses to its authored statement, a failed path naming the row")

  -- Hydrated history: the TASK heads its turn; a started execution stands in grey.
  worker_tab.hydrate("turns", 7, {
    entry({ id = 21, op = "READ", scheme = "known", pathname = "/h.md", sequence = 1 }),
    entry({ id = 22, op = "sh", sequence = 2, tx = { runtime = "sh", aside = "old run" }, rx = { status = 200, outcome = "started" }, attrs = { runtime = "sh", stream = "sh:///cafe0001" } }),
    entry({ id = 23, op = "TASK", sequence = 3, status_rx = 102, tx = { body = { entries = { { content = "Read h.", priority = "medium", status = "completed" } } } } }),
  })
  rows = lines()
  H.assert_eq(rows[1], "", "hydrated history puts the TASK at the head of its turn")
  H.assert_eq(rows[#rows - 1], "READ (known:///h.md)", "then the turn's rows")
  H.assert_eq(rows[#rows], "sh old run", "a hydrated started execution stands in grey: its row carries no conclusion")
  H.assert_truthy(groups_at(#rows)["PlurnkPending"], "grey")

  -- Folds name their blocks.
  vim.api.nvim_set_current_win(rec.waterfall_win)
  local fold_label
  for _, block in ipairs(rec.blocks) do
    if block.fold and block.fold_label then fold_label = block.fold_label; break end
  end
  H.assert_eq(fold_label, "completed 1", "a folded TASK names its columns")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
