-- [§nvim-name-is-identity]
-- workspace.list returns { workspaces: [{ id, name, project_root?, ... }] }.
local NAME = "03_workspace_list"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local r = H.call("workspace.list")
  H.assert_type(r, "table", "workspace.list result")
  H.assert_type(r.workspaces, "table", "workspace.list.workspaces")
  for i, s in ipairs(r.workspaces) do
    H.assert_type(s.id, "number", "workspaces[" .. i .. "].id")
    H.assert_type(s.name, "string", "workspaces[" .. i .. "].name")
  end
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
