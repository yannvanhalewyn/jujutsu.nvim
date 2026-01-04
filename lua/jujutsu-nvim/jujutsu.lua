local M = {}

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

--------------------------------------------------------------------------------
-- Basic Operations

M.new_change = function(change_id, on_success)
  run_jj_command({ "jj", "new", change_id }, on_success)
end

M.abandon_change = function(change_id, on_success)
  run_jj_command({ "jj", "abandon", change_id }, on_success)
end

M.edit_change = function(change_id, on_success)
  run_jj_command({ "jj", "edit", change_id }, on_success)
end

M.describe = function(change_id, new_description, on_success)
  run_jj_command(
    { "jj", "describe", "-r", change_id, "-m", new_description },
    on_success)
end

--------------------------------------------------------------------------------
-- Change queries

M.make_revset = function(change_ids)
  return table.concat(change_ids, " | ")
end

M.get_changes = function(revset, callback)
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
  { label = 'Revision (single change)', flag = '-r' },
  { label = 'Source (subtree - change + descendants)', flag = '-s' },
  { label = 'Branch (all revisions in branch)', flag = '-b' },
}

M.rebase_destination_types = {
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
      on_success()
    end, function(result)
      vim.notify("Rebase failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    end)
  end)
end


return M
