-- Chat input scratch buffer. Triggered by `:AI` with no args (mirrors
-- rummy.nvim/main/lua/rummy/input.lua). Anchored bottom-split, single-
-- line by default; <CR> in normal mode submits via loop.run.

local M = {}
local INPUT_HEIGHT = 3

local function buffer_name(session_name)
  return "plurnk://input/" .. (session_name or "scratch")
end

local function submit(buf, session_name)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = vim.fn.trim(table.concat(lines, "\n"))
  if text == "" then return end

  -- Strip rummy mode prefixes that users still reach for out of habit
  -- (?, :, ! — plurnk has no modes, the model decides what ops to emit).
  text = text:gsub("^[%?%:%!]+%s*", "")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local commands = require("plurnk.commands")
  commands.prompt({ args = text, range = 0 })
end

M.open = function(session_name)
  -- Reuse existing input buffer for this session if there is one.
  local existing = vim.fn.bufnr(buffer_name(session_name))
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    -- Find a window showing it; if none, create the bottom split.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == existing then
        vim.api.nvim_set_current_win(w)
        vim.cmd("startinsert")
        return existing
      end
    end
    vim.cmd("botright " .. INPUT_HEIGHT .. "split")
    vim.api.nvim_win_set_buf(0, existing)
    vim.cmd("startinsert")
    return existing
  end

  vim.cmd("botright " .. INPUT_HEIGHT .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, buffer_name(session_name))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_win_set_buf(win, buf)

  vim.wo[win].wrap = true
  vim.wo[win].winfixheight = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  pcall(vim.api.nvim_set_option_value, "winbar",
    " plurnk · type prompt · <CR> submit · <Esc> close ",
    { win = win })

  if session_name then vim.b[buf].plurnk_session = session_name end

  vim.keymap.set("n", "<CR>", function() submit(buf, session_name) end,
    { buffer = buf, silent = true, desc = "Plurnk: submit prompt" })
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    submit(buf, session_name)
  end, { buffer = buf, silent = true, desc = "Plurnk: submit prompt (insert)" })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true, desc = "Plurnk: close input" })

  vim.cmd("startinsert")
  return buf
end

return M
