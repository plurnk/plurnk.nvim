-- {§nvim-installed-journey}: exercise the packaged plugin's default human
-- path against the built daemon and a deterministic standards-compatible
-- provider. The stochastic real-model specimen remains a separate opt-in gate.

local NAME = "installed Neovim default journey"
local root = assert(os.getenv("PLURNK_NVIM_ROOT"), "PLURNK_NVIM_ROOT is required")
vim.opt.rtp:prepend(root)

local function assert_truthy(value, message)
  if not value then error("ASSERT truthy " .. message) end
end

local function assert_match(value, pattern, message)
  if type(value) ~= "string" or not value:match(pattern) then
    error(string.format("ASSERT %s: %s does not match %s", message, vim.inspect(value), pattern))
  end
end

local function match_count(value, pattern)
  local count = 0
  for _ in value:gmatch(pattern) do count = count + 1 end
  return count
end

local function wait_for(predicate, timeout, message)
  assert_truthy(vim.wait(timeout, predicate, 25), "wait_for(" .. message .. ") timed out")
end

local function buffer_mapping(buf, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == lhs then return mapping end
  end
  return nil
end

local function waterfall(workspace)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_valid(buf)
        and vim.b[buf].plurnk_workspace == workspace
        and name:match("^plurnk%-nvim://")
        and not name:match("^plurnk%-nvim://input/") then
      return buf
    end
  end
  return nil
end

local ok, err = pcall(function()
  require("plurnk").setup()
  require("plurnk").apply_default_keymaps()

  local mappings = require("plurnk.keymaps").inspect()
  assert_truthy(#mappings > 20, "the installed default mapping inventory is complete")
  for _, mapping in ipairs(mappings) do
    assert_truthy(mapping.status == "installed" or mapping.status == "conflict",
      string.format("%s %s is installed or honestly conflicted", mapping.mode, mapping.lhs))
  end
  local open_mapping = vim.fn.maparg("<leader>aa", "n", false, true)
  assert_truthy(type(open_mapping) == "table" and open_mapping.rhs == ":AI<CR>",
    "the ordinary prompt mapping retains its declared behavior")

  local leader = type(vim.g.mapleader) == "string" and vim.g.mapleader or "\\"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(leader .. "aa", true, false, true), "mx", false)
  wait_for(function()
    return vim.api.nvim_buf_get_name(0):match("^plurnk%-nvim://input/") ~= nil
  end, 15000, "default mapping opens the native input buffer")

  local input = vim.api.nvim_get_current_buf()
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(input, 0, -1, false, {
    "Create a reviewed acceptance marker.",
    "The final response must confirm this multiline prompt.",
  })
  local submit = buffer_mapping(input, "<CR>")
  assert_truthy(type(submit) == "table" and type(submit.callback) == "function",
    "the native input buffer owns its normal-mode submit mapping")
  submit.callback()

  local state = require("plurnk.state")
  wait_for(function() return state.get_active_workspace_name() ~= nil end, 15000, "workspace creation")
  local workspace = state.get_active_workspace_name()
  wait_for(function() return require("plurnk.resolve").pending_count() == 1 end, 30000, "proposal interrupt")
  assert_truthy(vim.fn.readfile("journey.txt")[1] == "pending",
    "the side effect remains stopped before proposal resolution")

  local accept_mapping = vim.fn.maparg("<leader>ay", "n", false, true)
  assert_truthy(type(accept_mapping) == "table" and accept_mapping.rhs == ":PlurnkAccept<CR>",
    "the default proposal mapping retains its declared behavior")
  vim.cmd("PlurnkAccept")
  wait_for(function()
    return require("plurnk.resolve").pending_count() == 0
      and vim.fn.readfile("journey.txt")[1] == "accepted"
  end, 15000, "accepted proposal lands")

  wait_for(function()
    local status = state.get_runtime_status(workspace)
    return not state.is_loop_inflight(workspace)
      and type(status) == "table"
      and status.lifecycle == "completed"
  end, 30000, "settled lifecycle")

  local buf = waterfall(workspace)
  assert_truthy(buf ~= nil, "the installed journey owns a worker waterfall")
  local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert_match(content, "❯\n   Create a reviewed acceptance marker%.\n   The final response must confirm this multiline prompt%.",
    "the native buffer preserves the multiline prompt")
  assert_match(content, "💭 I will make one reviewed local change", "reasoning streams into the waterfall")
  local reasoning_count = match_count(content, "💭 I will make one reviewed local change")
  assert_truthy(reasoning_count == 1,
    "reasoning delivered before review is not duplicated after resume (count="
      .. tostring(reasoning_count) .. ")\n" .. content)
  assert_match(content, "🚧 Create the requested acceptance marker", "the active PLAN renders")
  assert_match(content, "🔧", "the executed operation renders")
  assert_match(content, "%[sh%]", "the operation row retains its executor")
  assert_match(content, "▶️ Next: Confirm the reviewed command completed%.", "the continuing SEND renders")
  assert_match(content, "✅ Create the requested acceptance marker", "the completed PLAN renders")
  assert_match(content, "⏹️ The reviewed multiline journey is complete%.", "the terminal SEND renders")

  local status = state.get_runtime_status(workspace)
  assert_truthy(status.model == "journey" and status.packet_count >= 2,
    "authoritative state names the fixture model and complete packet sequence")
  print("PASS " .. NAME .. ": " .. workspace .. " · P" .. tostring(status.packet_count))
end)

pcall(function() require("plurnk.client").stop() end)
if ok then vim.cmd("qa!") else
  print("FAIL " .. NAME .. ": " .. tostring(err))
  vim.cmd("cq")
end
