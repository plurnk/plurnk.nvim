local M = {}

-- Raw selected text (no XML wrapper) — `:AI!` execs the selected lines
-- verbatim; wrapping a shell command in <selection> would corrupt it.
function M.get_selection_text(start_pos, end_pos, forced_mode)
  local wrapped = M.get_selection(start_pos, end_pos, forced_mode)
  if not wrapped then return nil end
  return wrapped:match("^<selection[^>]*>\n(.*)\n</selection>$")
end

function M.get_selection(start_pos, end_pos, forced_mode)
  local mode = forced_mode or vim.fn.mode()
  -- If we're in command mode but came from visual, use marks
  if mode == "c" or mode == "n" then
    mode = forced_mode or vim.fn.visualmode()
  end

  start_pos = start_pos or vim.fn.getpos("'<")
  end_pos = end_pos or vim.fn.getpos("'>")
  
  -- If marks are not set (e.g. called from normal mode), return nil
  if start_pos[2] == 0 or end_pos[2] == 0 then return nil end

  local r1, c1 = start_pos[2], start_pos[3]
  local r2, c2 = end_pos[2], end_pos[3]

  -- Normalize range (visual mode can have end before start)
  if r1 > r2 or (r1 == r2 and c1 > c2) then
    r1, r2 = r2, r1
    c1, c2 = c2, c1
  end

  local lines = vim.api.nvim_buf_get_lines(0, r1 - 1, r2, false)
  if #lines == 0 then return nil end

  local selected_text = ""
  if mode == "v" then
    -- Characterwise
    if #lines == 1 then
      selected_text = lines[1]:sub(c1, c2)
    else
      lines[1] = lines[1]:sub(c1)
      lines[#lines] = lines[#lines]:sub(1, c2)
      selected_text = table.concat(lines, "\n")
    end
  elseif mode == "V" then
    -- Linewise
    selected_text = table.concat(lines, "\n")
    c1, c2 = 1, #lines[#lines]
  elseif mode == "\22" then
    -- Blockwise (CTRL-V)
    local block_lines = {}
    for _, line in ipairs(lines) do
      local sc, ec = c1, c2
      if sc > ec then sc, ec = ec, sc end
      table.insert(block_lines, line:sub(sc, ec))
    end
    selected_text = table.concat(block_lines, "\n")
  end

  if selected_text == "" then return nil end

  local client = require("plurnk.client")
  local abs_path = vim.api.nvim_buf_get_name(0)
  local rel_path = client.get_relative_path(abs_path)
  local is_modified = vim.bo.modified

  if is_modified then
    return string.format(
      '<selection file="%s" modified="true">\n%s\n</selection>',
      rel_path, selected_text
    )
  else
    return string.format(
      '<selection file="%s" first_row="%d" first_col="%d" final_row="%d" final_col="%d">\n%s\n</selection>',
      rel_path, r1, c1, r2, c2, selected_text
    )
  end
end

return M
