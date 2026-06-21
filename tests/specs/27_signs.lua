-- Membership gutter signs (svc#243): session.members → a line-1 extmark sign
-- for the EXCEPTIONS only (view 🔒, hidden 🚫); a plain member and any
-- non-member project file get NO sign (the quiet default).
local NAME = "27_signs"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local state = require("plurnk.state")
  state.set_active_session_name("s")
  state.set_project_path("/proj")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/proj/src/a.lua")
  vim.bo[buf].buftype = ""
  vim.api.nvim_set_current_buf(buf)

  local ns = vim.api.nvim_create_namespace("plurnk_membership_signs")
  local signs = require("plurnk.signs")
  signs.setup_highlights()

  local members_reply
  require("plurnk.client").send = function(method, params, _, cb)
    if method == "session.members" and cb then cb(members_reply) end
  end

  local function sign_for(reply)
    members_reply = reply
    signs.refresh("s")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    if #marks == 0 then return nil end
    return marks[1][4].sign_text, marks[1][4].sign_hl_group
  end

  -- view → 🔒 / PlurnkSignView
  local txt, hl = sign_for({ members = { { path = "/src/a.lua", effect = "view" } }, hidden = {} })
  H.assert_match(txt, "🔒", "view → 🔒 sign")
  H.assert_eq(hl, "PlurnkSignView", "view highlight")

  -- hidden → 🚫 / PlurnkSignHidden
  txt, hl = sign_for({ members = {}, hidden = { "/src/a.lua" } })
  H.assert_match(txt, "🚫", "hidden → 🚫 sign")
  H.assert_eq(hl, "PlurnkSignHidden", "hidden highlight")

  -- member → NO sign (a plain member is the quiet default — only exceptions sign)
  txt = sign_for({ members = { { path = "/src/a.lua", effect = "member" } }, hidden = {} })
  H.assert_truthy(txt == nil, "a plain member gets no sign")

  -- non-member (not in members or hidden) → NO sign (resolved daemon-side)
  txt = sign_for({ members = { { path = "/other/b.lua", effect = "member" } }, hidden = {} })
  H.assert_truthy(txt == nil, "a non-member project file gets no sign")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
