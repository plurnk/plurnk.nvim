-- The human's inspection ({§nvim-inspection}): `:AI/look <address> [scope] [pattern]`, `K` on
-- a waterfall row, or a typed LOOK fence — a READ for the human, never the model. The daemon's
-- `op.look` resolves it as the tab's conversation and mints no log row. The content opens in a
-- scratch split named for the address; an empty result says so; a Problem is a notice.

local M = {}

-- `worker:///plan.md <1,20> /needle/` → the LOOK fence with the address in its parentheses; an
-- address the user already parenthesized passes through. Nothing to look at is nil.
M.fence = function(rest)
  local text = vim.fn.trim(rest or "")
  if text == "" then return nil end
  local heading = text
  if text:sub(1, 1) ~= "(" then heading = text:gsub("^(%S+)", "(%1)", 1) end
  return "```LOOK " .. heading .. "```"
end

-- The heading as submitted, without its fence: `LOOK (worker:///plan.md) <1,20>`.
M.heading = function(text)
  local inner = text:gsub("^```+", ""):gsub("```+%s*$", "")
  return vim.fn.trim(inner:match("^[^\n]*") or "")
end

local function address_of(heading)
  return heading:match("%((.-)%)") or heading
end

local function scratch_name(address)
  return "plurnk-nvim://look/" .. address:gsub("[:/%%]", "_")
end

local function scratch_buffer(name)
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then return buf end
  buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  return buf
end

-- Open (or find) the split showing the buffer, below the current window, and read there.
local function show_in_split(buf, heading)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
  vim.cmd("belowright 12split")
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  pcall(vim.api.nvim_set_option_value, "winbar", " " .. heading .. " ", { win = win })
  return win
end

-- The readout for one op.look result: content into the split, an empty result's own words,
-- a Problem as a notice carrying its title, detail, and recovery.
M.show = function(text, result)
  local heading = M.heading(text)
  local status = type(result.status) == "number" and result.status or 0
  if status >= 400 then
    local problem = type(result.problem) == "table" and result.problem or {}
    local title = problem.title or result.detail or tostring(status)
    local message = heading .. " — " .. tostring(title)
    if type(problem.detail) == "string" and problem.detail ~= "" then message = message .. " — " .. problem.detail end
    if type(problem.recovery) == "string" and problem.recovery ~= "" then message = message .. "\n  " .. problem.recovery end
    require("plurnk.client").notify(message, vim.log.levels.WARN)
    return nil
  end
  local content = type(result.content) == "string" and result.content or ""
  local lines
  if content == "" then
    lines = { "(" .. tostring(result.detail or "empty") .. ")" }
  else
    lines = vim.split((content:gsub("\n$", "")), "\n", { plain = true })
  end
  local address = address_of(heading)
  local buf = scratch_buffer(scratch_name(address))
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local filetype = vim.filetype.match({ filename = address:match("[^/]+$") or address })
  if filetype ~= nil then pcall(function() vim.bo[buf].filetype = filetype end) end
  show_in_split(buf, heading)
  return buf
end

-- One LOOK fence, typed or composed, through op.look. A failed action is the bridge's notice;
-- an operation result, successful or not, is this module's readout.
M.inspect = function(text)
  require("plurnk.client").send("op.look", { text = text }, false, function(result)
    if type(result) ~= "table" then return end
    vim.schedule(function() M.show(text, result) end)
  end)
end

-- `:AI/look <address> [scope] [pattern]`.
M.run = function(rest)
  local text = M.fence(rest)
  if text == nil then
    require("plurnk.client").notify(":AI/look needs an address — :AI/help look", vim.log.levels.WARN)
    return
  end
  M.inspect(text)
end

-- `K` on a waterfall row: inspect that row's authored target.
M.at_cursor = function()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = require("plurnk.worker_tab").entry_at(buf, line)
  local target = entry ~= nil and require("plurnk.render").authored_target(entry) or nil
  if target == nil then
    require("plurnk.client").notify("no resource on this row to inspect", vim.log.levels.WARN)
    return
  end
  M.inspect(M.fence(target))
end

return M
