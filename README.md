# jujutsu.nvim

A Neovim plugin for working with [Jujutsu](https://github.com/martinvonz/jj) version control. This plugin is aimed to cover the most common use cases and focus mostly on smooth and fast UX.

![jujutsu-nivm-log-trim](https://github.com/user-attachments/assets/c868c4bc-e4dc-450f-ab8e-60b22e0e915c)

*Note*: this plugin is in early development, APIs and configuration are subject to change. I'd love to hear feedback, issues and feature requests!

## Features

- **Interactive Log View**: Browse your jujutsu history with syntax highlighting and keybindings
- **Change Operations**: Describe, edit, abandon, and create new changes
- **Rebase Support**: Interactive rebasing with multiple source types (revision, subtree, branch) and destination types (onto, after, before)
- **Squash Operations**: Squash single or multiple changes with combined descriptions
- **Multi-Selection**: Select multiple changes for batch operations
- **Difftastic Integration**: View diffs using [difftastic](https://github.com/Wilfred/difftastic)
- **Diffview Integration**: View diffs using [diffview](https://github.com/sindrets/diffview.nvim)
- **Extensible**: Via own keybindings and Lua API

<img width="981" height="652" alt="Screenshot 2026-01-05 at 03 22 58" src="https://github.com/user-attachments/assets/b9283c1d-76ac-42a8-bfcc-674f098c9437" />

## Requirements

- Neovim >= 0.10.0
- [jj](https://github.com/martinvonz/jj) (Jujutsu VCS)

### Optional Dependencies

- [difftastic.nvim](https://github.com/clabby/difftastic.nvim) - For the default "difftastic" diff viewer
- [diffview.nvim](https://github.com/sindrets/diffview.nvim) - For the "diffview" diff viewer preset

## Installation

### Using vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  src = "https://github.com/yannvanhalewyn/jujutsu.nvim"
})
```

The plugin will automatically set up the `:JJ` command when loaded.

### Using lazy.nvim

```lua
{
  "yannvanhalewyn/jujutsu.nvim",
}
```

Or to use diffview.nvim:

```lua
{
  "yannvanhalewyn/jujutsu.nvim",
  config = function()
    require("jujutsu-nvim").setup({
      diff_preset = "diffview",
    })
  end,
}
```

## Usage

### Demos

#### Multi-select Diffing

Select multiple changes and view their combined diff to see all changes at once. This is useful when wanting to get a sense of what's contained in a few changes before squashing / rebasing them.

https://github.com/user-attachments/assets/e009643f-0794-43c0-91b2-9795cec86b02

#### Rebase with Source and Destination Type Selection

Interactively rebase changes with full control over the source type (revision, subtree, or branch) and destination type (onto, after, or before). This gives you precise control over how changes are moved in your history.

https://github.com/user-attachments/assets/278bd063-8558-4df9-aebd-d25431f8ca84

#### Squash and Multi-select Flow

Squash multiple changes together, with their descriptions automatically combined. Select several changes and squash them into a target, or squash a single change into its parent.

https://github.com/user-attachments/assets/61837b2a-3fdf-49a3-b457-5310eab1faaf

#### Bookmark management

Manage your bookmarks, create, set, delete, rename and push them to the remote

https://github.com/user-attachments/assets/8cbf2ad0-86ac-435a-ad1a-38c245c3bdff

### Commands

- `:JJ` or `:JJ log` - Open the interactive log view
- `:JJ <command>` - Run any jj command (e.g., `:JJ status`, `:JJ op log`)

### Log View Keybindings

Press `?` in the log view to see all available keybindings organized by category.

#### Help

| Key | Action | Description |
|-----|--------|-------------|
| `?` | Show help | Display all keybindings organized by category |

#### Navigation

| Key | Action | Description |
|-----|--------|-------------|
| `j` | Jump to next change | Move to the next change in the log |
| `k` | Jump to previous change | Move to the previous change in the log |
| `<CR>` | Open diff viewer | Open diff viewer for change under cursor |

#### Log Window

| Key | Action | Description |
|-----|--------|-------------|
| `q` | Close window | Close the log window |
| `R` | Refresh | Refresh the log view |
| `l` | Set custom revset | Opens the log on a new custom revset |

#### Basic Operations

| Key | Action | Description |
|-----|--------|-------------|
| `d` | Describe | Edit the description of the change at cursor |
| `n` | Create new change | Create new change after change at cursor |
| `a` | Abandon change(s) | Abandon the change at cursor (or selected changes) |
| `e` | Edit (checkout) change | Edit (check out) the change at cursor |
| `u` | Undo last operation | Undo the last operation |

#### Advanced Operations

| Key | Action | Description |
|-----|--------|-------------|
| `s` | Squash into parent | Squash change into its parent |
| `S` | Squash to target | Squash change into another target |
| `r` | Rebase change | Rebase change onto another change. Opens interactive menu |

#### Bookmarks

| Key | Action | Description |
|-----|--------|-------------|
| `b` | Set/create bookmark | Set or create a bookmark on the change |
| `B` | Bookmark operations menu | More bookmark options, like delete and rename |
| `p` | Push bookmarks | Push the change (and its bookmarks) to remote |
| `P` | Push and create bookmarks | Push the change and create bookmarks on remote if they don't exist |
| f | Fetch from remote | Runs 'jj git fetch' |
| F | Pull | Runs 'jj git fetch' followed by moving local bookmark at cursor to origin  |

#### Multi-Selection

Some operations can be performed on a selection of changes. Here's how to manage selections:

- `m` - Toggle selection for the change at cursor
- `c` - Clear all selections

Now various operations can be performed on the selected changes:

| Operation | Action | Description |
|-----------|--------|-------------|
| `n` | New |  Creates new change after all selected changes |
| `a` | Abandon | Abandons all selected changes |
| `r` | Rebase |  Rebases all selected changes onto change at cursor |
| `s` | Squash | Squashes all selected changes into change at cursor |
| `<CR>` | Diff | Opens diff for all selected changes (only if there are no gaps) |
| `p` | Push | Pushes bookmarks for all selected changes |
| `P` | Push create | Pushes bookmarks all selected changes (with `--allow-new`) |

**Note**: Operations that don't support multi-selection (like `d` for describe, `e` for edit) always operate on the change under the cursor, ignoring selections.

#### Bookmarks

jujutsu.nvim provides several bookmark operations:

| Key | Action | Description |
|-----|--------|-------------|
| `b` | Set/Create bookmark | Select from existing bookmarks or create new one |
| `B` | Bookmark menu | Show all bookmark operations |
| `d` (in bookmark menu) | Delete bookmark | Delete a bookmark from the change |
| `r` (in bookmark menu) | Rename bookmark | Rename a bookmark |
| `p` (in bookmark menu) | Pull bookmark | Fetch and update bookmark from remote |

**Setting/Creating bookmarks (b)**:
1. Press `b` on a change
2. Select an existing bookmark to move it to this change, or select "[Create new bookmark]"
3. If creating, enter the new bookmark name

**Bookmark menu (B)**:
1. Press `B` on a change with bookmarks
2. Select an operation:
   - `d` - Delete: Choose a bookmark to delete
   - `r` - Rename: Choose a bookmark and enter a new name
   - `p` - Pull: Fetch from remote and update bookmark to point to remote version

**Pushing bookmarks**:
- Use `p` to push the change's bookmarks to remote
- Use `P` to push and create the bookmarks on remote with `--allow-new` flag

### Example Workflow

1. Open the log: `:JJ log` or `<leader>j`
2. Navigate to a change and press `<CR>` to view the diff
3. Press `d` to edit the description
4. Select multiple changes with `m` and rebase them with `r`
5. Press `q` to close the log view

## Configuration

The plugin can be configured by calling `setup()`. Note that this is optional,
only necessary if you want to change the default behavior.

```lua
require("jujutsu-nvim").setup({
  -- Diff viewer: "difftastic", "diffview", "codediff", none"
  diff_preset = "difftastic",  -- default

  -- Help window position: "center", "bottom_right"
  help_position = "center",  -- default
})
```

### Configuration Options

#### Help Window Position

The help window (opened with `?`) can be positioned in different locations:
- **`"center"`** (default) - Centers the help window on screen
- **`"bottom_right"`** - Positions the help window in the bottom right corner

```lua
require("jujutsu-nvim").setup({
  help_position = "bottom_right",
})
```

### Diff Viewer Options

#### Built-in Presets

- **`"difftastic"`** (default) - Opens diffs using [difftastic.nvim](https://github.com/clabby/difftastic.nvim) in a new tab
- **`"diffview"`** - Opens diffs using [diffview.nvim](https://github.com/sindrets/diffview.nvim)
- **`"codediff"`** - Opens diffs using [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- **`"none"`** - Disables the default `<CR>` behavior (useful if you want to add your own via keymaps)

### Custom Keymaps

You can customize keybindings in the log view by providing a `keymap` table in the setup configuration. Each key can map to:
- A **string** representing a built-in action name (legacy format)
- A **table** with `cmd` and `desc` fields (recommended format)
- A **function** to run custom code

#### Example: Custom Keymaps

```lua
require("jujutsu-nvim").setup({
  keymap = {
    -- Structured format (recommended)
    q = { cmd = "quit", desc = "Close window" },
    R = { cmd = "refresh", desc = "Refresh log" },
    d = { cmd = "describe", desc = "Edit description" },

    -- Map to custom functions
    ["<C-d>"] = {
      cmd = function()
        local jj = require("jujutsu-nvim")
        jj.with_change_at_cursor(function(change_id)
          vim.notify("Custom diff command: " .. change_id)
        end)
      end,
      desc = "Custom diff"
    },
  }
})
```

Custom keybindings (those using functions) will automatically appear in a "Custom" group when you press `?` to view the help window.

#### Available Built-in Actions

The following action names can be used as string values in your keymap (or as the `cmd` field in the new format):

| Action Name | Description |
|-------------|-------------|
| `show_help` | Show keybindings help window |
| `quit` | Close the log window |
| `jump_to_next_change` | Navigate to next change |
| `jump_to_prev_change` | Navigate to previous change |
| `refresh` | Refresh the log view |
| `undo` | Undo the last operation |
| `set_revset` | Open log with custom revset |
| `open_diff` | Open diff viewer for change |
| `describe` | Edit change description |
| `new_change` | Create new change |
| `abandon_changes` | Abandon change(s) |
| `edit_change` | Check out change |
| `rebase_change` | Rebase change |
| `squash_change` | Squash change |
| `squash_to_target` | Squash to specific target |
| `bookmark_change` | Set/create bookmark |
| `bookmark_menu` | Show bookmark operations |
| `push_bookmarks` | Push bookmarks |
| `push_bookmarks_and_create` | Push bookmarks with --allow-new |
| `toggle_change` | Toggle multi-selection |
| `clear_selections` | Clear all selections |

### Recommended setup

It's recommended to bind a leader key to run the `:JJ` command:

```lua
vim.keymap.set("n", "<leader>j", ":JJ<CR>", { desc = "JJ Log" })
```


But you can achieve similar results by calling into the Lua API directly:

```lua
local jj = require("jujutsu-nvim")
vim.keymap.set("n", "<leader>j", jj.log, { desc = "JJ Log" })
```

## Roadmap

Here are the things I'd like to be adding soon. Please submit issues for any ideas or feature requests, I'd love to hear from you :).

- [ ] Splitting changes interactively using [hunk.nvim](https://github.com/julienvincent/hunk.nvim) inside current Neovim instance
- [ ] Squashing current hunk from any code file
- [ ] 'U' to display the op log with the ability to undo specific operation using 'u'
- [ ] Add a good public Lua API to build own flows more easily
- [ ] Maybe, implement resolving by leveraging [jj-diffconflicts](https://github.com/rafikdraoui/jj-diffconflicts)

## Development

### Local Development Setup

To work on this plugin locally while using it in your config:

```lua
-- In your init.lua, use a local path:
vim.pack.add({ src = "~/code/jujutsu.nvim" })
```

Any changes you make to the plugin files will be picked up when you restart Neovim or reload your config.

### Running from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/jujutsu.nvim.git ~/code/jujutsu.nvim
   ```

2. Point your config to the local directory (see above)

3. Make your changes and test by restarting Neovim

## License

MIT

## Acknowledgments

- Built for use with [Jujutsu](https://github.com/martinvonz/jj), an inspiring VCS
- Inspired by LazyGit
