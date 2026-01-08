local M = {}

local popup_window = require("jujutsu-nvim.popup_window")

-- Define highlight group for prompt keys (yellow/orange)
vim.api.nvim_set_hl(0, "JJPromptKey", { fg = "#FFA500", bold = true })

--- @class DialogOption
--- @field key string Single key to trigger this option
--- @field label string Display label for the option
--- @field value any Value to pass to on_select callback

--- @class FloatingOptionsOpts
--- @field prompt string? Question to ask user
--- @field options DialogOption[] List of selectable options
--- @field on_select fun(option: DialogOption) Callback with the selected option
--- @field on_cancel function? Optional callback on cancel/escape

--- Show a floating window with single-key options
--- @param opts FloatingOptionsOpts
M.show_floating_options = function(opts)
  local prompt = opts.prompt or "Select an option:"
  local options = opts.options or {}

  -- Build content lines with padding and key highlighting
  local lines = { "" }

  -- Handle multi-line prompts by splitting and padding each line
  for line in vim.gsplit(prompt, "\n", { plain = true, trimempty = false }) do
    table.insert(lines, "  " .. line)
  end

  table.insert(lines, "")
  local highlights = {}  -- Track where to highlight keys
  for _, option in ipairs(options) do
    local line = string.format("    %s  %s", option.key:upper(), option.label)
    table.insert(lines, line)
    -- Track position of key for highlighting (accounting for padding)
    local line_idx = #lines - 1  -- 0-based index
    table.insert(highlights, {
      line = line_idx,
      col_start = 4,
      col_end = 4 + #option.key,
      hl_group = "JJPromptKey"
    })
  end

  -- Create popup window first
  local popup = popup_window.create({
    lines = lines,
    highlights = highlights,
    help_text = "    <Esc> or q to cancel",
    on_cancel = opts.on_cancel,
  })

  -- Add option keymaps after popup is created
  for _, option in pairs(options) do
    vim.keymap.set('n', option.key, function()
      popup.close()
      opts.on_select(option)
    end, { buffer = popup.buf, silent = true })
  end
end

--- Prompt for yes/no confirmation
--- @param prompt string Question to ask
--- @param on_confirm function? Callback if user confirms
--- @param on_cancel function? Optional callback if user cancels
M.confirm = function(prompt, on_confirm, on_cancel)
  M.show_floating_options({
    prompt = prompt,
    options = {
      { key = 'y', label = 'Yes', value = true },
      { key = 'n', label = 'No', value = false },
    },
    on_select = function(confirmed)
      if confirmed.value then
        if on_confirm then on_confirm() end
      else
        if on_cancel then on_cancel() end
      end
    end,
    on_cancel = on_cancel
  })
end

return M
