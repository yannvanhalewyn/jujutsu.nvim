local M = {}

local popup_window = require("jujutsu-nvim.popup_window")

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
---@param position string - Window position: "center" or "bottom_right"
M.show = function(keymap, position)
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

  -- Create popup window with all the content
  popup_window.create({
    lines = lines,
    highlights = highlights,
    title = " JJ Help ",
    position = position
  })
end

return M
