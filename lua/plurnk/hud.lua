-- HUD overlay stub. v0.1 just routes show() to vim.notify; the rich
-- virtual-text HUD from rummy is next-pass scope.
local M = {}
M.show = function(msg) if msg and msg ~= "" then vim.notify(msg, vim.log.levels.INFO) end end
M.clear_all_virtual_text = function() end
M.mark_buffer = function(_, _) end
M.setup_highlights = function() end
return M
