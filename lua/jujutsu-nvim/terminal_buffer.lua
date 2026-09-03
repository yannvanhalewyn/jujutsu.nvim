local M = {}

local ns_id = vim.api.nvim_create_namespace("jujutsu_ansi_hl")

local fg_ansi_to_hl = {
  ["38;5;1"]  = "JJRed",
  ["38;5;2"]  = "JJGreen",
  ["38;5;3"]  = "JJYellow",
  ["38;5;4"]  = "JJBlue",
  ["38;5;5"]  = "JJMagenta",
  ["38;5;6"]  = "JJCyan",
  ["38;5;8"]  = "JJBrightBlack",
  ["38;5;10"] = "JJBrightGreen",
  ["38;5;12"] = "JJBrightBlue",
  ["38;5;13"] = "JJBrightMagenta",
  ["38;5;14"] = "JJBrightCyan",
}

vim.api.nvim_set_hl(0, "JJBold",          { bold = true               })
vim.api.nvim_set_hl(0, "JJRed",           { fg = "NvimLightRed"       })
vim.api.nvim_set_hl(0, "JJGreen",         { fg = "NvimLightGreen"     })
vim.api.nvim_set_hl(0, "JJYellow",        { fg = "NvimLightYellow"    })
vim.api.nvim_set_hl(0, "JJBlue",          { fg = "NvimLightBlue"      })
vim.api.nvim_set_hl(0, "JJMagenta",       { fg = "NvimLightMagenta"   })
vim.api.nvim_set_hl(0, "JJCyan",          { fg = "NvimLightCyan"      })
vim.api.nvim_set_hl(0, "JJBrightBlack",   { link = "Comment"          })
vim.api.nvim_set_hl(0, "JJBrightGreen",   { fg = "NvimLightGreen"     })
vim.api.nvim_set_hl(0, "JJBrightBlue",    { fg = "NvimLightBlue"      })
vim.api.nvim_set_hl(0, "JJBrightMagenta", { fg = "NvimLightMagenta"   })
vim.api.nvim_set_hl(0, "JJBrightCyan",    { fg = "NvimLightCyan"      })
vim.api.nvim_set_hl(0, "JJFileModified",  { link = "diffChanged"      })
vim.api.nvim_set_hl(0, "JJFileAdded",     { link = "diffAdded"        })
vim.api.nvim_set_hl(0, "JJFileDeleted",   { link = "diffRemoved"      })
vim.api.nvim_set_hl(0, "JJFileRenamed",   { link = "diffChanged"      })
vim.api.nvim_set_hl(0, "JJFileCopied",    { link = "diffAdded"        })

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
    vim.fn.jobstart(shell_cmd, { term = true })

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

--- Apply one SGR code string (the text between '\27[' and 'm') to a state
--- table. Mutates `state.bold` and `state.fg` in place. Splits compound codes
--- on ';' and consumes the 3-token form of 38;5;N / 48;5;N and the 5-token
--- form of 38;2;R;G;B / 48;2;R;G;B as a single unit. Backgrounds are ignored.
local function apply_sgr(code, state)
  if code == "" or code == "0" then
    state.bold = false
    state.fg = nil
    return
  end

  local tokens = vim.split(code, ";", { plain = true })
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    if t == "0" or t == "" then
      state.bold = false
      state.fg = nil
      i = i + 1
    elseif t == "1" then
      state.bold = true
      i = i + 1
    elseif t == "22" then
      state.bold = false
      i = i + 1
    elseif t == "39" then
      state.fg = nil
      i = i + 1
    elseif t == "38" or t == "48" then
      local is_fg = (t == "38")
      local unit
      if tokens[i + 1] == "5" then
        unit = t .. ";5;" .. (tokens[i + 2] or "")
        i = i + 3
      elseif tokens[i + 1] == "2" then
        unit = t .. ";2;" .. (tokens[i + 2] or "")
            .. ";" .. (tokens[i + 3] or "")
            .. ";" .. (tokens[i + 4] or "")
        i = i + 5
      else
        unit = t
        i = i + 1
      end
      if is_fg and fg_ansi_to_hl[unit] then
        state.fg = fg_ansi_to_hl[unit]
      end
    else
      i = i + 1
    end
  end
end

