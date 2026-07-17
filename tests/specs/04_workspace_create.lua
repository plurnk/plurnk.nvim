-- [§nvim-name-is-identity]
-- workspace.create returns { id, name }. Subsequent workspace.list contains it.
local NAME = "04_workspace_create"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local fresh_name = string.format("plurnk-nvim-test-%d-%d", vim.loop.hrtime(), math.random(1, 1e6))
  local r = H.call("workspace.create", { name = fresh_name })
  H.assert_type(r, "table", "workspace.create result")
  H.assert_type(r.id, "number", "workspace.create.id")
  H.assert_eq(r.name, fresh_name, "workspace.create.name")
  -- Confirm it's listed.
  local list = H.call("workspace.list")
  local found = false
  -- The plurnk paradigm: the name IS the identity — the workspace lists under the
  -- EXACT name it was created with. (An earlier spec-rewrite bent this assertion
  -- to a broken prefix scheme; the original expectation was right.)
  for _, s in ipairs(list.workspaces) do if s.name == fresh_name then found = true end end
  H.assert_truthy(found, "workspace not in list after create")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
