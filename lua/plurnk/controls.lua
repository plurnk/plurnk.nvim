-- Miscellaneous controls that do not own workspace or generation policy.

local M = {}

function M.script(opts)
  local client = require("plurnk.client")
  local path = vim.fn.trim((opts and opts.args) or "")
  if path == "" then
    client.notify(":AI/script needs a path to a .plk file", vim.log.levels.WARN)
    return
  end
  local absolute = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(absolute) == 0 then
    client.notify(":AI/script — file not readable: " .. absolute, vim.log.levels.WARN)
    return
  end
  local text = table.concat(vim.fn.readfile(absolute), "\n")
  client.send("op.parse", { text = text }, false, function(result)
    if type(result) ~= "table" or type(result.results) ~= "table" then return end
    local worst = 0
    for _, operation in ipairs(result.results) do
      if type(operation.status) == "number" and operation.status > worst then
        worst = operation.status
      end
    end
    local count = #result.results
    local message = string.format("script: %d op%s", count, count == 1 and "" or "s")
    if worst >= 400 then
      client.notify(message .. ", worst status " .. worst, vim.log.levels.WARN)
    else
      client.notify(message .. " ok", vim.log.levels.INFO)
    end
  end)
end

function M.yolo()
  local diff = require("plurnk.diff")
  diff.toggle_yolo()
  require("plurnk.client").notify(
    "YOLO " .. (diff.is_yolo() and "ON" or "OFF"),
    vim.log.levels.INFO)
end

function M.ping()
  require("plurnk.client").send("ping", {}, false, function()
    require("plurnk.client").notify("pong", vim.log.levels.INFO)
  end)
end

function M.accept() require("plurnk.resolve").accept() end
function M.accept_edits() require("plurnk.resolve").accept_edits() end
function M.reject() require("plurnk.resolve").reject() end
function M.cancel() require("plurnk.resolve").cancel_current() end
function M.next() require("plurnk.resolve").next() end
function M.prev() require("plurnk.resolve").prev() end

function M.stop()
  local count = require("plurnk.resolve").cancel_all()
  local client = require("plurnk.client")
  if not require("plurnk.workspace_context").active() then
    client.notify(string.format(
      "Cancelled %d pending proposal%s (no active workspace)",
      count,
      count == 1 and "" or "s"), vim.log.levels.INFO)
    return
  end
  client.send("loop.cancel", { reason = "user_stop" }, false, function(result)
    if type(result) == "table" and result.cancelled then
      client.notify("Loop cancelled", vim.log.levels.INFO)
    else
      client.notify(string.format(
        "No loop in flight; cancelled %d proposal%s",
        count,
        count == 1 and "" or "s"), vim.log.levels.INFO)
    end
  end)
end

function M.clear()
  local workspace = require("plurnk.workspace_context").active()
  M.stop()
  if workspace then require("plurnk.worker_tab").close(workspace) end
end

return M
