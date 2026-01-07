local M = {}

-- Creates a centered floating popup window with common styling
-- @param opts table with:
--   - lines: table - array of strings to display in the window
--   - highlights: table - array of {line, col_start, col_end, hl_group} for syntax highlighting
--   - title: string - window title (default: " JJ ")
--   - on_close: function - callback when window closes (optional)
--   - extra_keymaps: table - additional keymaps like { key = function() end } (optional)
--   - help_text: string - help text to show at bottom (default: "<Esc> or q to close")
-- @return table with { win, buf, close } where close() is the cleanup function
M.create = function(opts)
  local lines = opts.lines or {}
  local highlights = opts.highlights or {}
  local title = opts.title or " JJ "
  local on_close = opts.on_close
  local extra_keymaps = opts.extra_keymaps or {}
  local help_text = opts.help_text or "    <Esc> or q to close"

  -- Add help text at the bottom
  table.insert(lines, "")
  table.insert(lines, help_text)
  local help_line_idx = #lines - 1  -- 0-based index, help_text is the last line we added
  table.insert(highlights, { line = help_line_idx, col_start = 0, col_end = -1, hl_group = "Comment" })
  table.insert(lines, "")

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  -- Calculate window size
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.8))
  local height = #lines

  -- Center the window
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  -- Set window-local options
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", false, { win = win })
  vim.api.nvim_set_option_value("cursorcolumn", false, { win = win })

  -- Hide cursor completely
  local original_guicursor = vim.o.guicursor
  local original_cursor_hl = vim.api.nvim_get_hl(0, { name = 'Cursor' })
  local original_lcursor_hl = vim.api.nvim_get_hl(0, { name = 'lCursor' })

  vim.api.nvim_set_hl(0, 'Cursor', { reverse = false, blend = 100 })
  vim.api.nvim_set_hl(0, 'lCursor', { reverse = false, blend = 100 })
  vim.o.guicursor = 'a:hor1-Cursor/lCursor'

  -- Apply all highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end

  -- TODO: Fix cursor hiding properly (current method doesn't fully work)
  -- For now, also move cursor to last line (empty line) to keep it out of sight
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  -- Cleanup function
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Restore cursor visibility
    vim.o.guicursor = original_guicursor
    vim.api.nvim_set_hl(0, 'Cursor', original_cursor_hl)
    vim.api.nvim_set_hl(0, 'lCursor', original_lcursor_hl)
    
    if on_close then
      on_close()
    end
  end

  -- Default keybindings to close
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })

  -- Add extra keymaps
  for key, handler in pairs(extra_keymaps) do
    vim.keymap.set("n", key, handler, { buffer = buf, silent = true })
  end

  -- Auto-close on buffer leave (when focus moves away)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = close
  })

  return {
    win = win,
    buf = buf,
    close = close
  }
end

return M
