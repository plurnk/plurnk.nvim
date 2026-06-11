-- Run-keyed waterfalls (#16 topology): entries route to THEIR run's
-- buffer by entry.run_id (no interleaving), the pending record (created
-- before the run id is known) is adopted by the first run seen, and
-- hydrate replaces a run's buffer with canonical history.
-- Pure module path; no daemon round-trip.
local NAME = "19_run_routing"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local function entry(id, run_id, path)
  return {
    id = id, run_id = run_id, loop_id = 1, turn_id = 1, sequence = 1,
    op = "READ", suffix = "", origin = "model", signal = nil,
    scheme = "known", pathname = path or ("/e" .. id), hostname = nil,
    fragment = nil, status_rx = 200,
    tx = { op = "READ", body = nil }, rx = { status = 200 },
  }
end

local ok, err = pcall(function()
  local rt = require("plurnk.run_tab")
  local state = require("plurnk.state")
  state.set_session_id("topo", 5)

  -- Open before the run id is known → pending record.
  rt.open("topo")
  local rec = rt.get_record("topo")
  H.assert_truthy(rec, "pending record exists")
  H.assert_match(vim.api.nvim_buf_get_name(rec.waterfall_buf), "plurnk://topo/pending", "pending title")

  -- First entry carries run_id 42 → pending adopted: rekeyed, renamed,
  -- and 42 becomes the session's current run.
  rt.append_history("topo", { entry(1, 42) })
  H.assert_eq(state.get_run_id("topo"), 42, "first run seen claims current")
  local adopted = rt.get_record("topo")
  H.assert_eq(adopted.waterfall_buf, rec.waterfall_buf, "pending record adopted, not replaced")
  H.assert_match(vim.api.nvim_buf_get_name(adopted.waterfall_buf), "plurnk://topo/run#42", "renamed to run key")
  H.assert_eq(vim.b[adopted.waterfall_buf].plurnk_run_id, 42, "buffer stamped with run id")

  -- A second run's entries land in a SEPARATE buffer — never interleaved.
  rt.append_history("topo", { entry(2, 43, "/other-run") })
  local lines42 = vim.api.nvim_buf_get_lines(adopted.waterfall_buf, 0, -1, false)
  H.assert_eq(#lines42, 1, "run 42 buffer has only its own entry")
  local buf43
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("plurnk://topo/run#43") then buf43 = b end
  end
  H.assert_truthy(buf43, "run 43 got its own buffer")
  H.assert_match(table.concat(vim.api.nvim_buf_get_lines(buf43, 0, -1, false), "\n"),
    "/other%-run", "run 43 entry landed in run 43 buffer")

  -- Hydrate REPLACES a run's waterfall with canonical history.
  rt.hydrate("topo", 43, { entry(7, 43, "/hydrated-a"), entry(8, 43, "/hydrated-b") })
  local hydrated = table.concat(vim.api.nvim_buf_get_lines(buf43, 0, -1, false), "\n")
  H.assert_match(hydrated, "/hydrated%-a", "hydrated entry present")
  H.assert_truthy(not hydrated:match("/other%-run"), "stale content replaced")

  -- Labels: once a run has a name, titles and winbars use it.
  state.set_run_label("topo", 44, "feature-pass")
  rt.append_history("topo", { entry(9, 44) })
  local found
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("plurnk://topo/feature%-pass") then found = b end
  end
  H.assert_truthy(found, "named run uses its label in the buffer title")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
