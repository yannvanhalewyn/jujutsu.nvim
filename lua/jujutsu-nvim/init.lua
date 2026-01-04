-- Custom jj integration for Neovim
--
-- Provides a simple interface for running jj commands and displaying results
-- in Neovim buffers with custom keymaps and highlighting.
--
-- Usage:
--   :JJ log           - Open interactive log view
--   :JJ <any command> - Run any jj command

local M = {}

-- Window and buffer tracking
M.jj_window = nil
M.jj_buffer = nil

-- Highlight group for jj log change lines
vim.api.nvim_set_hl(0, "JJLogChange", { link = "CursorLine" })

--------------------------------------------------------------------------------
-- Utils
local function remove(list, pred)
  local filtered = {}
  for _, v in ipairs(list) do
    if not pred(v) then
      table.insert(filtered, v)
    end
  end
  return filtered
end

--------------------------------------------------------------------------------
-- Multi Selection
--------------------------------------------------------------------------------

-- Selection state (set of change IDs)
M.selected_changes = {}

local ns_id = vim.api.nvim_create_namespace("jj_selections")

-- Clear all selections
local function clear_selections()
  M.selected_changes = {}
  if M.jj_buffer and vim.api.nvim_buf_is_valid(M.jj_buffer) then
    -- Clear all extmarks for selections
    vim.api.nvim_buf_clear_namespace(M.jj_buffer, ns_id, 0, -1)
  end
end

-- Toggle selection for a change
local function toggle_selection(change_id)
  if M.selected_changes[change_id] then
    M.selected_changes[change_id] = nil
  else
    M.selected_changes[change_id] = true
  end
end

-- Get list of selected change IDs
local function get_selected_ids()
  local ids = {}
  for id, _ in pairs(M.selected_changes) do
    table.insert(ids, id)
  end
  return ids
end

--------------------------------------------------------------------------------
-- Extracting changes from log output
--------------------------------------------------------------------------------

local function strip_ansi(str)
  return str:gsub("\27%[[0-9;]*m", "")
end

local function extract_change_id(line)
  local clean_line = strip_ansi(line)

  -- Try to extract change ID from jj log output
  -- Format: "◉  mrtwmypl yann.vanhalewyn@gmail.com 2026-01-03 22:53:01 02a96588"

  -- Pattern 1: Extract the first alphanumeric string after box-drawing/special chars
  local change_id = clean_line:match "^[^%w]*(%w+)%s+%S+@"

  -- Pattern 2: If that fails, try to get 8-char hex at the end of the line
  if not change_id then
    change_id = clean_line:match "(%x%x%x%x%x%x%x%x)%s*$"
  end

  -- Pattern 3: For lines with branch names, extract the first word
  if not change_id then
    change_id = clean_line:match "[│├└─╮╯]*%s*[◉○◆@]+%s+(%w+)"
  end

  return change_id
end

-- Extracts the change ID of the change at cursor, and when valid calls the
-- operation with it.
local function with_change_at_cursor(operation)
  local line = vim.api.nvim_get_current_line()
  local change_id = extract_change_id(line)

  if change_id and #change_id >= 4 then
    operation(change_id)
  else
    vim.notify("Could not find change ID on current line", vim.log.levels.WARN)
  end
end

--------------------------------------------------------------------------------
-- Floating prompt window
--------------------------------------------------------------------------------

-- Define highlight group for prompt keys (yellow/orange)
vim.api.nvim_set_hl(0, "JJPromptKey", { fg = "#FFA500", bold = true })

