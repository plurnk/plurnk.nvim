-- {§nvim-conversation-requests}: the installed editor, real daemon, and streaming fixture.
vim.opt.rtp:prepend(assert(os.getenv("PLURNK_NVIM_ROOT")))
require("plurnk").setup({ yolo = false })
local state, bridge = require("plurnk.state"), require("plurnk.bridge")
local tabs, context = require("plurnk.worker_tab"), require("plurnk.workspace_context")
local function wait(predicate, label)
  assert(vim.wait(15000, predicate, 10), "Timed out: " .. label)
end
local function rpc(binding, method, params)
  local settled, result, failure = false
  bridge.rpc(binding, method, params or {}, function(value, problem)
    result, failure, settled = value, problem, true
  end)
  wait(function() return settled end, method)
  assert(not failure, vim.inspect(failure))
  return result
end
local function world(name)
  local binding = state.binding(name)
  local created = rpc(binding, "workspace.create", { name = name, projectRoot = vim.fn.getcwd() })
  state.set_workspace_id(name, created.id)
  return binding
end
local function fork(owner, name)
  local created = rpc(owner, "run.fork", { name = name })
  state.set_worker_label(owner.workspace, created.workerId, created.workerName)
  return state.binding(owner.workspace, created.workerId)
end
local function focus(owner)
  tabs.open(owner.workspace, owner.workerId)
  vim.cmd("stopinsert")
end
local function text(owner)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].plurnk_workspace == owner.workspace and vim.b[buf].plurnk_worker_id == owner.workerId
        and not vim.api.nvim_buf_get_name(buf):match("/input/") then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end
local function submit(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == "<CR>" then mapping.callback(); return end
  end
  error("No native submit mapping")
end
local function release(name)
  local response = vim.system({ "curl", "-sf", "-X", "POST", os.getenv("PLURNK_NVIM_FIXTURE_URL") .. "/release/" .. name }):wait()
  assert(response.code == 0, "Fixture release failed")
end
local ok, err = pcall(function()
  local shared = world("concurrent-shared")
  local alice, bob = fork(shared, "alice"), fork(shared, "bob")
  local other = fork(world("concurrent-other"), "alice")
  local proposals, questions, answers, failures = {}, {}, {}, {}
  local notices = {}
  local notify = vim.notify
  vim.notify = function(message, ...)
    notices[#notices + 1] = message
    notify(message, ...)
  end
  local dispatch = require("plurnk.dispatch")
  local original = dispatch.handle_notification
  dispatch.handle_notification = function(notification)
    if notification.method == "loop/proposal" then proposals[#proposals + 1] = notification.params end
    if notification.method == "loop/interaction" then questions[#questions + 1] = notification.params end
    if notification.method == "problem/event" then failures[#failures + 1] = notification.params end
    original(notification)
  end
  vim.ui.input = function(_, answer) answers[#answers + 1] = answer end
  focus(alice)
  submit({ "parallel-alice", "Ask your question." })
  wait(function() return text(alice):find("Live reasoning for parallel%-alice") end, "Alice's live reasoning")
  focus(bob)
  vim.cmd("AI parallel-bob")
  wait(function() return text(bob):find("Live reasoning for parallel%-bob") end, "Bob's live reasoning")
  assert(bridge.active(alice), "Tab switch detached Alice")
  focus(other)
  vim.cmd("AI other-alice")
  wait(function() return text(other):find("other%-alice complete%.") and not bridge.active(other) end, "other workspace's Alice completes")
  assert(not text(other):find("parallel%-"), "foreign conversation leaked into other Alice")
  release("parallel-alice")
  release("parallel-bob")
  wait(function() return #questions == 1 and #proposals == 1 and #answers == 1 end, "concurrent question and approval")
  assert(questions[1].binding == alice and proposals[1].binding == bob, "interrupts lost their destinations")
  assert(vim.fn.filereadable("bob.txt") == 0, "Bob's effect ran without approval")
  focus(bob)
  submit({ "? change proposal policy" })
  assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "? change proposal policy",
    "a refused mid-loop policy change discarded the input")
  vim.cmd("AI ... bob-command-injection")
  submit({ "bob-buffer-injection" })
  wait(function() return bridge.active(bob).injections == 0 end, "both Bob injections are admitted")
  focus(alice)
  vim.cmd("AI ! printf 'human accepted\\n' > human.txt")
  wait(function() return #proposals == 2 end, "independent human action is proposed")
  local human = proposals[2]
  assert(human.binding == alice and human.requestSource == "action", "human action lost Alice's binding")
  focus(alice)
  vim.cmd("AI /stop")
  wait(function() return not bridge.active(alice) end, "Alice cancelled while Bob and human action wait")
  wait(function() return state.get_runtime_status(alice.workspace, alice.workerId).lifecycle == "failed" end,
    "Alice's authoritative terminal status after cancellation")
  answers[1]("too late")
  assert(bridge.active(bob), "Alice's cancellation stopped Bob")
  assert(require("plurnk.resolve").pending_count() == 2, "cancel discarded unrelated approvals")
  focus(other)
  local function accept(proposal)
    local buf = vim.fn.bufnr("plurnk-nvim://exec/" .. proposal.logEntryId)
    assert(buf ~= -1, "missing native proposal buffer")
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if mapping.lhs == "a" then mapping.callback(); return end
    end
    error("missing native approval mapping")
  end
  accept(human)
  wait(function() return vim.fn.filereadable("human.txt") == 1 end, "human action remains independently approvable")
  assert(vim.fn.filereadable("bob.txt") == 0, "human approval also approved Bob")
  accept(proposals[1])
  wait(function() return text(bob):find("parallel%-bob complete%.") and not bridge.active(bob) end, "Bob receives injections and completes")
  assert(vim.fn.readfile("bob.txt")[1] == "bob accepted", "Bob's actual approved effect is absent")
  assert(vim.fn.readfile("human.txt")[1] == "human accepted", "independent human effect is absent")
  assert(not text(alice):find("parallel%-bob complete"), "Bob's response leaked into Alice")
  -- {§loop-lifecycle-vocabulary}: cancellation is a failed lifecycle; its exact
  -- cause remains in Problem Details rather than a client-invented lifecycle.
  assert(state.get_runtime_status(alice.workspace, alice.workerId).lifecycle == "failed", "Alice's terminal state is absent")
  assert(#failures == 0, "an independent request failed: " .. vim.inspect(failures))
  assert(table.concat(notices, "\n"):find("Loop cancelled", 1, true), "the user did not receive cancellation acknowledgement")
  assert(state.get_runtime_status(bob.workspace, bob.workerId).lifecycle == "completed", "Bob's status is not completion")
  assert(state.get_runtime_status(other.workspace, other.workerId).lifecycle == "completed", "other Alice's state was overwritten")
  focus(other)
  vim.cmd("AI ... other-alice-followup")
  wait(function()
    local _, count = text(other):gsub("other%-alice complete%.", "")
    return count == 2 and not bridge.active(other) and not state.is_loop_inflight(other.workspace, other.workerId)
  end, "post-terminal injection is observed without replaying its prompt")
  print("PASS installed concurrent conversations")
end)
if ok then vim.cmd("qa!") else print("FAIL installed concurrent conversations: " .. tostring(err)); vim.cmd("cq") end
