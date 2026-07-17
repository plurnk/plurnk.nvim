-- [§nvim-workspace-door][§nvim-honest-errors]
-- THE FRONT DOOR (operator, 2026-07-10): :PlurnkWorkspaces → pick → ATTACHED, for
-- real — the plurnk paradigm (the name IS the identity), with failures failing
-- loudly instead of the or-{} pantomime that shipped the disaster.
local NAME = "36_workspace_door"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  -- Seed a real named workspace on the daemon.
  local created = H.call("workspace.create", { name = "door-alpha" })
  H.assert_type(created.id, "number", "seeded workspace id")
  H.assert_eq(created.name, "door-alpha", "the name is the identity — created verbatim, no prefix")

  -- Walk the actual door: :PlurnkWorkspaces with the picker choosing door-alpha.
  vim.ui.select = function(items, _opts, on_choice)
    for _, it in ipairs(items) do
      if type(it) == "table" and it.name == "door-alpha" then on_choice(it); return end
    end
    on_choice(nil)
  end
  require("plurnk.commands").workspaces()
  H.wait_for(function()
    return require("plurnk.state").get_active_workspace_name() == "door-alpha"
  end, 10000, "picker attach binds the active workspace")
  H.assert_eq(require("plurnk.state").get_workspace_id("door-alpha"), created.id, "attached the REAL workspace id")

  -- A FAILING attach must fail loudly and bind NOTHING (no or-{} pantomime).
  require("plurnk.state").set_active_workspace_name(nil)
  local bound_after_failure = "unset"
  require("plurnk.client").send("workspace.attach", { id = 999999 }, false, function(att)
    bound_after_failure = att == nil and "nil" or type(att)
  end)
  H.wait_for(function() return bound_after_failure ~= "unset" end, 8000, "failing attach calls back")
  H.assert_eq(bound_after_failure, "nil", "a failed action delivers NIL — never a truthy empty table")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
