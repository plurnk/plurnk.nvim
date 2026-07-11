-- [§nvim-control-plane]
-- Liveness: ping → empty object result, no error.
local NAME = "01_ping"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local r = H.call("ping")
  H.assert_type(r, "table", "ping returned non-table")
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
