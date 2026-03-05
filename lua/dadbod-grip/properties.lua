-- properties.lua: table properties float.
-- Shows full table metadata: columns, PKs, FKs, indexes, row estimate, size.
-- Opened via gI from a grip grid or :GripProperties command.

local db   = require("dadbod-grip.db")
local sql  = require("dadbod-grip.sql")

local M = {}

-- ── format helpers ──────────────────────────────────────────────────────────

local function format_size(bytes)
  if not bytes or bytes <= 0 then return "N/A" end
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
  return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
end

local function format_count(n)
  if not n or n <= 0 then return "N/A" end
  if n < 1000 then return tostring(n) end
  if n < 1000000 then return string.format("~%.1fK", n / 1000) end
  return string.format("~%.1fM", n / 1000000)
end

-- ── refresh open grip buffers for a table ───────────────────────────────────

local function refresh_grip_buffers(table_name)
  local view = require("dadbod-grip.view")
  for bufnr, session in pairs(view._sessions) do
    if session.state and session.state.table_name == table_name then
      if session.on_refresh and vim.api.nvim_buf_is_valid(bufnr) then
        vim.schedule(function() session.on_refresh(bufnr) end)
      end
    end
  end
end

-- ── gather all properties ───────────────────────────────────────────────────

local function gather(table_name, url)
  local props = { table_name = table_name }

  -- Column info (reuses existing adapter method)
  local col_info, col_err = db.get_column_info(table_name, url)
  props.columns = col_info or {}
  if col_err then props.col_error = col_err end

  -- Primary keys
  local pks, _ = db.get_primary_keys(table_name, url)
  props.primary_keys = pks or {}

  -- Foreign keys
  local fks, _ = db.get_foreign_keys(table_name, url)
  props.foreign_keys = fks or {}

  -- Indexes
  local indexes, _ = db.get_indexes(table_name, url)
  props.indexes = indexes or {}

  -- Table stats (row estimate + size)
  local stats, _ = db.get_table_stats(table_name, url)
  props.row_estimate = stats and stats.row_estimate or 0
  props.size_bytes = stats and stats.size_bytes or 0

  return props
end

-- ── build display lines ─────────────────────────────────────────────────────

