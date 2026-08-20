-- Universal Agent Skills projection: direct argv, standard target, no local
-- registry/copy implementation and no terminal-client subprocess.
local NAME = "43_skills"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local project = vim.fn.tempname()
  vim.fn.mkdir(project, "p")
  require("plurnk.state").set_project_path(project)

  local calls = {}
  local original_system = vim.system
  vim.system = function(argv, opts, callback)
    calls[#calls + 1] = { argv = argv, opts = opts }
    callback({ code = 0, signal = 0, stdout = "\27[32mdone\27[0m\n", stderr = "" })
    return { wait = function() return { code = 0 } end }
  end

  local notes = {}
  local original_notify = vim.notify
  vim.notify = function(message)
    notes[#notes + 1] = tostring(message)
  end

  local skills = require("plurnk.skills")
  skills.run("")
  skills.run("add 'owner/skill repo' --skill review")
  skills.run("remove review")
  skills.run("find sqlite review")
  skills.run("update review")
  skills.run("add owner/repo --all")

  H.wait_for(function() return #notes == 6 end, 2000, "skill command callbacks")
  local completed = 0
  for _, note in ipairs(notes) do
    H.assert_truthy(not note:find("\27", 1, true), "upstream terminal decoration does not leak into Neovim")
    if note:match("done$") then completed = completed + 1 end
  end
  H.assert_eq(completed, 5, "each delegated command reports plain output")
  H.assert_eq(#calls, 5, "--all cannot widen the universal target to every agent")
  H.assert_truthy(vim.deep_equal(calls[1].argv, { "npx", "--yes", "skills", "list", "--agent", "universal" }), "default list argv")
  H.assert_truthy(vim.deep_equal(calls[2].argv, {
    "npx", "--yes", "skills", "add", "owner/skill repo", "--skill", "review",
    "--agent", "universal", "--yes",
  }), "add argv")
  H.assert_truthy(vim.deep_equal(calls[3].argv, {
    "npx", "--yes", "skills", "remove", "review", "--agent", "universal", "--yes",
  }), "remove argv")
  H.assert_truthy(vim.deep_equal(calls[4].argv, { "npx", "--yes", "skills", "find", "sqlite", "review" }), "find argv")
  H.assert_truthy(vim.deep_equal(calls[5].argv, {
    "npx", "--yes", "skills", "update", "review", "--project", "--yes",
  }), "update argv")
  for _, call in ipairs(calls) do H.assert_eq(call.opts.cwd, project, "workspace cwd") end

  vim.system = original_system
  vim.notify = original_notify
  vim.fn.delete(project, "rf")
  print(NAME .. " ok")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
