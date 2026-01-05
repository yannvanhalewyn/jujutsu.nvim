-- Custom jj integration for Neovim
--
-- Provides a simple interface for running jj commands and displaying results
-- in Neovim buffers with custom keymaps and highlighting.
--
-- Usage:
--   :JJ log           - Open interactive log view
--   :JJ <any command> - Run any jj command

local jj = require("jujutsu-nvim.jujutsu")

local M = {}

-- Window and buffer tracking
M.jj_window = nil
M.jj_buffer = nil

-- Highlight group for jj log change lines
vim.api.nvim_set_hl(0, "JJLogChange", { link = "CursorLine" })

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- Default configuration
local default_config = {
  -- Diff viewer preset options: "difftastic", "diffview" or "none"
  diff_preset = "difftastic",
}

-- Current configuration (merged with user config)
M.config = vim.deepcopy(default_config)

-- Built-in diff viewer implementations
local diff_presets = {
  difftastic = function(changes)
    vim.cmd("tabnew")
    local change_ids = vim.tbl_map(function(c)
      return c.change_id end,
      changes
    )
    vim.cmd("Difft " .. jj.make_revset(change_ids))
  end,

  diffview = function(changes)
    if #changes == 1 then
      vim.cmd(string.format("DiffviewOpen %s", changes[0].commit_sha))
    else
      vim.cmd(string.format("DiffviewOpen %s...%s", changes[0].commit_sha, changes[#changes].commit_sha))
    end
  end,

  none = function(_)
    vim.notify("No diff viewer configured", vim.log.levels.INFO)
  end,
}

-- Get the configured diff viewer function
local function get_diff_viewer()
  local preset = M.config.diff_preset

  local viewer = diff_presets[preset]
  if viewer then
    return viewer
  else
    vim.notify(
      string.format("Unknown diff viewer preset: '%s'. Using 'none'.", preset),
      vim.log.levels.WARN
    )
    return diff_presets.none
  end
end

function M.setup(user_config)
  M.config = vim.tbl_deep_extend("force", default_config, user_config or {})
end

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
    -- Makes it so the cursor remains at top after edit buffer close
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

local dialog_window = require("jujutsu-nvim.dialog_window")

local function new_change()
  local selected_ids = get_selected_ids()
  if #selected_ids > 0 then
    jj.new_change(jj.make_revset(selected_ids), function()
      vim.notify("Created new change on " .. table.concat(selected_ids, ", "), vim.log.levels.INFO)
      M.log()
    end)
  else
    with_change_at_cursor(function(change_id)
      jj.new_change({ change_id }, function()
        vim.notify("Created new change after " .. change_id, vim.log.levels.INFO)
        M.log()
      end)
    end)
  end
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

local function abandon_changes()
  local selected_ids = get_selected_ids()
  if #selected_ids > 0 then
    dialog_window.confirm(
      string.format(
        "Abandon the following changes?\n\n%s",
        table.concat(vim.tbl_map(function(id) return "- " .. id end, selected_ids), "\n")
      ),
      function()
        jj.abandon_changes(jj.make_revset(selected_ids), function()
          vim.notify("Abandoned changes " .. table.concat(selected_ids, ", "), vim.log.levels.INFO)
          clear_selections()
          M.log()
        end)
      end,
      function()
        vim.notify("Abandon cancelled", vim.log.levels.INFO)
      end)
  else
    with_change_at_cursor(function(change_id)
      dialog_window.confirm(
        string.format("Abandon change %s?", change_id:sub(1, 8)),
        function()
          jj.abandon_changes({ change_id }, function()
            vim.notify("Abandoned change " .. change_id, vim.log.levels.INFO)
            M.log()
          end)
        end,
        function()
          vim.notify("Abandon cancelled", vim.log.levels.INFO)
        end)
      end)
    end
end

local function edit_change(change_id)
  jj.edit_change(change_id, function()
    vim.notify("Checked out change " .. change_id, vim.log.levels.INFO)
    M.log()
  end)
end

local function undo()
  jj.undo(nil, function()
    vim.notify("Undid latest operation", vim.log.levels.INFO)
    M.log()
  end)
end

local function bookmark_change(change_id)
  jj.get_bookmarks(function(bookmarks)
    -- Add "Create new bookmark" option at the beginning
    local new_bookmark_name = "[Create new bookmark]"
    local items = { new_bookmark_name }
    vim.list_extend(items, bookmarks)

    vim.ui.select(items, {
      prompt = "Select bookmark:",
      format_item = function(item) return item end
    }, function(choice)
      if not choice then
        vim.notify("Bookmark cancelled", vim.log.levels.INFO)
        return
      end

      if choice == new_bookmark_name then
        vim.ui.input({ prompt = "New bookmark name: " }, function(bookmark_name)
          if not bookmark_name or bookmark_name == "" then
            vim.notify("Bookmark cancelled", vim.log.levels.INFO)
            return
          end

          jj.create_bookmark(bookmark_name, change_id, function()
            vim.notify("Created bookmark '" .. bookmark_name .. "' at " .. change_id, vim.log.levels.INFO)
            M.log()
          end)
        end)
      else
        jj.set_bookmark(choice, change_id, function()
          vim.notify("Moved bookmark '" .. choice .. "' to " .. change_id, vim.log.levels.INFO)
          M.log()
        end)
      end
    end)
  end)
end

local function bookmark_menu(change_id)
  jj.get_bookmarks_for_change(change_id, function(bookmarks)
    if #bookmarks == 0 then
      vim.notify("No bookmarks on change " .. change_id, vim.log.levels.WARN)
      return
    end

    local options = {
      { key = 'd', label = 'Delete bookmark', value = 'delete' },
      { key = 'r', label = 'Rename bookmark', value = 'rename' },
      { key = 'p', label = 'Pull bookmark from remote', value = 'pull' },
    }

    dialog_window.show_floating_options({
      prompt = 'Bookmark operations:',
      options = options,
      on_select = function(option)
        if option.value == 'delete' then
          -- Select which bookmark to delete
          vim.ui.select(bookmarks, {
            prompt = "Delete bookmark:",
            format_item = function(item) return item end
          }, function(bookmark)
            if not bookmark then
              vim.notify("Delete cancelled", vim.log.levels.INFO)
              return
            end

            dialog_window.confirm(
              string.format("Delete bookmark '%s'?", bookmark),
              function()
                jj.delete_bookmark(bookmark, function()
                  vim.notify("Deleted bookmark '" .. bookmark .. "'", vim.log.levels.INFO)
                  M.log()
                end)
              end,
              function()
                vim.notify("Delete cancelled", vim.log.levels.INFO)
              end
            )
          end)
        elseif option.value == 'rename' then
          -- Select which bookmark to rename
          vim.ui.select(bookmarks, {
            prompt = "Rename bookmark:",
            format_item = function(item) return item end
          }, function(bookmark)
            if not bookmark then
              vim.notify("Rename cancelled", vim.log.levels.INFO)
              return
            end

            vim.ui.input({ prompt = "New name for '" .. bookmark .. "': " }, function(new_name)
              if not new_name or new_name == "" then
                vim.notify("Rename cancelled", vim.log.levels.INFO)
                return
              end

              jj.rename_bookmark(bookmark, new_name, function()
                vim.notify("Renamed bookmark '" .. bookmark .. "' to '" .. new_name .. "'", vim.log.levels.INFO)
                M.log()
              end)
            end)
          end)
        elseif option.value == 'pull' then
          -- Select which bookmark to pull
          vim.ui.select(bookmarks, {
            prompt = "Pull bookmark:",
            format_item = function(item) return item end
          }, function(bookmark)
            if not bookmark then
              vim.notify("Pull cancelled", vim.log.levels.INFO)
              return
            end

            jj.pull_bookmark(bookmark, function()
              vim.notify("Pulled bookmark '" .. bookmark .. "' from remote", vim.log.levels.INFO)
              M.log()
            end)
          end)
        end
      end,
      on_cancel = function()
        vim.notify("Bookmark operation cancelled", vim.log.levels.INFO)
      end
    })
  end)
end

local function push_bookmarks(opts)
  local selected_ids = get_selected_ids()
  if #selected_ids > 0 then
    jj.push_bookmarks_for_changes(
      jj.make_revset(selected_ids),
      { create = opts.create },
      function()
        vim.notify(
          string.format("Pushed bookmarks for %s",
          table.concat(selected_ids, ", ")
        ),
        vim.log.levels.INFO
      )
      M.log()
    end)
  else
    with_change_at_cursor(function(change_id)
      jj.push_bookmarks_for_changes(
        change_id,
        { create = opts.create },
        function()
          vim.notify("Pushed change " .. change_id, vim.log.levels.INFO)
          M.log()
        end)
      end)
  end
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

  dialog_window.show_floating_options({
    prompt = 'Rebase source type:',
    options = options,
    on_select = function(option) cb(option.value) end,
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

  dialog_window.show_floating_options({
    prompt = 'Rebase destination type:',
    options = options,
    on_select = function(option) cb(option.value) end,
    on_cancel = function()
      vim.notify("Rebase cancelled", vim.log.levels.INFO)
    end
  })
end

local function execute_rebase(source_ids, source_type, dest_id, dest_type)
  local prompt = jj.build_rebase_confirmation_msg(source_ids, dest_type, dest_id)

  dialog_window.confirm(
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
-- Diff operations
--------------------------------------------------------------------------------

local function open_diff_for_changes()
  local viewer = get_diff_viewer()
  local selected_ids = get_selected_ids()
  if #selected_ids > 0 then
    jj.get_changes_by_ids(selected_ids, viewer)
  else
    with_change_at_cursor(function(change_id)
      jj.get_changes_by_ids({ change_id }, viewer)
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
    vim.keymap.set("n", key, action, vim.tbl_extend("force", opts, {
      desc = "JJ: " .. desc,
      nowait = true
    }))
  end

  -- Navigate to next line with a change ID
  local function jump_to_next_change()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local total_lines = vim.api.nvim_buf_line_count(buf)

    for line_num = current_line + 1, total_lines do
      local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1]
      if line and extract_change_id(line) then
        vim.api.nvim_win_set_cursor(0, { line_num, 0 })
        return
      end
    end
  end

  -- Navigate to previous line with a change ID
  local function jump_to_prev_change()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]

    for line_num = current_line - 1, 1, -1 do
      local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1]
      if line and extract_change_id(line) then
        vim.api.nvim_win_set_cursor(0, { line_num, 0 })
        return
      end
    end
  end

  -- Navigation
  map("q", close_jj_window, "Close window")
  map("j", jump_to_next_change, "Jump to next change")
  map("k", jump_to_prev_change, "Jump to previous change")

  -- Open diff viewer for change under cursor
  map("<CR>", open_diff_for_changes, "Open diff")

  -- Change operations
  map("R", M.log, "Refresh log")
  map("d", function() with_change_at_cursor(describe) end, "Describe change")
  map("n", new_change, "New change after this")
  map("a", abandon_changes, "Abandon change")
  map("e", function() with_change_at_cursor(edit_change) end, "Edit (check out) change")
  map("r", rebase_change, "Rebase change")
  map("s", squash_change, "Squash change")
  map("u", undo, "Squash change")
  map("S", function() with_change_at_cursor(squash_to_target) end, "Squash into target")
  map("b", function() with_change_at_cursor(bookmark_change) end, "Bookmark change")
  map("B", function() with_change_at_cursor(bookmark_menu) end, "Bookmark menu")
  map("p", function() push_bookmarks({}) end, "Push change")
  map("P", function() push_bookmarks({ create = true }) end, "Push change (create on remote)")

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