--- Strip ANSI SGR escapes from a line, returning the plain text plus a list of
--- { col, end_col, hl_group } spans (byte offsets) covering each colored run.
---
--- Bold and foreground are tracked independently; when both are active the
--- parser emits two overlapping spans (e.g. JJBold + JJBrightGreen) so the
--- attributes compose at the extmark layer rather than one masking the other.
--- Unknown SGR codes are silently ignored.
local function parse_ansi_to_spans(line)
  local plain_parts = {}
  local spans = {}
  local bold = false
  local fg = nil
  local bold_start = 0
  local fg_start = 0
  local col = 0
  local i = 1
  local len = #line

  while i <= len do
    if line:byte(i) == 27 and line:sub(i + 1, i + 1) == "[" then
      local m_pos = line:find("m", i + 2, true)
      if not m_pos then
        i = i + 2
      else
        local code = line:sub(i + 2, m_pos - 1)
        local new = { bold = bold, fg = fg }
        apply_sgr(code, new)

        if bold and not new.bold and col > bold_start then
          spans[#spans + 1] = { col = bold_start, end_col = col, hl_group = "JJBold" }
        elseif not bold and new.bold then
          bold_start = col
        end

        if fg ~= new.fg then
          if fg and col > fg_start then
            spans[#spans + 1] = { col = fg_start, end_col = col, hl_group = fg }
          end
          if new.fg then
            fg_start = col
          end
        end

        bold = new.bold
        fg = new.fg
        i = m_pos + 1
      end
    else
      plain_parts[#plain_parts + 1] = line:sub(i, i)
      col = col + 1
      i = i + 1
    end
  end

  if bold and col > bold_start then
    spans[#spans + 1] = { col = bold_start, end_col = col, hl_group = "JJBold" }
  end
  if fg and col > fg_start then
    spans[#spans + 1] = { col = fg_start, end_col = col, hl_group = fg }
  end

  return table.concat(plain_parts), spans
end

--- @class PlainBufferOpts : TerminalWindowOpts
--- @field on_content_loaded fun(window: number, buffer: number)? Fired after lines and highlights are applied

--- Runs a jj command and renders its colorized output into a plain `nofile`
--- buffer (no embedded terminal). ANSI SGR codes from `--color=always` are
--- parsed into extmark highlights.
---
--- Same window-reuse and lifecycle semantics as `run_command_in_terminal_window`,
--- with one extra callback: `on_content_loaded(window, buffer)` fires once the
--- buffer text and highlights are in place.
---
--- @param args string[] Command arguments to pass to jj
--- @param opts PlainBufferOpts Options for the plain buffer
M.run_command_in_plain_buffer = function(args, opts)
  local buffer = opts.buf
  local window = opts.window

  if window and vim.api.nvim_win_is_valid(window) then
    vim.api.nvim_set_current_win(window)
  else
    local split_cmd
    if opts.split_mode == "vsplit" then
      split_cmd = "vsplit"
    else
      split_cmd = "botright split"
    end
    vim.cmd(split_cmd)
    window = vim.api.nvim_get_current_win()
  end

  buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(window, buffer)

  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].buflisted = false
  vim.bo[buffer].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buffer, opts.title or "[JJ]")

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

  local lines = {}
  local all_spans = {}

  vim.fn.jobstart(
    vim.list_extend({ "jj", "--no-pager", "--color=always" }, args),
    {
      stdout_buffered = true,
      stderr_buffered = true,

      on_stdout = function(_, data)
        for _, raw_line in ipairs(data) do
          if raw_line ~= "" then
            local plain, spans = parse_ansi_to_spans(raw_line)
            lines[#lines + 1] = plain
            if #spans > 0 then
              all_spans[#lines] = spans
            end
          end
        end
      end,

      on_stderr = function(_, data)
        for _, raw_line in ipairs(data) do
          if raw_line ~= "" then
            local plain = parse_ansi_to_spans(raw_line)
            lines[#lines + 1] = plain
          end
        end
      end,

      on_exit = function(_, exit_code)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buffer) then return end

          vim.bo[buffer].modifiable = true
          vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
          vim.bo[buffer].modifiable = false

          for line_num, spans in pairs(all_spans) do
            for _, span in ipairs(spans) do
              vim.api.nvim_buf_set_extmark(buffer, ns_id, line_num - 1, span.col, {
                end_col  = span.end_col,
                hl_group = span.hl_group,
                priority = 100,
              })
            end
          end

          if opts.on_content_loaded then
            opts.on_content_loaded(window, buffer)
          end
          if opts.on_exit then
            opts.on_exit(exit_code)
          end
        end)
      end,
    }
  )
end

return M
