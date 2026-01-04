# AGENTS.md - Development Guide for jujutsu.nvim

This guide provides essential information for AI coding agents working on the jujutsu.nvim codebase.

## Project Overview

**jujutsu.nvim** is a Neovim plugin for working with Jujutsu (jj) version control.
- Language: Lua (Neovim plugin)
- Target: Neovim >= 0.10.0
- Dependencies: jj CLI, optional difftastic.nvim
- Structure: Single-file plugin with auto-setup

## Build, Lint, and Test Commands

### Testing
This project currently has no automated test suite. Testing is done manually:

```bash
# Manual testing approach:
# 1. Install plugin locally in Neovim config:
#    vim.pack.add({ src = "~/code/jujutsu.nvim" })
# 2. Restart Neovim or reload config
# 3. Test commands: :JJ log, :JJ status, etc.
# 4. Verify keybindings work in log view (d, r, s, etc.)
```

### Linting
No formal linter configured. Follow Lua language server recommendations.

### Building
No build step required - pure Lua source loaded directly by Neovim.

### Running the Plugin
```bash
# From Neovim command line:
:JJ                  # Open interactive log view
:JJ log              # Open interactive log view
:JJ status           # Run jj status
:JJ <any-command>    # Run arbitrary jj command
```

## Code Style Guidelines

### File Organization
- Entry point: `plugin/jj.lua` (auto-loads on startup)
- Main logic: `lua/jj.lua` (all functionality in single module)
- Sections marked with comment separators: `----...----`

### Imports and Dependencies
```lua
-- Use local M = {} module pattern
local M = {}

-- Access Neovim API via vim global
vim.api.nvim_*
vim.ui.*
vim.fn.*

-- Return module at end
return M
```

### Formatting
- **Indentation**: 2 spaces (soft tabs)
- **Line length**: ~100 characters (no strict limit observed)
- **Strings**: Double quotes preferred for user-facing text, flexible otherwise
- **Comments**: Use `--` for single-line, section headers like `-- Section Name`
- **Blank lines**: Generous spacing between functions for readability

### Naming Conventions
- **Functions**: `snake_case` for all functions
  - Local functions: `local function do_something()`
  - Module functions: `function M.public_api()`
- **Variables**: `snake_case` for all variables
  - Module state: `M.jj_window`, `M.jj_buffer`, `M.selected_changes`
  - Local vars: `change_id`, `source_ids`, `dest_type`
- **Constants**: `SCREAMING_SNAKE_CASE` for tables that act as constants
  - Example: `rebase_source_types`, `rebase_destination_types`
- **Tables/Objects**: Use descriptive names with `_opts` suffix for option tables
  - Example: `keymap_opts`, `opts`

### Function Patterns
```lua
-- Use local functions for internal logic
local function extract_change_id(line)
  -- Implementation
end

-- Public API functions on module
function M.log(args)
  -- Implementation
end

-- Helper functions that take callbacks
local function with_change_at_cursor(operation)
  -- Extract data, validate, then call operation(data)
end
```

### Error Handling
- Use `vim.notify()` for all user-facing messages
- Severity levels:
  - `vim.log.levels.INFO` - Success messages, status updates
  - `vim.log.levels.WARN` - Non-fatal issues (e.g., invalid line)
  - `vim.log.levels.ERROR` - Command failures, validation errors
- Check buffer/window validity before operations:
  ```lua
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Safe to use buffer
  end
  ```
- Use `pcall()` for operations that might fail:
  ```lua
  pcall(vim.api.nvim_buf_set_name, M.jj_buffer, title or "[JJ]")
  ```

### Async Operations
- Use `vim.system()` with `:wait()` for external commands:
  ```lua
  local result = vim.system(args, { text = true }):wait()
  if result.code == 0 then
    -- Handle success
  else
    -- Handle error
  end
  ```
- Callback pattern for async flows:
  ```lua
  local function run_jj_command(args, on_success, on_error)
    -- Execute and call appropriate callback
  end
  ```

