local M = {}

--- @class TerminalWindowOpts
--- @field split_mode "reuse"|"vsplit"|"hsplit"|nil How to create/reuse window
--- @field buf number? Existing buffer to replace (if window is reused)
--- @field window number? Existing window to reuse
--- @field title string? Buffer name to display (defaults to "[JJ]")
--- @field on_exit fun(exit_code: number)? Callback invoked when the command completes
--- @field on_close function? Callback invoked when the buffer is wiped out
--- @field on_ready fun(window: number, buffer: number)? Callback invoked when buffer is ready

--- Runs a jj command in a terminal buffer within a window.
--- If a window is provided and valid, reuses it by replacing the buffer.
--- Otherwise, creates a new split window with a terminal buffer.
---
--- @param args string[] Command arguments to pass to jj (e.g., {"log", "--summary"})
--- @param opts TerminalWindowOpts Options for the terminal window
M.run_command_in_terminal_window = function (args, opts)
  local buffer = opts.buf
  local window = opts.window

  local cmd = vim.list_extend({ "jj", "--no-pager", "--color=always" }, args)

  -- Build shell command
  local cmd_str = table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ")
  local shell_cmd = "sh -c " .. vim.fn.shellescape(cmd_str)

  if window and vim.api.nvim_win_is_valid(window) then
    -- Reuse existing window - replace buffer with new terminal buffer
    -- Save current window to restore focus later
    local current_win = vim.api.nvim_get_current_win()
    
    -- Focus the window temporarily
    vim.api.nvim_set_current_win(window)

    -- Create a new empty buffer
    vim.cmd("enew")
    buffer = vim.api.nvim_get_current_buf()
    
    -- Start terminal in the new buffer using the shell command
    vim.fn.termopen(shell_cmd)
    
    -- Restore focus to original window after a brief delay
    -- This ensures the terminal buffer has time to initialize
    if current_win ~= window and vim.api.nvim_win_is_valid(current_win) then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(current_win) then
          vim.api.nvim_set_current_win(current_win)
        end
      end)
    end
  else
    -- Create new split based on split_mode
    local split_cmd
    if opts.split_mode == "vsplit" then
      split_cmd = "vsplit"
    elseif opts.split_mode == "hsplit" then
      split_cmd = "botright split"
    else
      -- Default to hsplit for backward compatibility
      split_cmd = "botright split"
    end

    vim.cmd(split_cmd .. " term://" .. vim.fn.fnameescape(shell_cmd))
    window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_get_current_buf()
  end

  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, buffer, opts.title or "[JJ]")

  -- TermClose fires when the terminal job exits
  if opts.on_exit then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buffer,
      once = true,
      callback = function()
        -- Extract exit code from v:event.status
        local exit_code = vim.v.event.status or 0
        opts.on_exit(exit_code)
      end
    })
  end

  -- BufWipeout fires when the buffer is closed/wiped
  if opts.on_close then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buffer,
      once = true,
      callback = opts.on_close
    })
  end

  if opts.on_ready then
    opts.on_ready(window, buffer)
  end
end

return M
