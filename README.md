# jujutsu.nvim

A Neovim plugin for working with [Jujutsu](https://github.com/martinvonz/jj) version control.

## Features

- **Interactive Log View**: Browse your jujutsu history with syntax highlighting and keybindings
- **Change Operations**: Describe, edit, abandon, and create new changes
- **Rebase Support**: Interactive rebasing with multiple source types (revision, subtree, branch) and destination types (onto, after, before)
- **Squash Operations**: Squash single or multiple changes with combined descriptions
- **Multi-Selection**: Select multiple changes for batch operations
- **Difftastic Integration**: View diffs using [difftastic](https://github.com/Wilfred/difftastic)

## Requirements

- Neovim >= 0.10.0
- [jj](https://github.com/martinvonz/jj) (Jujutsu VCS)

### Optional Dependencies

- [difftastic.nvim](https://github.com/clabby/difftastic.nvim) - For the default "difftastic" diff viewer
- [diffview.nvim](https://github.com/sindrets/diffview.nvim) - For the "diffview" diff viewer preset

## Installation

### Using vim.pack (Neovim 0.10+)

```lua
vim.pack.add({
  src = "https://github.com/yannvanhalewyn/jujutsu.nvim"
})
```

The plugin will automatically set up the `:JJ` command when loaded.

## Configuration

The plugin can be configured by calling `setup()`. Note that this is optional,
only necessary if you want to change the default behavior.

```lua
require("jujutsu-nvim").setup({
  -- Diff viewer to use when pressing <CR> on a change
  -- Options: "difftastic", "diffview", "none", or a custom function
  diff_viewer = "difftastic",  -- default
})
```

### Diff Viewer Options

#### Built-in Presets

- **`"difftastic"`** (default) - Opens diffs using [difftastic.nvim](https://github.com/clabby/difftastic.nvim) in a new tab
- **`"diffview"`** - Opens diffs using [diffview.nvim](https://github.com/sindrets/diffview.nvim)
- **`"none"`** - Disables the default `<CR>` behavior (useful if you want to add your own via keymaps)


### Manual Setup (if needed)

If you prefer to call setup manually:

```lua
vim.keymap.set("n", "<leader>j", ":JJ<CR>", { desc = "JJ Log" })
-- Or use via the lua API:
local jj = require("jujutsu-nvim")
vim.keymap.set("n", "<leader>j", jj.log, { desc = "JJ Log" })
```

## Usage

### Commands

- `:JJ` or `:JJ log` - Open the interactive log view
- `:JJ <command>` - Run any jj command (e.g., `:JJ status`, `:JJ diff`)

### Log View Keybindings

#### Navigation
- `j` / `k` - Move down/up by 2 lines
- `q` - Close window
- `<CR>` - Open difftastic view for change under cursor

#### Change Operations
- `R` - Refresh log
- `d` - Describe (edit description)
- `n` - Create new change after current
- `N` - Create new with options
- `a` - Abandon change
- `e` - Edit (check out) change
- `r` - Rebase change onto another change
- `s` - Squash change into it's parent
- `S` - Squash change into another target

#### Multi-Selection
- `m` - Toggle selection for current change
- `c` - Clear all selections

When multiple changes are selected, operations like rebase and squash will act on all selected changes.

### Example Workflow

1. Open the log: `:JJ log` or `<leader>j`
2. Navigate to a change and press `<CR>` to view the diff
3. Press `d` to edit the description
4. Select multiple changes with `m` and rebase them with `r`
5. Press `q` to close the log view

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

- Built for use with [Jujutsu](https://github.com/martinvonz/jj)
- Inspired by fugitive.vim and other Git plugins
