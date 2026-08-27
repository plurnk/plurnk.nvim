-- Workspace membership overlay commands.

local M = {}

local function membership_glob(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg ~= "" then return arg end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or name:match("^%a[%w+.-]*://") then return nil end
  return vim.fn.fnamemodify(name, ":.")
end

local function constrain(effect, arg)
  local glob = membership_glob(arg)
  if not glob then
    require("plurnk.client").notify(
      ":AI/" .. effect .. " needs a glob, or run it in a file buffer",
      vim.log.levels.WARN)
    return
  end
  require("plurnk.workspace_context").resolve(function(workspace_name)
    require("plurnk.client").send("workspace.constrain", {
      effect = effect,
      glob = glob,
    }, false, function()
      require("plurnk.client").notify(effect .. ": " .. glob, vim.log.levels.INFO)
      require("plurnk.signs").refresh(workspace_name)
    end)
  end)
end

function M.pick(opts) constrain("pick", opts.args) end
function M.hide(opts) constrain("hide", opts.args) end
function M.view(opts) constrain("view", opts.args) end

function M.drop(opts)
  local glob = membership_glob(opts.args)
  if not glob then
    require("plurnk.client").notify(
      ":AI/drop needs a glob, or run it in a file buffer",
      vim.log.levels.WARN)
    return
  end
  require("plurnk.workspace_context").resolve(function(workspace_name)
    local client = require("plurnk.client")
    client.send("workspace.constraints", {}, false, function(result)
      local constraints = type(result) == "table" and result.constraints or {}
      local matches = vim.tbl_filter(function(constraint)
        return constraint.glob == glob
      end, constraints)
      if #matches == 0 then
        client.notify("no constraint matching " .. glob, vim.log.levels.WARN)
        return
      end
      for _, constraint in ipairs(matches) do
        client.send("workspace.unconstrain", {
          effect = constraint.effect,
          glob = constraint.glob,
        }, false)
      end
      client.notify(
        "dropped " .. #matches .. " constraint(s): " .. glob,
        vim.log.levels.INFO)
      require("plurnk.signs").refresh(workspace_name)
    end)
  end)
end

function M.list()
  require("plurnk.workspace_context").resolve(function()
    local client = require("plurnk.client")
    client.send("workspace.members", {}, false, function(result)
      local members = type(result) == "table" and result.members or {}
      local hidden = type(result) == "table" and result.hidden or {}
      local editable, view = {}, {}
      for _, member in ipairs(members) do
        if member.effect == "view" then
          view[#view + 1] = member.path
        else
          editable[#editable + 1] = member.path
        end
      end

      local lines = {}
      if #members == 0 and #hidden == 0 then
        lines[1] = "the model's universe is empty — no Git members or /pick rules"
      else
        lines[1] = string.format(
          "the model's universe: %d file%s — %d editable, %d read-only%s",
          #members,
          #members == 1 and "" or "s",
          #editable,
          #view,
          #hidden > 0 and (", " .. #hidden .. " hidden") or "")
        for _, path in ipairs(view) do lines[#lines + 1] = "  view    " .. path end
        for _, path in ipairs(hidden) do lines[#lines + 1] = "  hidden  " .. path end
        if #editable <= 40 then
          for _, path in ipairs(editable) do lines[#lines + 1] = "  member  " .. path end
        else
          lines[#lines + 1] = string.format(
            "  member  …%d editable files (git-tracked); listing suppressed",
            #editable)
        end
      end

      client.send("workspace.constraints", {}, false, function(constraint_result)
        local constraints = type(constraint_result) == "table"
          and constraint_result.constraints
          or {}
        if #constraints == 0 then
          lines[#lines + 1] = "rules: none (git-tracked files only)"
        else
          local parts = {}
          for _, constraint in ipairs(constraints) do
            parts[#parts + 1] = constraint.effect .. " " .. constraint.glob
          end
          lines[#lines + 1] = "rules: " .. table.concat(parts, ", ")
        end
        client.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      end)
    end)
  end)
end

return M
