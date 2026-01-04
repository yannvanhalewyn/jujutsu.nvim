local M = {}

-- Define highlight group for prompt keys (yellow/orange)
vim.api.nvim_set_hl(0, "JJPromptKey", { fg = "#FFA500", bold = true })

-- Show a floating window with single-key options
-- @param opts table with:
--   - prompt: string - question to ask user
--   - options: table - list of {key: string, label: string, value: any}
--   - on_select: function(option) - callback with the selected option
--   - on_cancel: function() - optional callback on cancel/escape
M.show_floating_options = function(opts)
  local prompt = opts.prompt or "Select an option:"
  local options = opts.options or {}

  -- Build content lines with padding and key highlighting
  local lines = { "", "  " .. prompt, "" }
  local key_highlights = {}  -- Track where to highlight keys
  for _, option in ipairs(options) do
    local line = string.format("    %s  %s", option.key:upper(), option.label)
    table.insert(lines, line)
    -- Track position of key for highlighting (accounting for padding)
    local line_idx = #lines - 1  -- 0-based index
    table.insert(key_highlights, { line = line_idx, col_start = 4, col_end = 4 + #option.key })
  end

  -- Add help text
  table.insert(lines, "")
  table.insert(lines, "    <Esc> or q to cancel")

  -- Calculate window size (accounting for padding)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.8))
  local height = #lines

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  -- Calculate window position (centered)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' JJ ',
    title_pos = 'center',
  })

  -- Hide cursor completely
  vim.api.nvim_win_set_option(win, 'cursorline', false)
  vim.api.nvim_win_set_option(win, 'cursorcolumn', false)

  -- Store original guicursor to restore later
  local original_guicursor = vim.o.guicursor

  -- Multiple approaches to hide cursor for maximum compatibility:
  -- 1. Set cursor highlight to reverse video (makes it invisible on most backgrounds)
  local original_cursor_hl = vim.api.nvim_get_hl(0, { name = 'Cursor' })
  local original_lcursor_hl = vim.api.nvim_get_hl(0, { name = 'lCursor' })
  vim.api.nvim_set_hl(0, 'Cursor', { reverse = false, blend = 100 })
  vim.api.nvim_set_hl(0, 'lCursor', { reverse = false, blend = 100 })

  -- 2. Hide guicursor
  vim.o.guicursor = 'a:hor1-Cursor/lCursor'

  -- Apply highlighting to keys
  for _, hl in ipairs(key_highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, 'JJPromptKey', hl.line, hl.col_start, hl.col_end)
  end

  -- Apply highlighting to help text
  local help_line = #lines - 2
  vim.api.nvim_buf_add_highlight(buf, -1, 'Comment', help_line, 0, -1)

  -- Cleanup function
  local function close_popup()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Restore cursor visibility
    vim.o.guicursor = original_guicursor
    vim.api.nvim_set_hl(0, 'Cursor', original_cursor_hl)
    vim.api.nvim_set_hl(0, 'lCursor', original_lcursor_hl)
  end

  -- Cancel handler
  local function cancel()
    close_popup()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  -- Set up keymaps for each option key
  for _, option in pairs(options) do
    vim.keymap.set('n', option.key, function()
      close_popup()
      opts.on_select(option)
    end, { buffer = buf, silent = true })
  end

  -- Escape to cancel
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', cancel, { buffer = buf, silent = true })

  -- Auto-close on buffer leave
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    once = true,
    callback = cancel
  })
end

-- Prompt for yes/no confirmation
-- @param prompt string - question to ask (without the y/N suffix)
-- @param on_confirm function() - callback if user confirms
-- @param on_cancel function() - optional callback if user cancels
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
