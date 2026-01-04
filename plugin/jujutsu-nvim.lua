-- Auto-setup for jujutsu.nvim
-- This file is automatically loaded by Neovim when the plugin is installed
vim.api.nvim_create_user_command("JJ", function(opts)
  local jj = require("jujutsu-nvim")
  if opts.args == "" or opts.args == "log" then
    jj.log()
  else
    jj.run(opts.args)
  end
end, { nargs = "*", desc = "Run jj commands" })
