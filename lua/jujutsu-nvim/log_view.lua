-- Inline changed-files expansion for the JJ log buffer.
--
-- Responsibilities:
--   * Parse `jj log -s` output into per-commit blocks (header / description / files).
--   * Maintain an `expanded` set keyed by change_id; file lines render only for expanded commits.
--   * Maintain a line -> { block_idx, kind, file_idx } mapping for cursor-based actions.
--   * Provide actions: toggle expansion, open file diff (vsplit), open file content (hsplit).
--
-- The render pipeline plugs into terminal_buffer.run_command_in_plain_buffer via the
-- process_output hook: raw parsed lines + ANSI spans come in, filtered lines/spans go out.

local jj = require("jujutsu-nvim.jujutsu")

local M = {}

local hl_ns = vim.api.nvim_create_namespace("jujutsu_log_view_hl")

-- Persistent state (survives `R` refresh, reset on log window close)
M.expanded = {}            -- set: change_id -> true
M.current_change_id = nil  -- working-copy change_id captured at last refresh

-- Per-render parsed data
local render = {
  blocks = {},     -- { { change_id, is_working_copy, lines = { { kind, plain, spans, file? } } } }
  leading = {},   -- lines before any commit header (rare)
  line_meta = {}, -- 1-indexed: { block_idx, kind, file_idx? }
}

-- Split windows reused across invocations
local diff_left_win = nil
local diff_right_win = nil
local file_split_win = nil
local workspace_root = nil

local function get_workspace_root()
  if workspace_root then return workspace_root end
  local result = vim.system({ "jj", "workspace", "root" }, { text = true }):wait()
  if result.code == 0 then
    workspace_root = vim.trim(result.stdout or "")
    return workspace_root
  end
  return vim.fn.getcwd()
end

M.reset = function()
  M.expanded = {}
  M.current_change_id = nil
  render.blocks = {}
  render.leading = {}
  render.line_meta = {}
  diff_left_win = nil
  diff_right_win = nil
  file_split_win = nil
  workspace_root = nil
end

-- Find an entry in M.expanded that matches `change_id` by shared prefix.
-- jj's `change_id.short()` (used by prepare_open) and the prefix shown by
-- `jj log` (used when parsing blocks) can have different lengths, so a direct
-- table lookup is not safe; compare via `jj.change_ids_match`.
local function find_expanded_key(change_id)
  if M.expanded[change_id] then return change_id end
  for k, _ in pairs(M.expanded) do
    if jj.change_ids_match(k, change_id) then return k end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

-- Parse a `jj log -s` file-status line. Returns nil if the line isn't a file row.
-- Status letters: M (modify), A (add), D (delete), R (rename), C (copy).
-- Rename/copy paths use jj's `{old => new}` infix syntax.
local function parse_file_line(plain)
  local rest = plain:match("^[^%w]*(.+)$")
  if not rest then return nil end
  local status, path = rest:match("^([MADRC])%s+(.+)$")
  if not status then return nil end

  if status == "R" or status == "C" then
    local prefix, old, new, suffix = path:match("^(.-){(.-) => (.-)}(.*)$")
    if prefix then
      return {
        status = status,
        old_path = prefix .. old .. suffix,
        new_path = prefix .. new .. suffix,
        display_path = path,
      }
    end
  end

  return { status = status, path = path, display_path = path }
end

local function parse_output(raw_lines, all_spans)
  local blocks = {}
  local leading = {}
  local current = nil

  for i, plain in ipairs(raw_lines) do
    local spans = all_spans[i]
    local change_id = jj.extract_change_id(plain)
    if change_id and #change_id >= 4 then
      if current then table.insert(blocks, current) end
      current = {
        change_id = change_id,
        is_working_copy = M.current_change_id ~= nil
          and jj.change_ids_match(change_id, M.current_change_id),
        lines = { { kind = "header", plain = plain, spans = spans } },
      }
    else
      local file_info = parse_file_line(plain)
      if file_info and current then
        table.insert(current.lines,
          { kind = "file", plain = plain, spans = spans, file = file_info })
      elseif current then
        table.insert(current.lines, { kind = "other", plain = plain, spans = spans })
      else
        table.insert(leading, { kind = "other", plain = plain, spans = spans })
      end
    end
  end
  if current then table.insert(blocks, current) end

  return blocks, leading
