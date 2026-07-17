-- Membership gutter signs (svc#243). On entering a project file (and after any
-- membership change), fetch workspace.members and place a line-1 gutter sign for
-- its RESOLVED effect — daemon-resolved, ZERO client glob-matching (the daemon
-- owns git + the overlay; the client only signs what it's told). Only the
-- EXCEPTIONS are signed — a plain member (the default) gets nothing, so the
-- gutter stays quiet:
--   view    🔒  — a member, but read-only to the model (/view)
--   hidden  🚫  — a tracked file the model can't see (/hide)
-- A plain member and any non-member project file get no sign.
-- No cache: the daemon is co-located, so workspace.members is a cheap local call
-- on each BufEnter (membership is not money — nothing here is worth staleness).
local M = {}
local ns = vim.api.nvim_create_namespace("plurnk_membership_signs")

-- Safe width-2 plane-1 emoji (the width-stable glyph discipline — NOT BMP
-- ornament emoji that a font may render width-1). Operator-pickable.
local SIGN = {
  view   = { text = "🔒", hl = "PlurnkSignView" },
  hidden = { text = "🚫", hl = "PlurnkSignHidden" },
}

M.setup_highlights = function()
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignView",   { fg = "#b8a200", default = true })  -- amber
  pcall(vim.api.nvim_set_hl, 0, "PlurnkSignHidden", { fg = "#666666", default = true })  -- grey
end

local function place(bufnr, effect)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local s = effect and SIGN[effect]  -- member / nil → no sign (the quiet default)
  if not s then return end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, 0, 0, { sign_text = s.text, sign_hl_group = s.hl })
end

-- Sign one buffer against a resolved {by_path, hidden} set. Skips scratch /
-- scheme buffers (only real project files carry membership).
local function sign_buf(bufnr, resolved)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%a[%w+.-]*://") then return end
  if vim.bo[bufnr].buftype ~= "" then return end
  local rel = "/" .. require("plurnk.state").get_relative_path(name)
  local effect = resolved.hidden[rel] and "hidden" or resolved.by_path[rel]
  place(bufnr, effect)
end

-- Fetch workspace.members → re-sign every visible project buffer. No cache: called
-- on BufEnter and after every membership change (pick/hide/view/repo/drop).
M.refresh = function(workspace)
  if not workspace then return end
  require("plurnk.client").send("workspace.members", {}, false, function(result)
    if type(result) ~= "table" then return end
    local by_path, hidden = {}, {}
    for _, m in ipairs(result.members or {}) do by_path[m.path] = m.effect end
    for _, p in ipairs(result.hidden or {}) do hidden[p] = true end
    local resolved = { by_path = by_path, hidden = hidden }
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      sign_buf(vim.api.nvim_win_get_buf(win), resolved)
    end
  end)
end

M.setup = function()
  M.setup_highlights()
  local grp = vim.api.nvim_create_augroup("PlurnkMembershipSigns", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = grp,
    callback = function()
      local workspace = require("plurnk.state").get_active_workspace_name()
      if workspace then M.refresh(workspace) end
    end,
  })
end

return M
