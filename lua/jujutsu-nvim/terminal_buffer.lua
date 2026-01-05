local M = {}

M.run_command_in_new_terminal_window = function (args, opts)
  local cmd_args = { "jj", "--no-pager", "--color=always" }
  vim.list_extend(cmd_args, args)

  -- Build shell command
  local cmd_str = table.concat(vim.tbl_map(vim.fn.shellescape, cmd_args), " ")
  local shell_cmd = "sh -c " .. vim.fn.shellescape(cmd_str)

  local buffer = opts.buf
  local window = opts.window

  if window and vim.api.nvim_win_is_valid(window) then
    -- Reuse existing window - replace buffer with new terminal buffer
    -- Focus the window first
    vim.api.nvim_set_current_win(window)

    -- Create new terminal buffer (this replaces the current buffer in the window)
    vim.cmd("edit term://" .. vim.fn.fnameescape(shell_cmd))
    local new_buffer = vim.api.nvim_get_current_buf()

    -- Delete old buffer after switching (avoids closing the window)
    if buffer and vim.api.nvim_buf_is_valid(buffer) and buffer ~= new_buffer then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end

    buffer = new_buffer
  else
    -- Create a new terminal buffer and run command
    vim.cmd("botright split term://" .. vim.fn.fnameescape(shell_cmd))
    window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_get_current_buf()
  end

  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].buflisted = false
  pcall(vim.api.nvim_buf_set_name, buffer, opts.title or "[JJ]")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = opts.on_close
  })

  if opts.on_ready then
    opts.on_ready(window, buffer)
  end
end

return M
