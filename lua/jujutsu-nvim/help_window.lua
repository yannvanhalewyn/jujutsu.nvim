local M = {}

local help_groups = {
  { key = "help", name = "Help" },
  { key = "navigation", name = "Navigation" },
  { key = "log", name = "Log" },
  { key = "basic_operations", name = "Basic Operations" },
  { key = "advanced_operations", name = "Advanced Operations" },
  { key = "bookmarks", name = "Bookmarks" },
  { key = "multi_selection", name = "Multi-Selection" },
  { key = "custom", name = "Custom" },
}

local action_help_info = {
  show_help = { group = "help", order = 1 },

  jump_to_next_change = { group = "navigation", order = 1 },
  jump_to_prev_change = { group = "navigation", order = 2 },

  quit = { group = "log", order = 1 },
  refresh = { group = "log", order = 2 },
  set_revset = { group = "log", order = 3 },

  open_diff = { group = "navigation", order = 3 },

  describe = { group = "basic_operations", order = 1 },
  new_change = { group = "basic_operations", order = 2 },
  abandon_changes = { group = "basic_operations", order = 3 },
  edit_change = { group = "basic_operations", order = 4 },
  undo = { group = "basic_operations", order = 5 },

  rebase_change = { group = "advanced_operations", order = 1 },
  squash_change = { group = "advanced_operations", order = 2 },
  squash_to_target = { group = "advanced_operations", order = 3 },

  bookmark_change = { group = "bookmarks", order = 1 },
  bookmark_menu = { group = "bookmarks", order = 2 },
  push_bookmarks = { group = "bookmarks", order = 3 },
  push_bookmarks_and_create = { group = "bookmarks", order = 4 },

  toggle_change = { group = "multi_selection", order = 1 },
  clear_selections = { group = "multi_selection", order = 2 },
}

---@param keymap table - The selected keymap configuration
M.show = function(keymap)
  -- Group keybinds using action_help_info metadata
  local grouped_keybinds = {}
  for key, binding in pairs(keymap) do
    if type(binding) == "table" then
      local cmd = binding.cmd
      local group, order

      -- Look up metadata for this action
      if type(cmd) == "string" and action_help_info[cmd] then
        group = action_help_info[cmd].group
        order = action_help_info[cmd].order
      else
        -- Custom function or unmapped action
        group = "custom"
        order = 999  -- Will sort alphabetically within custom group
      end

      if not grouped_keybinds[group] then
        grouped_keybinds[group] = {}
      end
      table.insert(grouped_keybinds[group], {
        key = key,
        desc = binding.desc,
        cmd = cmd,
        order = order,
      })
    end
  end

  -- Build help text with padding
  local lines = { "" }
  local highlights = {}  -- Track highlighting positions

  -- Display groups in order
  for _, help_group in ipairs(help_groups) do
    local bindings = grouped_keybinds[help_group.key]
    if bindings and #bindings > 0 then
      local group_label = "  " .. help_group.name
      table.insert(lines, group_label)
      local group_line_idx = #lines - 1
      table.insert(highlights, { line = group_line_idx, col_start = 0, col_end = -1, hl_group = "Title" })

      -- Sort bindings by order, then by key for custom bindings
      table.sort(bindings, function(a, b)
        if a.order ~= b.order then
          return a.order < b.order
        end
        return a.key < b.key
      end)

      -- Add each binding with padding
      for _, binding in ipairs(bindings) do
        local key_display = string.format("%-10s", binding.key)
        local line = string.format("    %s  %s", key_display, binding.desc)
        table.insert(lines, line)

        -- Highlight the key (similar to dialog_window)
        local line_idx = #lines - 1  -- 0-based
        table.insert(highlights, {
          line = line_idx,
          col_start = 4,
          col_end = 4 + #binding.key,
          hl_group = "JJPromptKey"
        })
      end

      table.insert(lines, "")
    end
  end

  -- Add help text
  table.insert(lines, "    <Esc> or q to close")
  local help_line_idx = #lines - 1
  table.insert(highlights, { line = help_line_idx, col_start = 0, col_end = -1, hl_group = "Comment" })
  table.insert(lines, "")

  -- Create a floating window for the help
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

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " JJ Help ",
    title_pos = "center",
  })

  -- Set window-local options (no cursorline to match dialog_window)
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
  local function close_help()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Restore cursor visibility
    vim.o.guicursor = original_guicursor
    vim.api.nvim_set_hl(0, 'Cursor', original_cursor_hl)
    vim.api.nvim_set_hl(0, 'lCursor', original_lcursor_hl)
  end

  -- Keybindings for the help window
  vim.keymap.set("n", "q", close_help, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_help, { buffer = buf, silent = true })

  -- Auto-close on buffer leave (when focus moves away)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = close_help
  })
end

return M
