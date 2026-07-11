-- [§nvim-control-plane]
-- providers.list returns { aliases: [{ alias, provider, model, active }, ...] }.
local NAME = "02_providers"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local r = H.call("providers.list")
  H.assert_type(r, "table", "providers.list result")
  H.assert_type(r.aliases, "table", "providers.list.aliases")
  -- We don't assert length — daemon may have zero configured aliases.
  -- But every element, when present, must have alias/provider/model strings.
  for i, a in ipairs(r.aliases) do
    H.assert_type(a.alias, "string", "alias[" .. i .. "].alias")
    H.assert_type(a.provider, "string", "alias[" .. i .. "].provider")
    H.assert_type(a.model, "string", "alias[" .. i .. "].model")
  end
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
