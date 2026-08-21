-- {§nvim-reasoning-policy} — effective value and choices come from the daemon;
-- explicit selection persists once and the winbar displays it independently.
local NAME = "44_reasoning"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  local calls = {}
  local notices = {}
  require("plurnk.client").notify = function(message) notices[#notices + 1] = message end
  require("plurnk.client").send = function(method, params, _notify, callback)
    calls[#calls + 1] = { method = method, params = params }
    if not callback then return end
    if method == "worker.reasoning.get" then
      callback({ policy = "adaptive", supportedPolicies = { "off", "adaptive", "high" } })
    elseif method == "worker.reasoning.set" then
      callback({ policy = params.policy, supportedPolicies = { "off", "adaptive", "high" } })
    end
  end

  state.set_active_workspace_name("reasoning")
  state.set_workspace_id("reasoning", 1)
  local commands = require("plurnk.commands")

  commands.set_reasoning("")
  H.assert_eq(calls[1].method, "worker.reasoning.get", "bare reasoning inspects daemon state")
  H.assert_eq(state.get_reasoning_policy("reasoning"), "adaptive", "effective policy is hydrated")
  H.assert_match(notices[#notices], "supported: off, adaptive, high", "inspection reports daemon choices")

  commands.set_reasoning("high")
  H.assert_eq(calls[2].method, "worker.reasoning.set", "explicit reasoning persists through its action")
  H.assert_eq(calls[2].params.policy, "high", "the client forwards the exact spelling")
  H.assert_eq(state.get_reasoning_policy("reasoning"), "high", "the daemon result is display truth")
  H.assert_match(require("plurnk.worker_tab").winbar_text("reasoning", nil), "🧠 high", "winbar shows reasoning separately")

  local completion = commands.ai_complete("", "AI /reasoning a", 0)
  H.assert_eq(table.concat(completion, ","), "adaptive", "completion derives from daemon-supported choices")

  state.set_active_workspace_name(nil)
  commands.set_reasoning("low")
  H.assert_eq(state.consume_selected_reasoning_policy(), "low", "pre-workspace selection is consumed once")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
