-- Minimal statusline. Reports the session name (if attached) and the
-- model alias picked for next loop.run, if any.
local M = {}
local state = require("plurnk.state")

M.text = function()
  local buf = vim.api.nvim_get_current_buf()
  local session = vim.b[buf].plurnk_session
  if not session then return "" end
  local parts = { "plurnk[" .. session .. "]" }
  local model = state.get_model_alias(session)
  if model then parts[#parts+1] = "model=" .. model end
  local loop_id = state.get_current_loop_id(session)
  if loop_id then parts[#parts+1] = "loop=" .. tostring(loop_id) end
  local final = state.get_final_status(session)
  if final then parts[#parts+1] = "status=" .. tostring(final) end
  return table.concat(parts, " ")
end

M.setup_highlights = function() end
return M
