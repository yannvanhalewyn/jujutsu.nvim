local M = {}

--- @class JJChange
--- @field change_id string Short change ID
--- @field commit_sha string Full commit SHA
--- @field description string Change description

--- @param cmd string[]
--- @param on_success function?
--- @param on_error function?
local function run_jj_command(cmd, on_success, on_error)
  local result = vim.system(cmd, { text = true }):wait()

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

--------------------------------------------------------------------------------
-- Change queries

--- Combine multiple change IDs into a revset expression
--- @param change_ids string[] Array of change IDs
--- @return string Revset expression
M.make_revset = function(change_ids)
  return table.concat(change_ids, " | ")
end

--- Get changes matching a revset expression
--- @param revset string Revset expression to query
--- @param callback fun(changes: JJChange[]) Callback with array of changes
M.get_changes = function(revset, callback)
  local template = 'separate(";", change_id.short(), commit_id, coalesce(description, " ")) ++ "\n---END-CHANGE---\n"'

  run_jj_command(
    { "jj", "log", "--no-graph", "-r", revset, "-T", template },
    function(result)
      local output = result.stdout or ""
      local changes = {}

      -- Split by end-of-change separator
      for change_block in output:gmatch("(.-)\n%-%-%-END%-CHANGE%-%-%-\n") do
        if change_block ~= "" then
          -- Split on first semicolon only (to handle multiline descriptions)
          -- local change_id, commit_sha, description = change_block:match("^([^;]*);(.*);(.*)$")
          local change_id, commit_sha, description = unpack(vim.split(change_block, ";"))
          if change_id then
            -- Trim the change_id and preserve description as-is (including newlines)
            change_id = change_id:gsub("^%s*(.-)%s*$", "%1")
            table.insert(changes, {
              change_id = change_id,
              commit_sha = commit_sha,
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

--- Get changes by their IDs
--- @param change_ids string[] Array of change IDs
--- @param callback fun(changes: JJChange[]) Callback with array of changes
M.get_changes_by_ids = function(change_ids, callback)
  M.get_changes(M.make_revset(change_ids), function(changes)
    if #changes ~= #change_ids then
      vim.notify("Could not get change information", vim.log.levels.ERROR)
      return
    end
    callback(changes)
  end)
end

--------------------------------------------------------------------------------
-- Log output parsing

local function strip_ansi(str)
  return str:gsub("\27%[[0-9;]*m", "")
end

--- Try to extract change ID from jj log output
--- Format: "◉  mrtwmypl yann.vanhalewyn@gmail.com 2026-01-03 22:53:01 02a96588"
--- @param line string Line from jj log output
--- @return string? change_id The extracted change ID, or nil if not found
M.extract_change_id =  function(line)
  local clean_line = strip_ansi(line)

  -- Pattern 1: Extract the first alphanumeric string after box-drawing/special chars
  local change_id = clean_line:match "^[^%w]*(%w+)%s+%S+@"

  -- Pattern 2: If that fails, try to get 8-char hex at the end of the line
  if not change_id then
    change_id = clean_line:match "(%x%x%x%x%x%x%x%x)%s*$"
  end

  -- Pattern 3: For lines with branch names, extract the first word
  if not change_id then
    change_id = clean_line:match "[│├└─╮╯]*%s*[◉○◆@x]+%s+(%w+)"
  end

  return change_id
end

--------------------------------------------------------------------------------
-- Basic Operations

M.new_change = function(revset, on_success)
  run_jj_command({ "jj", "new", revset }, on_success)
end

M.abandon_changes = function(revset, on_success)
  run_jj_command({ "jj", "abandon", revset }, on_success)
end

M.edit_change = function(change_id, on_success)
  run_jj_command({ "jj", "edit", change_id }, on_success)
end

M.describe = function(change_id, new_description, on_success)
  run_jj_command(
    { "jj", "describe", "-r", change_id, "-m", new_description },
    on_success)
end

M.undo = function(op_id, on_success)
  run_jj_command({ "jj", "undo", op_id }, on_success)
end

M.get_bookmarks = function(callback)
  run_jj_command(
    { "jj", "bookmark", "list", "-T", "name ++ '\n'"},
    function(result)
      -- Format: "bookmark_name: change_id\n"
      local output = result.stdout or ""
      local bookmarks = vim.tbl_filter(
        function(line) return line end,
        vim.split(output, "\n")
      )
      callback(bookmarks)
    end,
    function(result)
      vim.notify("Failed to get bookmarks: " .. (result.stderr or ""), vim.log.levels.ERROR)
      callback({})
    end
  )
end

M.create_bookmark = function(bookmark_name, change_id, on_success)
  run_jj_command(
    { "jj", "bookmark", "create", bookmark_name, "-r", change_id },
    on_success
  )
end

M.set_bookmark = function(bookmark_name, change_id, on_success)
  run_jj_command(
    { "jj", "bookmark", "set", bookmark_name, "-r", change_id, "--allow-backwards" },
    on_success
  )
end

M.get_bookmarks_for_change = function(change_id, callback)
  run_jj_command(
    { "jj", "log", "--no-graph", "-r", change_id, "-T", "bookmarks ++ '\n'" },
    function(result)
      local output = result.stdout or ""
      local bookmarks = {}

      -- Parse space-separated bookmark names
      for bookmark in output:gmatch("%S+") do
        if bookmark ~= "" then
          local cleaned = string.gsub(bookmark, "*$", "")
          table.insert(bookmarks, cleaned)
        end
      end

      callback(bookmarks)
    end,
    function(result)
      vim.notify("Failed to get bookmarks for change: " .. (result.stderr or ""), vim.log.levels.ERROR)
      callback({})
    end
  )
end

M.push_bookmarks_for_changes = function(revset, opts, on_success)
  local cmd = { "jj", "git", "push", "-r", revset }
  if opts.create then
    table.insert(cmd, "--allow-new")
  end
  run_jj_command(cmd, on_success)
end

M.delete_bookmark = function(bookmark_name, on_success)
  run_jj_command(
    { "jj", "bookmark", "delete", bookmark_name },
    on_success
  )
end

M.rename_bookmark = function(old_name, new_name, on_success)
  run_jj_command(
    { "jj", "bookmark", "rename", old_name, new_name },
    on_success
  )
end

M.git_fetch = function(on_success)
  run_jj_command(
    { "jj", "git", "fetch" },
    on_success
  )
end

M.pull_bookmark = function(bookmark_name, on_success)
  M.git_fetch(function()
    -- Then set the bookmark to point to the remote version
    run_jj_command(
      { "jj", "bookmark", "set", bookmark_name, "-r", bookmark_name .. "@origin" },
      on_success
    )
  end)
end

--------------------------------------------------------------------------------
-- Squash

M.execute_squash = function(source_ids, target_id, message, on_success)
  run_jj_command(
    { "jj", "squash", "--from", M.make_revset(source_ids), "--into", target_id, "-m", message },
    function()
      vim.notify(string.format(
        "Squashed %d %s into %s",
        #source_ids, #source_ids == 1 and "change" or "changes", target_id
      ), vim.log.levels.INFO)
      on_success()
    end,
    function(result)
      vim.notify("Squash failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end
  )
end

--------------------------------------------------------------------------------
-- Rebase

M.rebase_source_types = {
  { key = 'r', label = 'Revision (single change)', flag = '-r' },
  { key = 's', label = 'Source (subtree - change + descendants)', flag = '-s' },
  { key = 'b', label = 'Branch (all revisions in branch)', flag = '-b' },
}

M.rebase_destination_types = {
  {
    key = 'd',
    label = 'Destination (onto - default)',
    flag = '-d',
    preposition = 'onto'
  },
  {
    key = 'a',
    label = 'After destination',
    flag = '-A',
    preposition = 'after'
  },
  {
    key = 'b',
    label = 'Before destination',
    flag = '-B',
    preposition = 'before'
  },
}

M.execute_rebase = function(source_ids, source_type, dest_id, dest_type, on_success)
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

  run_jj_command(args, function()
    vim.notify(string.format(
      "Rebased %d change%s %s %s",
      count,
      count == 1 and "" or "s",
      dest_type.preposition,
      dest_id:sub(1, 8)
    ), vim.log.levels.INFO)
    on_success()
  end, function(result)
    vim.notify("Rebase failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
  end)
end

return M
