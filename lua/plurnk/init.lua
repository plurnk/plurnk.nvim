local M = {}

M.setup = function(opts)
  local cfg = require("plurnk.config")
  cfg.setup(opts)
  require("plurnk.commands").setup()
  require("plurnk.run_tab").setup()
  require("plurnk.statusline").setup_highlights()
  require("plurnk.hud").setup_highlights()

end

M.apply_default_keymaps = function()
  require("plurnk.keymaps").setup()
end

M.statusline = require("plurnk.statusline").text

return M