local function build_lines(props)
  local lines = {}
  local hl_marks = {}  -- {line_idx, start_col, end_col, hl_group}

  local function add(s) table.insert(lines, s) end
  local function add_hl(hl, start_col, end_col)
    hl_marks[#lines] = hl_marks[#lines] or {}
    table.insert(hl_marks[#lines], { hl = hl, start_col = start_col, end_col = end_col })
  end

  -- Header
  add("  Table: " .. props.table_name)
  add_hl("GripHeader", 2, #lines[#lines])

  -- Stats line
  local stats_parts = {}
  if props.row_estimate > 0 then
    table.insert(stats_parts, "Rows: " .. format_count(props.row_estimate))
  end
  if props.size_bytes > 0 then
    table.insert(stats_parts, "Size: " .. format_size(props.size_bytes))
  end
  if #stats_parts > 0 then
    add("  " .. table.concat(stats_parts, "    "))
  end

  add("")

  -- Columns table
  add("  Columns")
  add_hl("GripHeader", 2, 9)

  -- Calculate column widths for the table
  local col_widths = { num = 3, name = 4, dtype = 4, null = 4, default = 7 }
  for i, col in ipairs(props.columns) do
    col_widths.num = math.max(col_widths.num, #tostring(i))
    col_widths.name = math.max(col_widths.name, #col.column_name)
    col_widths.dtype = math.max(col_widths.dtype, #col.data_type)
    col_widths.default = math.max(col_widths.default, #col.column_default)
  end
  -- Clamp widths
  col_widths.name = math.min(col_widths.name, 24)
  col_widths.dtype = math.min(col_widths.dtype, 20)
  col_widths.default = math.min(col_widths.default, 20)

  local function pad(s, w) return s .. string.rep(" ", math.max(0, w - #s)) end
  local function col_row(num, name, dtype, nullable, default)
    return "  " .. pad(num, col_widths.num) ..
           "  " .. pad(name, col_widths.name) ..
           "  " .. pad(dtype, col_widths.dtype) ..
           "  " .. pad(nullable, 4) ..
           "  " .. default
  end

  -- Header row
  add(col_row("#", "Name", "Type", "Null", "Default"))
  add("  " .. string.rep("-", col_widths.num + col_widths.name + col_widths.dtype + 4 + col_widths.default + 10))

  -- Column rows (track line -> column name for DDL keymaps)
  local col_line_map = {}
  local pk_set = {}
  for _, pk in ipairs(props.primary_keys) do pk_set[pk] = true end
  local fk_set = {}
  for _, fk in ipairs(props.foreign_keys) do fk_set[fk.column] = fk end

  for i, col in ipairs(props.columns) do
    local marker = ""
    if pk_set[col.column_name] then marker = " PK" end
    if fk_set[col.column_name] then marker = marker .. " FK" end

    local nullable = col.is_nullable == "YES" and "YES" or "NO"
    local default_val = col.column_default ~= "" and col.column_default or ""
    -- Truncate long values so they don't break column alignment
    local col_name = col.column_name
    if #col_name > col_widths.name then col_name = col_name:sub(1, col_widths.name - 1) .. "~" end
    local dtype = col.data_type
    if #dtype > col_widths.dtype then dtype = dtype:sub(1, col_widths.dtype - 1) .. "~" end
    if #default_val > col_widths.default then
      default_val = default_val:sub(1, col_widths.default - 1) .. "~"
    end

    add(col_row(tostring(i), col_name, dtype, nullable, default_val .. marker))
    col_line_map[#lines] = col.column_name
  end

  add("")

  -- Primary key
  if #props.primary_keys > 0 then
    add("  Primary Key")
    add_hl("GripHeader", 2, 13)
    add("    (" .. table.concat(props.primary_keys, ", ") .. ")")
    add("")
  end

  -- Foreign keys
  if #props.foreign_keys > 0 then
    add("  Foreign Keys")
    add_hl("GripHeader", 2, 14)
    for _, fk in ipairs(props.foreign_keys) do
      add("    " .. fk.column .. " -> " .. fk.ref_table .. "(" .. fk.ref_column .. ")")
    end
    add("")
  end

  -- Indexes
  if #props.indexes > 0 then
    add("  Indexes")
    add_hl("GripHeader", 2, 9)
    -- Calculate max name width for alignment
    local max_name = 0
    for _, idx in ipairs(props.indexes) do
      max_name = math.max(max_name, #idx.name)
    end
    max_name = math.min(max_name, 30)
    for _, idx in ipairs(props.indexes) do
      local dots = string.rep(".", math.max(2, max_name - #idx.name + 3))
      local idx_type = idx.type or "INDEX"
      local cols_str = table.concat(idx.columns or {}, ", ")
      add("    " .. idx.name .. " " .. dots .. " " .. idx_type .. " (" .. cols_str .. ")")
    end
    add("")
  end

  -- Footer
  add("  q close   T rename tbl   R rename col   + add col   D drop col   gI refresh")

  return lines, hl_marks, col_line_map
end

-- ── open float ──────────────────────────────────────────────────────────────

function M.open(table_name, url, grip_win)
  if not table_name or table_name == "" then
    vim.notify("Table properties requires a table name", vim.log.levels.INFO)
    return
  end

  local props = gather(table_name, url)
  local lines, hl_marks, col_line_map = build_lines(props)

  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end

  local width = math.min(math.max(max_w + 4, 50), vim.o.columns - 10)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8))

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(popup_buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Table Properties ",
    title_pos = "center",
    zindex = 50,
  })

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("grip_properties")
  for line_idx, marks in pairs(hl_marks) do
    for _, mark in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, popup_buf, ns, line_idx - 1, mark.start_col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
      })
    end
  end

  -- Close keymaps
  local caller_win = grip_win or vim.fn.win_getid()
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = popup_buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      if vim.api.nvim_win_is_valid(caller_win) then
        vim.api.nvim_set_current_win(caller_win)
      end
    end, { buffer = popup_buf })
  end

  -- gI: reopen (refresh) properties
  local function reopen()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(caller_win) then
      vim.api.nvim_set_current_win(caller_win)
    end
    vim.schedule(function()
      M.open(table_name, url, caller_win)
    end)
  end

  vim.keymap.set("n", "gI", reopen, { buffer = popup_buf })

  -- Helper: get column name under cursor
  local function cursor_column()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return col_line_map[row]
  end

  -- R: rename column under cursor
  vim.keymap.set("n", "R", function()
    local col_name = cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column row", vim.log.levels.INFO)
      return
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    local ddl = require("dadbod-grip.ddl")
    ddl.rename_column(table_name, col_name, url, function()
      -- Refresh properties and any open grip buffers
      reopen()
      refresh_grip_buffers(table_name)
    end)
  end, { buffer = popup_buf })

  -- +: add column
  vim.keymap.set("n", "+", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    local ddl = require("dadbod-grip.ddl")
    ddl.add_column(table_name, url, function()
      reopen()
      refresh_grip_buffers(table_name)
    end)
  end, { buffer = popup_buf })

  -- T: rename table
  vim.keymap.set("n", "T", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(caller_win) then
      vim.api.nvim_set_current_win(caller_win)
    end
    local ddl = require("dadbod-grip.ddl")
    ddl.rename_table(table_name, url, function(new_name)
      require("dadbod-grip.view").update_table_sessions(table_name, new_name)
    end)
  end, { buffer = popup_buf })

  -- D: drop column under cursor
  vim.keymap.set("n", "D", function()
    local col_name = cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column row", vim.log.levels.INFO)
      return
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    local ddl = require("dadbod-grip.ddl")
    ddl.drop_column(table_name, col_name, url, function()
      reopen()
      refresh_grip_buffers(table_name)
    end)
  end, { buffer = popup_buf })

  return win, popup_buf
end

return M