-- Show a floating window with single-key options
-- @param opts table with:
--   - prompt: string - question to ask user
--   - options: table - list of {key: string, label: string, value: any}
--   - on_select: function(value) - callback with selected option's value
--   - on_cancel: function() - optional callback on cancel/escape
local function show_floating_prompt(opts)
  local prompt = opts.prompt or "Select an option:"
  local options = opts.options or {}

  -- Build content lines with padding
  local lines = { "", "  " .. prompt, "" }
  local key_map = {}
  local key_highlights = {}  -- Track where to highlight keys

  for _, option in ipairs(options) do
    local line = string.format("    %s  %s", option.key, option.label)
    table.insert(lines, line)

    -- Track position of key for highlighting (accounting for padding)
    local line_idx = #lines - 1  -- 0-based index
    table.insert(key_highlights, { line = line_idx, col_start = 4, col_end = 4 + #option.key })

    key_map[option.key:lower()] = option.value or option.key
    -- Also support uppercase if provided
    key_map[option.key:upper()] = option.value or option.key
  end

  -- Add help text
  table.insert(lines, "")
  table.insert(lines, "    <Esc> or q to cancel")
  table.insert(lines, "")

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
  local function cleanup()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Restore cursor visibility
    vim.o.guicursor = original_guicursor
    vim.api.nvim_set_hl(0, 'Cursor', original_cursor_hl)
    vim.api.nvim_set_hl(0, 'lCursor', original_lcursor_hl)
  end

  -- Handle key press
  local function handle_key(key)
    local value = key_map[key]
    if value then
      cleanup()
      if opts.on_select then
        opts.on_select(value)
      end
      return true
    end
    return false
  end

  -- Cancel handler
  local function cancel()
    cleanup()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  -- Set up keymaps for each option key
  for key, _ in pairs(key_map) do
    vim.keymap.set('n', key, function()
      handle_key(key)
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
local function confirm(prompt, on_confirm, on_cancel)
  show_floating_prompt({
    prompt = prompt,
    options = {
      { key = 'Y', label = 'Yes', value = true },
      { key = 'N', label = 'No', value = false },
    },
    on_select = function(confirmed)
      if confirmed and on_confirm then
        on_confirm()
      elseif not confirmed and on_cancel then
        on_cancel()
      end
    end,
    on_cancel = on_cancel
  })
end

--------------------------------------------------------------------------------
-- Editor buffer
--------------------------------------------------------------------------------

-- Open an editor buffer meant to capture user input
-- @param opts table with:
--   - content: string - initial content
--   - filetype: string - buffer filetype
--   - extra_help_text: string - extra help text shown at bottom
--   - on_submit: function(content: string) - callback with user content (without help lines)
--   - on_abort: function() - optional callback on abort
local function open_editor_buffer(opts)
  local buf = vim.api.nvim_create_buf(false, false)
  local temp_file = vim.fn.tempname()

  -- Set buffer options
  vim.api.nvim_buf_set_name(buf, temp_file)
  vim.bo[buf].buftype = ''
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype or 'text'

  -- Set content
  local lines = vim.split(opts.content or "", "\n")
  if opts.extra_help_text then
    table.insert(lines, 1, opts.extra_help_text)
  end
  vim.list_extend(lines, {
    "JJ: <C-c><C-c> - confirm",
    "JJ: <C-c><C-k> - abort"
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Open buffer in a split
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * 0.4))
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  -- Submit and abort handlers
  local function submit()
    vim.cmd.stopinsert()
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_delete(buf, { force = true })
    if opts.on_submit then
      -- Filter out lines starting with "JJ:"
      local filtered_lines = remove(content, function(x) return x:match("^JJ:") end)
      local user_content = table.concat(filtered_lines, "\n")
      opts.on_submit(user_content)
    end
  end

  local function abort()
    -- Makes it so the cursor remains at top after edit buffer close
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
    if opts.on_abort then
      opts.on_abort()
    else
      vim.notify("Aborted", vim.log.levels.INFO)
    end
  end

  -- Setup keymaps
  local keymap_opts = function(desc)
    return { desc = desc, buffer = buf, silent = true }
  end

  vim.keymap.set("n", "<C-c><C-k>", abort, keymap_opts("JJ: Abort"))
  vim.keymap.set("i", "<C-c><C-k>", abort, keymap_opts("JJ: Abort"))
  vim.keymap.set("n", "<C-c><C-c>", submit, keymap_opts("JJ: Submit"))
  vim.keymap.set("i", "<C-c><C-c>", submit, keymap_opts("JJ: Submit"))

  -- Cleanup temp file
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() vim.fn.delete(temp_file) end
  })
end

--------------------------------------------------------------------------------
-- Basic Operations
--------------------------------------------------------------------------------

local jj = require("jujutsu-nvim.jujutsu")

local function new_change(change_id)
  jj.new_change(change_id, function()
    vim.notify("Created new change after " .. change_id, vim.log.levels.INFO)
    M.log()
  end)
end

local function describe(change_id)
  jj.get_changes_by_ids({ change_id }, function(changes)
    local description = changes[1].description
    open_editor_buffer({
      content = description,
      filetype = 'jjdescription',
      on_submit = function(new_description)
        jj.describe(change_id, new_description, function()
          vim.notify("Description updated for " .. change_id, vim.log.levels.INFO)
          M.log()
        end)
      end,
      on_abort = function()
        vim.notify("Aborted description edit", vim.log.levels.INFO)
      end
    })
  end)
end

local function abandon_change(change_id)
  confirm(
    string.format("Abandon change %s?", change_id:sub(1, 8)),
    function()
      jj.abandon_change(change_id, function()
        vim.notify("Abandoned change " .. change_id, vim.log.levels.INFO)
        M.log()
      end)
    end,
    function()
      vim.notify("Abandon cancelled", vim.log.levels.INFO)
    end)
end

local function edit_change(change_id)
  jj.edit_change(change_id, function()
    vim.notify("Checked out change " .. change_id, vim.log.levels.INFO)
    M.log()
  end)
end

--------------------------------------------------------------------------------
-- Rebase operations
--------------------------------------------------------------------------------

local function select_change(opts, cb)
  vim.notify(
    (opts.prompt or "Select destination change")
    .. " (navigate with j/k, <CR> to select, <Esc> to cancel)",
    vim.log.levels.INFO
  )

  local keymap_opts = { buffer = M.jj_buffer, silent = true }

  vim.keymap.set("n", "<CR>", function()
    with_change_at_cursor(function(change_id)
      print("CHANGE AT CURSOR", change_id)
      vim.keymap.del("n", "<CR>", { buffer = M.jj_buffer })
      vim.keymap.del("n", "<Esc>", { buffer = M.jj_buffer })
      cb(change_id)
    end)
  end, keymap_opts)

  vim.keymap.set("n", "<Esc>", function()
    vim.keymap.del("n", "<CR>", { buffer = M.jj_buffer })
    vim.keymap.del("n", "<Esc>", { buffer = M.jj_buffer })
    vim.notify("Selection cancelled", vim.log.levels.INFO)
  end, keymap_opts)
end

local function prompt_source_type(cb)
  local options = {}
  for _, source_type in ipairs(jj.rebase_source_types) do
    table.insert(options, {
      key = source_type.key,
      label = source_type.label,
      value = source_type
    })
  end

  show_floating_prompt({
    prompt = 'Rebase source type:',
    options = options,
    on_select = cb,
    on_cancel = function()
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
    end
  })
end

local function prompt_destination_type(cb)
  local options = {}
  for _, dest_type in ipairs(jj.rebase_destination_types) do
    table.insert(options, {
      key = dest_type.key,
      label = dest_type.label,
      value = dest_type
    })
  end

  show_floating_prompt({
    prompt = 'Rebase destination type:',
    options = options,
    on_select = cb,
    on_cancel = function()
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
    end
  })
end

local function execute_rebase(source_ids, source_type, dest_id, dest_type)
  local prompt = jj.build_rebase_confirmation_msg(source_ids, dest_type, dest_id)

  confirm(
    prompt,
    function()
      jj.execute_rebase(source_ids, source_type, dest_id, dest_type, function()
        clear_selections()
        M.log()
      end)
    end,
    function()
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
    end
  )
end

local function rebase_change()
  local source_ids = get_selected_ids()
  if #source_ids > 0 then

    with_change_at_cursor(function (dest_id)
      prompt_destination_type(function(dest_type)
        execute_rebase(source_ids, jj.rebase_source_types[1], dest_id, dest_type)
      end)
    end)
  else
    with_change_at_cursor(function(source_id)
      prompt_source_type(function(source_type)
        select_change({ prompt = "Select change to rebase onto" }, function(dest_id)
          prompt_destination_type(function(dest_type)
            execute_rebase({ source_id }, source_type, dest_id, dest_type)
          end)
        end)
      end)
    end)
  end
end

--------------------------------------------------------------------------------
-- Squash operations
--------------------------------------------------------------------------------

local function describe_and_squash_changes(source_ids, target_id)
  local all_change_ids = vim.list_extend({}, source_ids)
  table.insert(all_change_ids, target_id)

  jj.get_changes_by_ids(all_change_ids, function(changes)
    local change_descriptions = {}
    for _, change in ipairs(changes) do
      if vim.trim(change.description) ~= "" then
        table.insert(
          change_descriptions,
          string.format("JJ: %s\n%s", change.change_id, change.description)
        )
      end
    end

    open_editor_buffer({
      content = table.concat(change_descriptions, "\n"),
      filetype = 'jjdescription',
      extra_help_text = string.format(
        "JJ: Squashing %d %s into %s. Enter a description for the combined commit.",
        #source_ids, #source_ids == 1 and "change" or "changes", target_id
      ),

      on_submit = function(message)
        jj.execute_squash(source_ids, target_id, message, function()
          clear_selections()
          M.log()
        end)
      end,

      on_abort = function()
        vim.notify("Squash cancelled", vim.log.levels.INFO)
      end
    })
  end)
end

local function squash_change()
  with_change_at_cursor(function(change_id)
    local selected_ids = get_selected_ids()
    if #selected_ids > 0 then
      describe_and_squash_changes(selected_ids, change_id)
    else
      describe_and_squash_changes({ change_id }, change_id .. "-")
    end
  end)
end

-- Squash change into custom target
local function squash_to_target(change_id)
  select_change({ prompt = "Select target to squash into" }, function(target_id)
    describe_and_squash_changes({ change_id }, target_id)
  end)
end

--------------------------------------------------------------------------------
-- Selection UI
--------------------------------------------------------------------------------

-- Update visual indicators for selections
local function update_selection_display()
  vim.api.nvim_buf_clear_namespace(M.jj_buffer, ns_id, 0, -1)

  -- Add visual indicators for each selected change
  local lines = vim.api.nvim_buf_get_lines(M.jj_buffer, 0, -1, false)
  for i, line in ipairs(lines) do
    local change_id = extract_change_id(line)
    if change_id and M.selected_changes[change_id] then
      -- Add checkmark at the start of the line
      vim.api.nvim_buf_set_extmark(M.jj_buffer, ns_id, i - 1, 0, {
        virt_text = {{ "✓ ", "DiffAdd" }},
        virt_text_pos = "overlay",
      })
      -- Highlight the line
      vim.api.nvim_buf_add_highlight(M.jj_buffer, ns_id, "Visual", i - 1, 0, -1)
    end
  end

  -- Update status message
  local count = #get_selected_ids()
  if count > 0 then
    vim.notify(string.format("%d change%s selected", count, count == 1 and "" or "s"), vim.log.levels.INFO)
  end
end

-- Toggle selection on current line
local function toggle_selection_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local change_id = extract_change_id(line)

  if change_id then
    toggle_selection(change_id)
    update_selection_display()
  else
    vim.notify("Could not find change ID on current line", vim.log.levels.WARN)
  end
end

--------------------------------------------------------------------------------
-- Log view and keymaps
--------------------------------------------------------------------------------

local terminal_buffer = require("jujutsu-nvim.terminal_buffer")

-- Cleanup jj window and buffer
local function close_jj_window()
  if M.jj_buffer and vim.api.nvim_buf_is_valid(M.jj_buffer) then
    vim.api.nvim_buf_delete(M.jj_buffer, { force = true })
  end
  if M.jj_window and vim.api.nvim_win_is_valid(M.jj_window) then
    vim.api.nvim_win_close(M.jj_window, true)
  end
  M.jj_buffer = nil
  M.jj_window = nil
end

local function setup_log_keymaps(buf)
  local opts = { buffer = buf, silent = true }

  -- Helper to create keymap with description
  local function map(key, action, desc)
    vim.keymap.set("n", key, action, vim.tbl_extend("force", opts, { desc = "JJ: " .. desc }))
  end


  -- Navigation
  map("q", close_jj_window, "Close window")
  map("j", "2j", "Move down 2 lines")
  map("k", "2k", "Move up 2 lines")

  -- Open difftastic for change under cursor
  map("<CR>", function()
    with_change_at_cursor(function(change_id)
      vim.cmd("tabnew")
      vim.cmd("Difft " .. change_id)
    end)
  end, "Open Difft for change")

  -- Change operations
  map("R", M.log, "Refresh log")
  map("d", function() with_change_at_cursor(describe) end, "Describe change")
  map("n", function() with_change_at_cursor(new_change) end, "New change after this")
  map("a", function() with_change_at_cursor(abandon_change) end, "Abandon change")
  map("e", function() with_change_at_cursor(edit_change) end, "Edit (check out) change")
  map("r", rebase_change, "Rebase change")
  map("s", squash_change, "Squash change")
  map("S", function() with_change_at_cursor(squash_to_target) end, "Squash into target")

  -- Multi-select
  map("m", toggle_selection_at_cursor, "Toggle selection")
  map("c", function()
    clear_selections()
    update_selection_display()
    vim.notify("Cleared all selections", vim.log.levels.INFO)
  end, "Clear selections")
end

local function run_in_jj_window(args, title, setup_keymaps_fn)
  close_jj_window()
  terminal_buffer.run_command_in_new_terminal_window(args, {
    title = title,
    on_ready = function(window, buffer)
      M.jj_buffer = buffer
      M.jj_window = window
      setup_keymaps_fn(buffer, window)
    end,
    on_close = function()
      M.jj_window = nil
      M.jj_buffer = nil
    end
  })
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Open jj log
function M.log(args)
  args = args or {}
  local log_args = { "log" }
  vim.list_extend(log_args, args)
  run_in_jj_window(log_args, "JJ Log", setup_log_keymaps)
end

-- Run any jj command interactively
function M.run(args_str)
  if not args_str or args_str == "" then
    vim.ui.input({ prompt = "jj command: " }, function(input)
      if input then M.run(input) end
    end)
    return
  end

  local args = vim.split(args_str, "%s+")

  run_in_jj_window(args, "JJ: " .. args_str, function(buf)
    vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true, desc = "JJ: Close window" })
  end)
end

return M
