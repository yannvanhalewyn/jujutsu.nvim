local u = require("jujutsu-nvim.utils")

local M = {}

--- @class CaptureBufferOpts
--- @field content string? Initial content to display
--- @field filetype string? Buffer filetype (e.g., 'jjdescription', 'text')
--- @field extra_help_text string? Extra help text shown at top of buffer
--- @field on_submit fun(content: string) Callback with user content (without help lines)
--- @field on_abort function? Optional callback on abort
--- @field on_ready fun(window: number, buffer: number)? Callback invoked when buffer is ready

--- Open an editor buffer meant to capture user input
--- @param opts CaptureBufferOpts
M.open = function(opts)
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
      local filtered_lines = u.remove(content, function(x) return x:match("^JJ:") end)
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

  if opts.on_ready then
    opts.on_ready(win, buf)
  end
end

return M
