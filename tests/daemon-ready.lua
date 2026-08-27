-- {§nvim-installed-journey} Await the same worldless AG-UI discovery action
-- clients use for compatibility checks. A listening socket or HTTP response is
-- insufficient while the daemon still owns its durable-recovery startup gate.
vim.opt.rtp:append(os.getenv("PLURNK_NVIM_ROOT") or vim.fn.getcwd())

local agui = require("plurnk.agui")
local timeout_ms = tonumber(os.getenv("PLURNK_NVIM_READY_TIMEOUT_MS") or "60000")
local deadline = vim.uv.hrtime() + (timeout_ms * 1000000)
local target = {
  url = string.format(
    "http://%s:%s",
    os.getenv("PLURNK_HOST") or "127.0.0.1",
    os.getenv("PLURNK_PORT") or "1066"
  ),
}
local last_detail = "the daemon did not answer"

while vim.uv.hrtime() < deadline do
  local segment
  local handle = agui.rpc(target, "nvim-readiness", "discover", {}, function(value)
    segment = value
  end)
  vim.wait(1000, function() return segment ~= nil end, 20)
  if segment ~= nil and segment.state == "complete" and type(segment.result) == "table" then
    vim.cmd("qa!")
    return
  end
  if handle ~= nil and segment == nil then pcall(function() handle:kill(15) end) end
  if segment ~= nil and type(segment.problem) == "table" then
    last_detail = tostring(segment.problem.detail or segment.problem.title or last_detail)
  end
  vim.wait(200, function() return false end, 20)
end

io.stderr:write("AG-UI discovery readiness timed out: " .. last_detail .. "\n")
vim.cmd("cq")
