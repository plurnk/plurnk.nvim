-- Prompt, direct EXEC, and model-loop submission.

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

function M.exec(command)
  require("plurnk.workspace_context").resolve(function()
    local client = require("plurnk.client")
    client.send("op.exec", { command = command }, false, function(result)
      if type(result) == "table"
          and type(result.status) == "number"
          and result.status >= 400 then
        client.notify("exec rejected: " .. tostring(result.status), vim.log.levels.WARN)
      end
    end)
  end)
end

function M.run(workspace_name, prompt, flags)
  local forwarded = {}
  local configured = require("plurnk.config").get("request_user_input")
  local enabled_by_env = ({
    ["1"] = true,
    ["true"] = true,
    ["yes"] = true,
    ["on"] = true,
  })[(vim.env.PLURNK_REQUEST_USER_INPUT or ""):lower()]
  local request_user_input = true
  if configured == false or enabled_by_env == false then request_user_input = false end
  forwarded.requestUserInput = request_user_input
  if flags then forwarded.flags = flags end
  local open_paths = extract_open_paths(prompt)
  if #open_paths > 0 then forwarded.openPaths = open_paths end

  local state = require("plurnk.state")
  state.set_loop_inflight(workspace_name, true)
  require("plurnk.bridge").run(workspace_name, prompt, {
    forwardedProps = next(forwarded) ~= nil and forwarded or nil,
    workerId = state.get_worker_id(workspace_name),
  }, function()
    state.set_loop_inflight(workspace_name, false)
    require("plurnk.worker_tab").update_status(workspace_name)
    pcall(vim.cmd, "redrawstatus! | redrawtabline")
  end)
end

function M.prompt(opts)
  local text = M.wrap_with_selection(opts.args, opts)
  if not text or text == "" then
    require("plurnk.client").notify("PlurnkPrompt: no prompt text", vim.log.levels.WARN)
    return
  end
  require("plurnk.workspace_context").resolve(function(workspace_name)
    require("plurnk.worker_tab").open(workspace_name)
    M.run(workspace_name, text, opts.flags)
  end)
end

return M