### UI Patterns

#### Prompts and Confirmations
```lua
-- Use vim.ui.input for simple text input
vim.ui.input({ prompt = "Enter value: " }, function(input)
  if not input then return end
  -- Process input
end)

-- Use vim.ui.select for choice menus
vim.ui.select(items, {
  prompt = 'Choose:',
  format_item = function(item) return item.label end
}, function(choice)
  if not choice then return end
  -- Process choice
end)
```

#### Buffer Management
- Track window/buffer state in module: `M.jj_window`, `M.jj_buffer`
- Clean up on close:
  ```lua
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() -- cleanup end
  })
  ```

#### Keymaps
- Always use descriptive options:
  ```lua
  vim.keymap.set("n", "R", M.log, {
    buffer = buf,
    silent = true,
    desc = "JJ: Refresh log"
  })
  ```
- Prefix all descriptions with "JJ: " for discoverability

### Command Construction
- Use tables for building command arguments:
  ```lua
  local args = { "jj", "rebase" }
  table.insert(args, "-r")
  table.insert(args, change_id)
  ```
- Shell-escape when passing to terminal:
  ```lua
  local cmd_str = table.concat(vim.tbl_map(vim.fn.shellescape, cmd_args), " ")
  ```

### State Management
- Module-level state for UI: `M.jj_window`, `M.jj_buffer`
- Module-level state for selections: `M.selected_changes = {}`
- Use table as set for selections: `selected_changes[id] = true/nil`
- Clear state when appropriate (after operations complete)

## Common Patterns

### Extracting Data from Log Lines
```lua
local function extract_change_id(line)
  local clean_line = strip_ansi(line)
  -- Try multiple patterns to handle different formats
  local change_id = clean_line:match "pattern1"
  if not change_id then
    change_id = clean_line:match "pattern2"
  end
  return change_id
end
```

### Operation with Validation
```lua
local function with_change_at_cursor(operation)
  local line = vim.api.nvim_get_current_line()
  local change_id = extract_change_id(line)

  if change_id and #change_id >= 4 then
    operation(change_id)
  else
    vim.notify("Could not find change ID", vim.log.levels.WARN)
  end
end
```

### Multi-step User Interactions
Use nested callbacks for multi-step flows:
```lua
prompt_source_type(function(source_type)
  select_change({ prompt = "Select destination" }, function(dest_id)
    prompt_destination_type(function(dest_type)
      execute_rebase(source_id, source_type, dest_id, dest_type)
    end)
  end)
end)
```

## Important Implementation Notes

- **Line-based parsing**: Log output parsed line-by-line, assumes consistent jj formatting
- **Change ID validation**: Minimum 4 characters required for IDs
- **ANSI handling**: Strip ANSI codes before parsing: `str:gsub("\27%[[0-9;]*m", "")`
- **Multi-selection**: Stored as table-as-set pattern, displayed with extmarks
- **Terminal buffers**: Use `term://` for interactive jj output with color support
- **Window sizing**: Fixed at 40% of screen height: `math.floor(vim.o.lines * 0.4)`

## Plugin Architecture

1. **Entry**: `plugin/jj.lua` calls `require("jj").setup()`
2. **Setup**: Creates `:JJ` user command
3. **Command routing**: Empty args → log view, otherwise run arbitrary jj command
4. **Log view**: Terminal buffer with custom keymaps for operations
5. **Operations**: Modify history via jj CLI, then refresh log view

## Testing Guidelines (Manual)

When adding features:
1. Test in a real jj repository with multiple changes
2. Verify log view displays correctly with colors
3. Test keybindings don't conflict
4. Test multi-selection with 0, 1, and 3+ changes
5. Test error cases (invalid change ID, cancelled operations)
6. Verify notification messages are clear and helpful

## Git Commit Style

Based on recent commits:
- Imperative mood, capitalized: "Update README.md", "Add feature"
- Descriptive but concise
- No issue references needed
