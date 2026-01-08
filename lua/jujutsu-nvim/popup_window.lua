local M = {}

--- @class PopupHighlight
--- @field line number 0-based line index
--- @field col_start number Starting column (0-based)
--- @field col_end number Ending column (-1 for end of line)
--- @field hl_group string Highlight group name

--- @class PopupWindowOpts
--- @field lines string[]? Array of strings to display in the window
--- @field highlights PopupHighlight[]? Array of highlight specifications
--- @field title string? Window title (defaults to " JJ ")
--- @field position "center"|"bottom_right"? Window position (defaults to "center")
--- @field on_cancel function? Callback when window is cancelled/closed
--- @field help_text string? Help text to show at bottom (defaults to "<Esc> or q to close")

--- @class PopupWindow
--- @field win number Window handle
--- @field buf number Buffer handle
--- @field close function Cleanup function to close the popup

--- Creates a floating popup window with common styling
--- @param opts PopupWindowOpts Options for the popup window
--- @return PopupWindow
M.create = function(opts)
  local lines = opts.lines or {}
  local highlights = opts.highlights or {}
  local title = opts.title or " JJ "
  local position = opts.position or "center"
  local on_cancel = opts.on_cancel
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

  -- Calculate window position
  local row, col
  if position == "bottom_right" then
    -- Position in bottom right corner with some padding
    row = vim.o.lines - height - 3  -- 3 lines from bottom (for cmdline + padding)
    col = vim.o.columns - width - 2  -- 2 columns from right edge
  else
    -- Center the window (default)
    row = math.floor((vim.o.lines - height) / 2)
    col = math.floor((vim.o.columns - width) / 2)
  end

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

  -- Track whether the window was closed programmatically
  -- This is needed to distinguish between a command closing the window,
  -- or the window losing focus. In cases the window lost focus we need to
  -- call the on_cancel handler.
  local closed_programmatically = false

  -- Cleanup function
  local function close()
    closed_programmatically = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Restore cursor visibility
    vim.o.guicursor = original_guicursor
    vim.api.nvim_set_hl(0, 'Cursor', original_cursor_hl)
    vim.api.nvim_set_hl(0, 'lCursor', original_lcursor_hl)
  end

  local function cancel()
    close()
    if on_cancel then
      on_cancel()
    end
  end

  -- Default keybindings to close
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })

  -- Auto-close on buffer leave (when focus moves away)
  -- Only trigger cancel if the window wasn't closed programmatically
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      if not closed_programmatically then
        cancel()
      end
    end
  })

  return {
    win = win,
    buf = buf,
    close = close
  }
end

return M
