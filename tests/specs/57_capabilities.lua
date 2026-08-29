local NAME = "57_capabilities"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent = {}
  require("plurnk.workspace_context").resolve = function(callback) callback("smoke") end
  local client = require("plurnk.client")
  client.notify = function() end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    local worker = params.policy or {}
    if callback then callback({
      service = {}, workspace = {}, workerBound = {}, worker = worker, effective = worker,
    }) end
  end

  require("plurnk.capabilities").run("")
  H.assert_eq(sent[1].method, "worker.capabilities.get", "empty command inspects the effective capability cascade")

  require("plurnk.capabilities").run('{"deny":[{"tool":"issue_write"}]}')
  H.assert_eq(sent[2].method, "worker.capabilities.set", "JSON command changes durable worker capabilities")
  H.assert_eq(sent[2].params.policy.deny[1].tool, "issue_write", "selector rides without a local policy dialect")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
