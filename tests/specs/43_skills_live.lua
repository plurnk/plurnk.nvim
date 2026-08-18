-- Installed-client dogfood: the skills surface manages the workspace's
-- skills/ directory end to end (list → add → list → remove).
local NAME = "43_skills_live"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local skill_file = vim.fn.tempname()
  vim.fn.writefile({
    "---",
    "name: review",
    "description: Check diffs before committing",
    "---",
    "Review diffs before committing.",
  }, skill_file)

  local project = vim.fn.tempname()
  vim.fn.mkdir(project, "p")

  local notes = {}
  local original_notify = vim.notify
  vim.notify = function(message, ...)
    notes[#notes + 1] = tostring(message)
    return original_notify(message, ...)
  end
  local function wait_note(pattern, label)
    H.wait_for(function()
      for _, message in ipairs(notes) do
        if message:match(pattern) then return true end
      end
      return false
    end, 20000, label)
  end

  local workspace = H.call("workspace.create", { projectRoot = project }, 10000)
  H.assert_type(workspace, "table", "workspace.create result")
  local state = require("plurnk.state")
  state.set_active_workspace_name(workspace.name)
  state.set_workspace_id(workspace.name, workspace.id)
  state.set_project_path(project)

  local ai = require("plurnk.commands").ai
  ai({ args = "/skills", range = 0 })
  wait_note("skills: none", "empty list")

  -- Local-path install (the git source forms share the same copy path).
  local source = vim.fn.tempname()
  vim.fn.delete(source, "rf")
  vim.fn.mkdir(source .. "/skills/review", "p")
  vim.fn.writefile({
    "---",
    "name: review",
    "description: Check diffs before committing",
    "---",
    "Review diffs before committing.",
  }, source .. "/skills/review/SKILL.md")
  ai({ args = "/skills install " .. source, range = 0 })
  wait_note("installed: review", "local install")

  ai({ args = "/skills add review " .. skill_file, range = 0 })
  wait_note("added: review", "skill add")

  ai({ args = "/skills", range = 0 })
  wait_note("review %— Check diffs before committing", "list shows the added skill")

  ai({ args = "/skills remove review", range = 0 })
  wait_note("removed: review", "skill remove")

  ai({ args = "/skills remove review", range = 0 })
  wait_note("no skill named review", "missing remove")

  vim.fn.delete(project, "rf")
  vim.fn.delete(skill_file)
  print(NAME .. " ok")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