end

local function build_visible(blocks, leading)
  local lines = {}
  local spans_map = {}
  local meta = {}

  local function push(plain, spans, m)
    table.insert(lines, plain)
    if spans then spans_map[#lines] = spans end
    meta[#lines] = m
  end

  for _, item in ipairs(leading) do
    push(item.plain, item.spans, { block_idx = 0, kind = "leading" })
  end

  for bi, block in ipairs(blocks) do
    local is_expanded = find_expanded_key(block.change_id) ~= nil
    local file_counter = 0
    for _, item in ipairs(block.lines) do
      if item.kind == "file" then
        file_counter = file_counter + 1
        if is_expanded then
          push(item.plain, item.spans,
            { block_idx = bi, kind = "file", file_idx = file_counter })
        end
      else
        push(item.plain, item.spans, { block_idx = bi, kind = item.kind })
      end
    end
  end

  return lines, spans_map, meta
end

local function apply_to_buffer(buf, lines, spans_map)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for line_num, spans in pairs(spans_map) do
    for _, span in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(buf, hl_ns, line_num - 1, span.col, {
        end_col = span.end_col,
        hl_group = span.hl_group,
        priority = 100,
      })
    end
  end
end

--------------------------------------------------------------------------------
-- Public render hooks
--------------------------------------------------------------------------------

-- Called before each render. Captures the current working-copy change_id (so
-- block.is_working_copy is correct). On a fresh open (`is_first_open`), wipes
-- the expansion set and auto-expands `@`. Refreshes preserve the existing set.
M.prepare_open = function(is_first_open)
  local result = vim.system(
    { "jj", "log", "--no-graph", "-r", "@", "-T", "change_id.short()" },
    { text = true }
  ):wait()
  local id = nil
  if result.code == 0 then
    id = vim.trim(result.stdout or "")
    if id == "" then id = nil end
  end
  M.current_change_id = id

  if is_first_open then
    M.expanded = {}
    if id then M.expanded[id] = true end
  end
end

-- process_output hook for terminal_buffer.run_command_in_plain_buffer.
M.process_output = function(raw_lines, all_spans)
  render.blocks, render.leading = parse_output(raw_lines, all_spans)
  local lines, spans_map, meta = build_visible(render.blocks, render.leading)
  render.line_meta = meta
  return { lines = lines, spans = spans_map }
end

--------------------------------------------------------------------------------
-- Cursor queries
--------------------------------------------------------------------------------

M.get_meta_at_line = function(line_num)
  return render.line_meta[line_num]
end

M.get_meta_at_cursor = function(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  local line_num = vim.api.nvim_win_get_cursor(win)[1]
  return render.line_meta[line_num]
end

M.get_block_at_cursor = function(win)
  local meta = M.get_meta_at_cursor(win)
  if meta and meta.block_idx and meta.block_idx > 0 then
    return render.blocks[meta.block_idx]
  end
  return nil
end

M.get_change_id_at_cursor = function(win)
  local block = M.get_block_at_cursor(win)
  return block and block.change_id or nil
end

-- Returns (file_info, block) if cursor is on a file line, else nil.
M.get_file_at_cursor = function(win)
  local meta = M.get_meta_at_cursor(win)
  if not meta or meta.kind ~= "file" then return nil end
  local block = render.blocks[meta.block_idx]
  if not block then return nil end
  local count = 0
  for _, item in ipairs(block.lines) do
    if item.kind == "file" then
      count = count + 1
      if count == meta.file_idx then
        return item.file, block
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Toggle expansion
--------------------------------------------------------------------------------

M.toggle_at_cursor = function(buf, win)
  local block = M.get_block_at_cursor(win)
  if not block then
    vim.notify("No commit at cursor", vim.log.levels.WARN)
    return
  end

  local has_files = false
  for _, item in ipairs(block.lines) do
    if item.kind == "file" then has_files = true; break end
  end
  if not has_files then
    vim.notify("No file changes for this commit", vim.log.levels.INFO)
    return
  end

  local existing_key = find_expanded_key(block.change_id)
  if existing_key then
    M.expanded[existing_key] = nil
  else
    M.expanded[block.change_id] = true
  end

  local lines, spans_map, meta = build_visible(render.blocks, render.leading)
  render.line_meta = meta
  apply_to_buffer(buf, lines, spans_map)

  -- Position cursor on the toggled commit's header line.
  for i, m in ipairs(meta) do
    if m.kind == "header" and render.blocks[m.block_idx].change_id == block.change_id then
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { i, 0 })
      end
      break
    end
  end
end

--------------------------------------------------------------------------------
-- Diff and file-open helpers
--------------------------------------------------------------------------------

local function detect_filetype(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok and ft and ft ~= "" then return ft end
  return nil
end

local function make_scratch_buffer(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

local function set_buf_lines(buf, content_lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
  vim.bo[buf].modifiable = false
end

local function fetch_file_content(rev, path, callback)
  vim.system(
    { "jj", "file", "show", "-r", rev, path },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code == 0 then
        local content = result.stdout or ""
        content = content:gsub("\n$", "")
        callback(vim.split(content, "\n", { plain = true }))
      else
        callback({})
      end
    end)
  )
end

-- Total editor width below which the two diff panes are placed *below* the log
-- window (each gets the full screen width split in half) instead of squeezed to
-- the right of the log.
local DIFF_SIDE_BY_SIDE_MIN_COLUMNS = 80

local function ensure_diff_windows(log_win)
  if diff_left_win and diff_right_win
    and vim.api.nvim_win_is_valid(diff_left_win)
    and vim.api.nvim_win_is_valid(diff_right_win) then
    return diff_left_win, diff_right_win
  end

  -- Clean up partial state
  if diff_left_win and vim.api.nvim_win_is_valid(diff_left_win) then
    pcall(vim.api.nvim_win_close, diff_left_win, true)
  end
  if diff_right_win and vim.api.nvim_win_is_valid(diff_right_win) then
    pcall(vim.api.nvim_win_close, diff_right_win, true)
  end

  vim.api.nvim_set_current_win(log_win)
  if vim.o.columns >= DIFF_SIDE_BY_SIDE_MIN_COLUMNS then
    -- Wide: log | parent | current
    vim.cmd("rightbelow vnew")
    diff_right_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    diff_left_win = vim.api.nvim_get_current_win()
  else
    -- Narrow: log on top, parent | current below
    vim.cmd("belowright new")
    diff_right_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    diff_left_win = vim.api.nvim_get_current_win()
  end
  return diff_left_win, diff_right_win
end

local function ensure_file_window(log_win)
  if file_split_win and vim.api.nvim_win_is_valid(file_split_win) then
    return file_split_win
  end
  vim.api.nvim_set_current_win(log_win)
  vim.cmd("rightbelow new")
  file_split_win = vim.api.nvim_get_current_win()
  return file_split_win
end

local function close_diff_windows(log_win)
  if diff_left_win and vim.api.nvim_win_is_valid(diff_left_win) then
    pcall(vim.api.nvim_win_close, diff_left_win, false)
  end
  if diff_right_win and vim.api.nvim_win_is_valid(diff_right_win) then
    pcall(vim.api.nvim_win_close, diff_right_win, false)
  end
  diff_left_win = nil
  diff_right_win = nil
  if log_win and vim.api.nvim_win_is_valid(log_win) then
    vim.api.nvim_set_current_win(log_win)
  end
end

local function close_file_split(log_win)
  if file_split_win and vim.api.nvim_win_is_valid(file_split_win) then
    pcall(vim.api.nvim_win_close, file_split_win, false)
  end
  file_split_win = nil
  if log_win and vim.api.nvim_win_is_valid(log_win) then
    vim.api.nvim_set_current_win(log_win)
  end
end

local function bind_close_q(win, close_fn)
  if not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.keymap.set("n", "q", close_fn,
    { buffer = buf, silent = true, desc = "JJ: Close diff/file split" })
end

M.open_diff_at_cursor = function(log_win)
  local file_info, block = M.get_file_at_cursor(log_win)
  if not file_info or not block then
    vim.notify("Cursor not on a file line", vim.log.levels.WARN)
    return
  end

  local rev = block.change_id
  local parent_rev = rev .. "-"
  local is_wc = block.is_working_copy
  local left_path = file_info.old_path or file_info.path
  local right_path = file_info.new_path or file_info.path

  local left_win, right_win = ensure_diff_windows(log_win)

  -- Left: parent revision (empty for additions).
  local left_filetype = detect_filetype(left_path)
  local left_label = (file_info.status == "A")
    and ("[parent] " .. left_path .. " (added)")
    or ("[" .. parent_rev .. "] " .. left_path)
  local left_buf = make_scratch_buffer(left_label, left_filetype)
  vim.api.nvim_win_set_buf(left_win, left_buf)
  if file_info.status ~= "A" then
    fetch_file_content(parent_rev, left_path, function(content)
      set_buf_lines(left_buf, content)
    end)
  end

  -- Right: commit revision (or live file if working copy; empty for deletions).
  local right_filetype = detect_filetype(right_path)
  if file_info.status == "D" then
    local right_buf = make_scratch_buffer("[deleted] " .. left_path, right_filetype)
    vim.api.nvim_win_set_buf(right_win, right_buf)
  elseif is_wc then
    local abs_path = get_workspace_root() .. "/" .. right_path
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
  else
    local right_buf = make_scratch_buffer("[" .. rev .. "] " .. right_path, right_filetype)
    vim.api.nvim_win_set_buf(right_win, right_buf)
    fetch_file_content(rev, right_path, function(content)
      set_buf_lines(right_buf, content)
    end)
  end

  -- Activate diff mode in both windows and rebind `q` on the current buffers.
  vim.schedule(function()
    local close_fn = function() close_diff_windows(log_win) end
    if vim.api.nvim_win_is_valid(left_win) then
      vim.api.nvim_set_current_win(left_win)
      vim.cmd("diffthis")
      bind_close_q(left_win, close_fn)
    end
    if vim.api.nvim_win_is_valid(right_win) then
      vim.api.nvim_set_current_win(right_win)
      vim.cmd("diffthis")
      bind_close_q(right_win, close_fn)
    end
  end)
end

M.open_file_at_cursor = function(log_win)
  local file_info, block = M.get_file_at_cursor(log_win)
  if not file_info or not block then
    vim.notify("Cursor not on a file line", vim.log.levels.WARN)
    return
  end

  local path = file_info.new_path or file_info.path
  local rev = block.change_id
  local is_wc = block.is_working_copy

  local win = ensure_file_window(log_win)
  vim.api.nvim_set_current_win(win)

  if is_wc then
    local abs_path = get_workspace_root() .. "/" .. path
    vim.cmd("edit " .. vim.fn.fnameescape(abs_path))
  else
    local buf = make_scratch_buffer("[" .. rev .. "] " .. path, detect_filetype(path))
    vim.api.nvim_win_set_buf(win, buf)
    fetch_file_content(rev, path, function(content)
      set_buf_lines(buf, content)
    end)
  end

  bind_close_q(win, function() close_file_split(log_win) end)
end

return M
