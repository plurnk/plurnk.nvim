-- Prompt, direct execution, and model-loop submission.

local M = {}

local function extract_open_paths(prompt)
  local seen, out = {}, {}
  for path in (" " .. tostring(prompt)):gmatch("%s@(%S+)") do
    path = path:gsub("[%.,;:!?%)]+$", "")
    if #path > 0 and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

function M.wrap_with_selection(prompt, opts)
  local mode = vim.fn.mode()
  local selection
  if mode:match("[vV\22]") then
    selection = require("plurnk.selection").get_selection()
  elseif opts and opts.range and opts.range > 0 then
    selection = require("plurnk.selection").get_selection(
      { 0, opts.line1, 1, 0 },
      { 0, opts.line2, 1000, 0 },
      "V")
  end
  if selection then return selection .. (prompt or "") end
  return prompt or ""
end

function M.selection_text(opts)
  local selection = require("plurnk.selection")
  if vim.fn.mode():match("[vV\22]") then return selection.get_selection_text() end
  if opts and opts.range and opts.range > 0 then
    return selection.get_selection_text(
      { 0, opts.line1, 1, 0 },
      { 0, opts.line2, 1000, 0 },
      "V")
  end
  return nil
end

function M.exec(command, captured_binding)
  local function execute(_, binding)
    local client = require("plurnk.client")
    client.send("op.exec", { command = command }, false, function(result)
      if type(result) == "table"
          and type(result.status) == "number"
          and result.status >= 400 then
        client.notify("exec rejected: " .. tostring(result.status), vim.log.levels.WARN)
      end
    end, { binding = binding })
  end
  if captured_binding then execute(captured_binding.workspace, captured_binding)
  else require("plurnk.workspace_context").resolve(execute) end
end

function M.run(workspace_name, prompt, policy, binding, review, inject)
  binding = binding or require("plurnk.state").binding(workspace_name)
  local bridge = require("plurnk.bridge")
  if bridge.is_renaming(binding.workspace) then
    require("plurnk.client").notify("Workspace rename in progress; submit again when it completes.", vim.log.levels.WARN)
    return false
  end
  if bridge.active(binding) or inject then
    if review then
      require("plurnk.client").notify("Proposal policy belongs to a new loop; omit ? to add a prompt, or stop this loop first.", vim.log.levels.WARN)
      return false
    end
    bridge.inject(binding, prompt)
    return true
  end
  local forwarded = { policy = policy or require("plurnk.policy").base() }
  local open_paths = extract_open_paths(prompt)
  if #open_paths > 0 then forwarded.openPaths = open_paths end

  local state = require("plurnk.state")
  state.set_loop_inflight(workspace_name, true, binding.workerId)
  bridge.run(binding, prompt, {
    forwardedProps = next(forwarded) ~= nil and forwarded or nil,
    review = review,
  }, function()
    state.set_loop_inflight(workspace_name, false, binding.workerId)
    require("plurnk.worker_tab").update_status(workspace_name)
    pcall(vim.cmd, "redrawstatus! | redrawtabline")
  end)
  return true
end

function M.prompt(opts)
  local text = M.wrap_with_selection(opts.args, opts)
  if not text or text == "" then
    require("plurnk.client").notify("PlurnkPrompt: no prompt text", vim.log.levels.WARN)
    return
  end
  require("plurnk.workspace_context").resolve(function(workspace_name, binding)
    require("plurnk.worker_tab").open(workspace_name, binding.workerId)
    local accepted = M.run(workspace_name, text, opts.policy, binding, opts.review, opts.inject)
    if opts.on_submitted then opts.on_submitted(accepted) end
  end)
end

return M
