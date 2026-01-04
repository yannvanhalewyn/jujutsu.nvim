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

-- Clear all selections
local function clear_selections()
  M.selected_changes = {}
  if M.jj_buffer and vim.api.nvim_buf_is_valid(M.jj_buffer) then
    -- Clear all extmarks for selections
    local ns_id = vim.api.nvim_create_namespace("jj_selections")
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

-- Get count of selected changes
local function get_selection_count()
  local count = 0
  for _ in pairs(M.selected_changes) do
    count = count + 1
  end
  return count
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
-- Utilities
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

-- Run a jj command and handle result with callback
local function run_jj_command(args, on_success, on_error)
  local result = vim.system(args, { text = true }):wait()

  if result.code == 0 then
    if on_success then on_success(result) end
  else
    if on_error then
      on_error(result)
    else
      vim.notify("Command failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end
  end
end

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

--------------------------------------------------------------------------------
-- Jujutsu API
--------------------------------------------------------------------------------

local function jj_make_revset(change_ids)
  return table.concat(change_ids, " | ")
end

local function jj_get_changes(revset, callback)
  local template = 'separate(";", change_id.short(), coalesce(description, " ")) ++ "\n---END-CHANGE---\n"'

  run_jj_command(
    { "jj", "log", "--no-graph", "-r", revset, "-T", template },
    function(result)
      local output = result.stdout or ""
      local changes = {}

      -- Split by end-of-change separator
      for change_block in output:gmatch("(.-)\n%-%-%-END%-CHANGE%-%-%-\n") do
        if change_block ~= "" then
          -- Split on first semicolon only (to handle multiline descriptions)
          local change_id, description = change_block:match("^([^;]*);(.*)$")
          if change_id then
            -- Trim the change_id and preserve description as-is (including newlines)
            change_id = change_id:gsub("^%s*(.-)%s*$", "%1")
            table.insert(changes, {
              change_id = change_id,
              description = description
            })
          end
        end
      end

      callback(changes)
    end,
    function(result)
      vim.notify("Failed to get changes: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end
  )
end

local function jj_get_changes_by_ids(change_ids, callback)
  jj_get_changes(jj_make_revset(change_ids), function(changes)
    if #changes ~= #change_ids then
      vim.notify("Could not get change information", vim.log.levels.ERROR)
      return
    end
    callback(changes)
  end)
end

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

local function describe(change_id)
  jj_get_changes_by_ids({ change_id }, function(changes)
    local description = changes[1].description
    open_editor_buffer({
      content = description,
      filetype = 'jjdescription',
      on_submit = function(new_description)
        run_jj_command(
          { "jj", "describe", "-r", change_id, "-m", new_description },
          function()
            vim.notify("Description updated for " .. change_id:sub(1, 8), vim.log.levels.INFO)
            M.log()
          end
        )
      end,
      on_abort = function()
        vim.notify("Aborted description edit", vim.log.levels.INFO)
      end
    })
  end)
end

local function new_change(change_id)
  run_jj_command(
    { "jj", "new", change_id },
    function()
      vim.notify("Created new change after " .. change_id, vim.log.levels.INFO)
      M.log()
    end
  )
end

local function abandon_change(change_id)
  vim.ui.input({
    prompt = string.format("Abandon change %s? (y/N): ", change_id:sub(1, 8))
  }, function(input)
    if not input or (input:lower() ~= "y" and input:lower() ~= "yes") then
      vim.notify("Abandon cancelled", vim.log.levels.INFO)
      return
    end

    run_jj_command(
      { "jj", "abandon", change_id },
      function()
        vim.notify("Abandoned change " .. change_id, vim.log.levels.INFO)
        M.log()
      end
    )
  end)
end

local function edit_change(change_id)
  run_jj_command(
    { "jj", "edit", change_id },
    function()
      vim.notify("Checked out change " .. change_id, vim.log.levels.INFO)
      M.log()
    end
  )
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

local rebase_source_types = {
  { label = 'Revision (single change)', flag = '-r' },
  { label = 'Source (subtree - change + descendants)', flag = '-s' },
  { label = 'Branch (all revisions in branch)', flag = '-b' },
}

local function prompt_source_type(cb)
  vim.ui.select(rebase_source_types, {
    prompt = 'Rebase source type:',
    format_item = function(item)
      return string.format('%s - %s', item.key, item.label)
    end
  }, function(choice)
    if not choice then
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
      return
    end
    cb(choice)
  end)
end

local rebase_destination_types = {
  {
    label = 'Destination (onto - default)',
    flag = '-d',
    preposition = 'onto'
  },
  {
    label = 'After destination',
    flag = '-A',
    preposition = 'after'
  },
  {
    label = 'Before destination',
    flag = '-B',
    preposition = 'before'
  },
}

local function prompt_destination_type(cb)
  vim.ui.select(rebase_destination_types, {
    prompt = 'Rebase destination type:',
    format_item = function(item)
      return string.format('%s - %s', item.key, item.label)
    end
  }, function(choice)
    if not choice then
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
      return
    end
    cb(choice)
  end)
end

local function execute_rebase(source_ids, source_type, dest_id, dest_type)
  local args = { "jj", "rebase" }

  -- Add all selected changes as -r arguments
  for _, change_id in ipairs(source_ids) do
    table.insert(args, source_type.flag)
    table.insert(args, change_id)
  end

  -- Add destination args
  table.insert(args, dest_type.flag)
  table.insert(args, dest_id)

  local count = #source_ids

  -- Build confirmation message
  local ids_preview = count <= 3
    and table.concat(vim.tbl_map(function(id) return id:sub(1, 8) end, source_ids), ", ")
    or string.format("%s, ... (%d total)", source_ids[1]:sub(1, 8), count)

  local confirm_msg = string.format(
    "Rebase %d change%s [%s] %s %s? (y/N): ",
    count,
    count == 1 and "" or "s",
    ids_preview,
    dest_type.preposition,
    dest_id:sub(1, 8)
  )

  vim.ui.input({ prompt = confirm_msg }, function(input)
    if not input or (input:lower() ~= "y" and input:lower() ~= "yes") then
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
      return
    end

    run_jj_command(args, function()
      vim.notify(string.format(
        "Rebased %d change%s %s %s",
        count,
        count == 1 and "" or "s",
        dest_type.preposition,
        dest_id:sub(1, 8)
      ), vim.log.levels.INFO)
      clear_selections()
      M.log()
    end, function(result)
      vim.notify("Rebase failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end)
  end)
end

local function rebase_change()
  if get_selection_count() > 0 then
    local source_ids = get_selected_ids()

    with_change_at_cursor(function (dest_id)
      prompt_destination_type(function(dest_type)
        execute_rebase(source_ids, rebase_source_types[1], dest_id, dest_type)
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
  local source_count = #source_ids
  local all_change_ids = vim.list_extend({}, source_ids)
  table.insert(all_change_ids, target_id)

  jj_get_changes_by_ids(all_change_ids, function(changes)
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
        source_count,
        source_count == 1 and "change" or "changes",
        target_id
      ),

      on_submit = function(message)
        local from_revset = jj_make_revset(source_ids)
        run_jj_command(
          { "jj", "squash", "--from", from_revset, "--into", target_id, "-m", message },
          function()
            vim.notify(string.format(
              "Squashed %d %s into %s",
              source_count, source_count == 1 and "change" or "changes",
              target_id
            ), vim.log.levels.INFO)
            clear_selections()
            M.log()
          end,
          function(result)
            vim.notify("Squash failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
          end
        )
      end,

      on_abort = function()
        vim.notify("Squash cancelled", vim.log.levels.INFO)
      end
    })
  end)
end

local function squash_change()
  with_change_at_cursor(function(change_id)
    if get_selection_count() > 0 then
      local selected_ids = get_selected_ids()
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
  if not M.jj_buffer or not vim.api.nvim_buf_is_valid(M.jj_buffer) then
    return
  end

  local ns_id = vim.api.nvim_create_namespace("jj_selections")
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
  local count = get_selection_count()
  if count > 0 then
    vim.notify(string.format("%d change%s selected", count, count == 1 and "" or "s"), vim.log.levels.INFO)
  end
end

-- Toggle selection on current line
local function toggle_selection_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local change_id = extract_change_id(line)

  if change_id and #change_id >= 4 then
    toggle_selection(change_id)
    update_selection_display()
  else
    vim.notify("Could not find change ID on current line", vim.log.levels.WARN)
  end
end

--------------------------------------------------------------------------------
-- Log view and keymaps
--------------------------------------------------------------------------------

local function setup_log_keymaps(buf, original_window)
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
      if original_window and vim.api.nvim_win_is_valid(original_window) then
        vim.api.nvim_set_current_win(original_window)
      end
      vim.cmd("DifftTab " .. change_id)
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

--------------------------------------------------------------------------------
-- Terminal command execution
--------------------------------------------------------------------------------

function M.run_command_in_terminal(args, title, setup_keymaps_fn)
  close_jj_window()

  local cmd_args = { "jj", "--no-pager", "--color=always" }
  vim.list_extend(cmd_args, args)

  -- Build shell command
  local cmd_str = table.concat(vim.tbl_map(vim.fn.shellescape, cmd_args), " ")
  local shell_cmd = "sh -c " .. vim.fn.shellescape(cmd_str)

  -- Save original window
  local original_window = vim.api.nvim_get_current_win()

  -- Create terminal buffer
  vim.cmd("botright split term://" .. vim.fn.fnameescape(shell_cmd))

  M.jj_buffer = vim.api.nvim_get_current_buf()
  M.jj_window = vim.api.nvim_get_current_win()

  pcall(vim.api.nvim_buf_set_name, M.jj_buffer, title or "[JJ]")
  vim.api.nvim_win_set_height(M.jj_window, math.floor(vim.o.lines * 0.4))

  if setup_keymaps_fn then
    setup_keymaps_fn(M.jj_buffer, original_window)
  end

  -- Auto-cleanup on buffer wipeout
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = M.jj_buffer,
    once = true,
    callback = function()
      M.jj_window = nil
      M.jj_buffer = nil
    end,
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

  M.run_command_in_terminal(log_args, "JJ Log", setup_log_keymaps)
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

  M.run_command_in_terminal(args, "JJ: " .. args_str, function(buf)
    vim.keymap.set("n", "q", ":close<CR>", { buffer = buf, silent = true, desc = "JJ: Close window" })
  end)
end

return M
