-- -- {§nvim-model-discovery}: models.list is a worldless, bounded, release-pinned
-- discovery action. It performs no inference and returns exact selectable routes.
local NAME = "46_model_catalog"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local page = H.call("models.list", { availability = "all", limit = 2 })
  H.assert_type(page, "table", "models.list result")
  H.assert_type(page.items, "table", "models.list.items")
  H.assert_truthy(#page.items > 0 and #page.items <= 2, "the requested page is non-empty and bounded")
  H.assert_eq(page.offset, 0, "the default offset is zero")
  H.assert_truthy(type(page.total) == "number" and page.total >= #page.items, "total covers the page")
  for i, model in ipairs(page.items) do
    H.assert_type(model.selector, "string", "model[" .. i .. "].selector")
    H.assert_match(model.selector, "^[^/]+/.+$", "the selector is an exact provider/model route")
    H.assert_type(model.readiness, "table", "model[" .. i .. "].readiness")
  end
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
