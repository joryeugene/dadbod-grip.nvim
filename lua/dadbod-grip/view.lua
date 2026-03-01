-- view.lua — buffer rendering + keymaps.
-- One buffer per grip session. State in M._sessions[bufnr].

local data  = require("dadbod-grip.data")
local sql   = require("dadbod-grip.sql")
local db    = require("dadbod-grip.db")
local qmod  = require("dadbod-grip.query")

local M = {}
M._sessions = {}  -- [bufnr] = { state, url, query_sql }

-- ── constants ──────────────────────────────────────────────────────────────
local NULL_DISPLAY  = "·NULL·"
local BINARY_PREFIX = "<binary"
local MAX_COL_WIDTH = 40  -- overridden by setup opts

local SEP_COL = "│"
local SEP_HDR = "═"
local SEP_MID = "╪"
local TOP_L   = "╔"
local TOP_R   = "╗"
local MID_L   = "╠"
local MID_R   = "╣"
local BOT_L   = "╚"
local BOT_R   = "╝"
local BOT_MID = "╧"
local TOP_MID = "╤"
local FREEZE_SEP = "┃"
local FREEZE_MID = "╋"

-- ── highlight group setup ──────────────────────────────────────────────────
local function ensure_highlights()
  local groups = {
    GripHeader   = "bold",
    GripNull     = "italic",
    GripModified = "bold",
    GripDeleted  = "strikethrough",
    GripInserted = "bold",
    GripReadonly = "italic",
    GripBorder   = "bold",
    GripStatusOk = "bold",
    GripStatusChg = "bold",
    GripFreeze    = "bold",
    GripNegative  = "bold",
    GripBoolTrue  = "bold",
    GripBoolFalse = "bold",
    GripDatePast  = "italic",
    GripUrl       = "underline",
  }
  for name, _ in pairs(groups) do
    if vim.fn.hlID(name) == 0 then
      if name == "GripHeader"   then vim.cmd("hi GripHeader gui=bold cterm=bold") end
      if name == "GripNull"     then vim.cmd("hi GripNull gui=italic ctermfg=243 guifg=#6c7086") end
      if name == "GripModified" then vim.cmd("hi GripModified gui=bold ctermfg=81 guifg=#89dceb") end
      if name == "GripDeleted"  then vim.cmd("hi GripDeleted gui=strikethrough ctermfg=203 guifg=#f38ba8") end
      if name == "GripInserted" then vim.cmd("hi GripInserted gui=bold ctermfg=113 guifg=#a6e3a1") end
      if name == "GripReadonly" then vim.cmd("hi GripReadonly gui=italic ctermfg=243 guifg=#6c7086") end
      if name == "GripBorder"   then vim.cmd("hi GripBorder gui=bold ctermfg=147 guifg=#cba6f7") end
      if name == "GripStatusChg" then vim.cmd("hi GripStatusChg gui=bold ctermfg=229 guifg=#f9e2af") end
      if name == "GripFreeze"    then vim.cmd("hi GripFreeze gui=bold ctermfg=147 guifg=#f5c2e7") end
      if name == "GripNegative"  then vim.cmd("hi GripNegative gui=bold ctermfg=203 guifg=#f38ba8") end
      if name == "GripBoolTrue"  then vim.cmd("hi GripBoolTrue gui=bold ctermfg=113 guifg=#a6e3a1") end
      if name == "GripBoolFalse" then vim.cmd("hi GripBoolFalse gui=bold ctermfg=203 guifg=#f38ba8") end
      if name == "GripDatePast"  then vim.cmd("hi GripDatePast gui=italic ctermfg=243 guifg=#6c7086") end
      if name == "GripUrl"       then vim.cmd("hi GripUrl gui=underline ctermfg=117 guifg=#89b4fa") end
    end
  end
end

-- ── column width calculation ──────────────────────────────────────────────
local function calc_col_widths(columns, rows, max_width)
  local widths = {}
  for _, col in ipairs(columns) do
    widths[col] = math.min(vim.fn.strdisplaywidth(col), max_width)
  end
  for _, row_data in ipairs(rows) do
    for i, col in ipairs(columns) do
      local v = row_data[i] or ""
      local display = (v == nil or v == "") and NULL_DISPLAY or tostring(v)
      widths[col] = math.min(math.max(widths[col], vim.fn.strdisplaywidth(display)), max_width)
    end
  end
  return widths
end

-- ── cell display formatting ───────────────────────────────────────────────
local function format_cell(value, width, is_null_staged)
  if is_null_staged or value == nil then
    local s = NULL_DISPLAY
    local sw = vim.fn.strdisplaywidth(s)
    if sw > width then
      s = vim.fn.strcharpart(s, 0, width - 1) .. "…"
      sw = width
    end
    return s .. string.rep(" ", width - sw), "GripNull"
  end
  if value:sub(1, #BINARY_PREFIX) == BINARY_PREFIX then
    local s = vim.fn.strcharpart(value, 0, width)
    local sw = vim.fn.strdisplaywidth(s)
    return s .. string.rep(" ", width - sw), "GripReadonly"
  end
  local display = value ~= "" and value:gsub("\n", "↵"):gsub("\r", "") or NULL_DISPLAY
  local hl = value == "" and "GripNull" or nil
  local dw = vim.fn.strdisplaywidth(display)
  if dw > width then
    display = vim.fn.strcharpart(display, 0, width - 1) .. "…"
    dw = width
  end
  return display .. string.rep(" ", width - dw), hl
end

--- Classify a cell value for conditional formatting.
--- Returns hl_group string or nil. Only for clean, non-null cells.
local function classify_cell(value, data_type)
  if value == nil or value == "" then return nil end
  local val_lower = value:lower()

  -- Boolean detection
  if data_type then
    local dt = data_type:lower()
    if dt:match("bool") or dt:match("tinyint%(1%)") then
      if val_lower == "t" or val_lower == "true" or val_lower == "1" or val_lower == "yes" then
        return "GripBoolTrue"
      elseif val_lower == "f" or val_lower == "false" or val_lower == "0" or val_lower == "no" then
        return "GripBoolFalse"
      end
    end
  end
  -- Detect explicit true/false without type info
  if val_lower == "true" or val_lower == "t" then return "GripBoolTrue" end
  if val_lower == "false" or val_lower == "f" then return "GripBoolFalse" end

  -- Negative numbers
  local num = tonumber(value)
  if num and num < 0 then return "GripNegative" end

  -- URLs and emails
  if value:match("^https?://") or value:match("^[%w%.%-]+@[%w%.%-]+%.[%w]+$") then
    return "GripUrl"
  end

  -- Dates in the past (requires data_type)
  if data_type then
    local dt = data_type:lower()
    if dt:match("date") or dt:match("timestamp") then
      local y, m, d = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
      if y then
        local date_str = string.format("%04d-%02d-%02d", tonumber(y), tonumber(m), tonumber(d))
        if date_str < os.date("%Y-%m-%d") then
          return "GripDatePast"
        end
      end
    end
  end

  return nil
end

-- ── border line builders ──────────────────────────────────────────────────
local function border_line(columns, widths, left, mid, sep, right, freeze_after)
  local parts = { left }
  for i, col in ipairs(columns) do
    table.insert(parts, string.rep(sep, widths[col] + 2))
    if i < #columns then
      if freeze_after and i == freeze_after then
        table.insert(parts, FREEZE_MID)
      else
        table.insert(parts, mid)
      end
    end
  end
  table.insert(parts, right)
  return table.concat(parts)
end

-- Build the title bar with connection/table info and staged count.
local function title_line(session, columns, widths, total_width)
  local staged = data.count_staged(session.state)
  local badges = {}
  if staged > 0 then table.insert(badges, staged .. " staged") end
  if session.state.readonly then table.insert(badges, "read-only: no PK") end
  if session.query_spec and qmod.has_filters(session.query_spec) then
    table.insert(badges, "filtered")
  end
  if session.pinned_count and session.pinned_count > 0 then
    table.insert(badges, session.pinned_count .. " pinned")
  end
  local right_info = #badges > 0 and (" [" .. table.concat(badges, " | ") .. "] ") or " "

  -- Build title with breadcrumb for FK navigation
  local title_text = session.state.table_name or "(query result)"
  if session.nav_stack and #session.nav_stack > 0 then
    local crumbs = {}
    for _, frame in ipairs(session.nav_stack) do
      table.insert(crumbs, frame.table_name or "?")
    end
    table.insert(crumbs, title_text)
    title_text = table.concat(crumbs, " > ")
  end
  local title = " " .. title_text .. " "
  -- Pad title line to fill width
  local inner = total_width - 3  -- ╔═(2) + ═╗(2) - 1 (gsub strips trailing space from right_info)
  local title_len = #title + #right_info
  local filler = math.max(0, inner - title_len)
  return "╔═" .. title .. string.rep("═", filler) .. right_info:gsub(" $", "") .. "═╗"
end

-- ── main render ──────────────────────────────────────────────────────────
-- Returns {lines=[], extmarks=[{row, col, end_col, hl_group}]}
local function build_render(session, opts)
  local configured_max = (opts and opts.max_col_width) or MAX_COL_WIDTH
  local st = session.state
  local columns = st.columns
  local ordered = data.get_ordered_rows(st)
  local pin = session.pinned_count or 0
  if pin >= #columns then pin = 0 end  -- can't pin all columns

  -- Build data type map for conditional formatting
  local cond_type_map = {}
  if session._column_info then
    for _, ci in ipairs(session._column_info) do
      cond_type_map[ci.column_name] = ci.data_type
    end
  end

  -- Compute column widths across all rows including staged changes
  local display_rows = {}
  for _, row_idx in ipairs(ordered) do
    local dr = {}
    for i, col in ipairs(columns) do
      local eff = data.effective_value(st, row_idx, col)
      table.insert(dr, eff or "")
    end
    table.insert(display_rows, dr)
  end

  -- Auto-fit: compute natural widths first (clamped to configured max)
  local widths = calc_col_widths(columns, display_rows, configured_max)

  -- Smart auto-fit: if total fits, expand narrow columns proportionally
  local available = vim.o.columns - 4  -- borders + padding
  local total_natural = 0
  for _, col in ipairs(columns) do total_natural = total_natural + widths[col] + 3 end
  if #columns > 0 and total_natural < available then
    -- Distribute extra space to columns that were truncated
    local slack = available - total_natural
    for _, col in ipairs(columns) do
      if slack <= 0 then break end
      local natural = widths[col]
      if natural >= configured_max then
        local extra = math.min(slack, 20)  -- max 20 extra chars per column
        widths[col] = natural + extra
        slack = slack - extra
      end
    end
  end

  -- Total visual width of content area
  local total_inner = 0
  for _, col in ipairs(columns) do total_inner = total_inner + widths[col] + 3 end
  if #columns > 0 then total_inner = total_inner - 1 end  -- no trailing sep
  local total_width = total_inner + 2  -- + borders

  local lines = {}
  local marks = {}  -- {line_idx (1-based), byte_start, byte_end, hl}

  local function push_mark(line_idx, byte_start, byte_end, hl)
    table.insert(marks, { line = line_idx - 1, col = byte_start, end_col = byte_end, hl = hl })
  end

  -- ── Title row ──
  local title = title_line(session, columns, widths, total_width)
  table.insert(lines, title)
  push_mark(#lines, 0, #title, "GripBorder")

  -- ── Header row ──
  local hdr_parts = { "║ " }
  local qspec = session.query_spec
  for i, col in ipairs(columns) do
    local is_ro = st.readonly
    local prefix = is_ro and "~" or ""
    local sort_ind = qspec and qmod.get_sort_indicator(qspec, col) or nil
    local suffix = sort_ind and " " .. sort_ind or ""
    local label = prefix .. col .. suffix
    local w = widths[col]
    local lw = vim.fn.strdisplaywidth(label)
    if lw > w then
      label = vim.fn.strcharpart(label, 0, w - 1) .. "…"
      lw = w
    end
    local padded = label .. string.rep(" ", w - lw)
    table.insert(hdr_parts, padded)
    if i < #columns then
      local col_sep = (pin > 0 and i == pin) and (" " .. FREEZE_SEP .. " ") or (" " .. SEP_COL .. " ")
      table.insert(hdr_parts, col_sep)
    end
  end
  table.insert(hdr_parts, " ║")
  local hdr_line = table.concat(hdr_parts)
  table.insert(lines, hdr_line)
  push_mark(#lines, 0, #hdr_line, "GripHeader")

  -- ── Type annotation row (T toggle) ──
  local has_type_row = false
  if session.show_types and session._column_info then
    local type_map = {}
    for _, ci in ipairs(session._column_info) do
      type_map[ci.column_name] = ci.data_type
    end
    local type_parts = { "║ " }
    for i, col in ipairs(columns) do
      local dtype = type_map[col] or ""
      local w = widths[col]
      local dw = vim.fn.strdisplaywidth(dtype)
      if dw > w then
        dtype = vim.fn.strcharpart(dtype, 0, w - 1) .. "…"
        dw = w
      end
      local padded = dtype .. string.rep(" ", w - dw)
      table.insert(type_parts, padded)
      if i < #columns then
        local col_sep = (pin > 0 and i == pin) and (" " .. FREEZE_SEP .. " ") or (" " .. SEP_COL .. " ")
        table.insert(type_parts, col_sep)
      end
    end
    table.insert(type_parts, " ║")
    local type_line = table.concat(type_parts)
    table.insert(lines, type_line)
    push_mark(#lines, 0, #type_line, "GripNull")
    has_type_row = true
  end

  -- ── Separator after header ──
  local freeze_at = pin > 0 and pin or nil
  local sep_line = border_line(columns, widths, MID_L, SEP_MID, SEP_HDR, MID_R, freeze_at)
  table.insert(lines, sep_line)
  push_mark(#lines, 0, #sep_line, "GripBorder")

  -- Byte-length constants for UTF-8 box-drawing chars (║=3 bytes, │=3 bytes)
  local ROW_PREFIX = "║ "
  local ROW_PREFIX_BYTES = #ROW_PREFIX  -- 4 bytes (3+1)
  local COL_SEP = " " .. SEP_COL .. " "
  local COL_SEP_BYTES = #COL_SEP  -- 5 bytes (1+3+1)
  local row_byte_positions = {}  -- [row_order_idx] = {col_name = {start, finish}}

  -- ── Data rows ──
  if #ordered == 0 then
    local empty = "║" .. string.rep(" ", total_inner) .. "║"
    local msg_s = " (empty result) "
    local start_col = math.floor((total_inner - #msg_s) / 2) + 1
    local empty_line = "║" ..
      string.rep(" ", start_col - 1) .. msg_s ..
      string.rep(" ", total_inner - start_col - #msg_s + 1) .. "║"
    table.insert(lines, empty_line)
  else
    for di, row_idx in ipairs(ordered) do
      local status = data.row_status(st, row_idx)
      local row_parts = { ROW_PREFIX }
      local line_byte_positions = {}  -- {col_name = {start, finish}}
      local byte_pos = ROW_PREFIX_BYTES  -- after "║ " (4 bytes, not 2)

      for i, col in ipairs(columns) do
        local eff = data.effective_value(st, row_idx, col)
        local is_null = (eff == nil or eff == "")
        local w = widths[col]
        local cell_str, cell_hl = format_cell(eff, w, is_null and (eff == nil))

        line_byte_positions[col] = { start = byte_pos, finish = byte_pos + #cell_str - 1 }

        if status == "modified" and st.changes[row_idx] and st.changes[row_idx][col] ~= nil then
          cell_hl = "GripModified"
        elseif status == "deleted" then
          cell_hl = "GripDeleted"
        elseif status == "inserted" then
          cell_hl = "GripInserted"
        end

        table.insert(row_parts, cell_str)
        byte_pos = byte_pos + #cell_str

        if i < #columns then
          local sep = (pin > 0 and i == pin) and (" " .. FREEZE_SEP .. " ") or COL_SEP
          table.insert(row_parts, sep)
          byte_pos = byte_pos + #sep  -- same byte width (5) for both separators
        end
      end

      row_byte_positions[di] = line_byte_positions

      table.insert(row_parts, " ║")
      local row_line = table.concat(row_parts)
      table.insert(lines, row_line)

      local li = #lines
      -- Apply per-cell highlights
      for _, col in ipairs(columns) do
        local bp = line_byte_positions[col]
        if bp then
          local eff = data.effective_value(st, row_idx, col)
          local cell_hl
          if status == "deleted" then
            cell_hl = "GripDeleted"
          elseif status == "inserted" then
            cell_hl = "GripInserted"
          elseif status == "modified" and st.changes[row_idx] and st.changes[row_idx][col] ~= nil then
            cell_hl = "GripModified"
          elseif eff == nil or eff == "" then
            cell_hl = "GripNull"
          else
            cell_hl = classify_cell(eff, cond_type_map[col])
          end
          if cell_hl then
            push_mark(li, bp.start, bp.finish + 1, cell_hl)
          end
        end
      end
    end
  end

  -- ── Bottom border ──
  local bot_line = border_line(columns, widths, BOT_L, BOT_MID, SEP_HDR, BOT_R, freeze_at)
  table.insert(lines, bot_line)
  push_mark(#lines, 0, #bot_line, "GripBorder")

  -- ── Status line ──
  local staged_count = data.count_staged(st)
  local status_parts = {}

  -- Row/page info
  if session.query_spec and session.total_rows then
    table.insert(status_parts, qmod.page_info(session.query_spec, session.total_rows))
  else
    table.insert(status_parts, #st.rows .. " rows")
  end

  if staged_count > 0 then table.insert(status_parts, staged_count .. " staged") end
  if st.readonly then table.insert(status_parts, "read-only") end
  if pin > 0 then table.insert(status_parts, pin .. " pinned") end

  -- Filter summary
  if session.query_spec then
    local fs = qmod.filter_summary(session.query_spec)
    if fs ~= "" then table.insert(status_parts, fs) end
  end

  local status_str = " " .. table.concat(status_parts, "  │  ")
  table.insert(lines, status_str)

  -- ── Hint line ──
  local hints = st.readonly
    and " r:refresh  Tab:columns  q:quit  ?:help"
    or  " e:edit  o:insert  d:delete  a:apply  u:undo  r:refresh  Tab:columns  q:quit  ?:help"
  table.insert(lines, hints)

  local data_start = has_type_row and 5 or 4
  return { lines = lines, marks = marks, widths = widths, ordered = ordered, byte_positions = row_byte_positions, data_start = data_start }
end

-- ── namespace for extmarks ───────────────────────────────────────────────
local ns = vim.api.nvim_create_namespace("dadbod_grip")

-- M.render(bufnr, state) — wipes and rewrites buffer, reapplies extmarks
function M.render(bufnr, state)
  local session = M._sessions[bufnr]
  if not session then return end
  session.state = state

  -- Save cursor position before re-render
  local saved_cursor
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    saved_cursor = vim.api.nvim_win_get_cursor(win)
  end

  local opts = session.opts or {}
  local rendered = build_render(session, opts)
  session._render = rendered  -- cache for get_cell

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered.lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for _, m in ipairs(rendered.marks) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, m.line, m.col, {
        end_col = m.end_col,
        hl_group = m.hl,
        priority = 100,
      })
    end

  end)

  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  -- Restore cursor position
  if saved_cursor and win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, saved_cursor)
  end

  if not ok then
    vim.notify("Grip: render error: " .. tostring(err), vim.log.levels.WARN)
  end

  -- Update live SQL float if active
  M._update_live_sql_float(session)
end

local UNDO_STACK_MAX = 50

-- M.apply_edit(bufnr, new_state) — pushes current state to undo stack, then renders.
-- Use this for user-initiated edits (not for refresh/requery).
function M.apply_edit(bufnr, new_state)
  local session = M._sessions[bufnr]
  if not session then return end
  if not session._undo_stack then session._undo_stack = {} end
  table.insert(session._undo_stack, session.state)
  if #session._undo_stack > UNDO_STACK_MAX then
    table.remove(session._undo_stack, 1)
  end
  M.render(bufnr, new_state)
end

-- ── live SQL float ──────────────────────────────────────────────────────
function M._update_live_sql_float(session)
  if not session.live_sql then return end
  local st = session.state
  if not st.table_name then return end

  -- Build content
  local content_lines
  if data.has_changes(st) then
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    content_lines = {}
    for line in (preview .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then table.insert(content_lines, line) end
    end
  else
    content_lines = { "-- stage changes to see live SQL" }
  end

  local editor_cols = vim.o.columns
  local max_line_w = 0
  for _, l in ipairs(content_lines) do max_line_w = math.max(max_line_w, #l) end
  local float_w = math.min(math.max(max_line_w + 4, 30), editor_cols - 10)
  local float_h = math.min(#content_lines, 15)

  -- Reuse existing float or create new one
  if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
    -- Update buffer contents
    vim.api.nvim_set_option_value("modifiable", true, { buf = session._live_sql_buf })
    vim.api.nvim_buf_set_lines(session._live_sql_buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = session._live_sql_buf })
    -- Resize if needed
    vim.api.nvim_win_set_width(session._live_sql_win, float_w)
    vim.api.nvim_win_set_height(session._live_sql_win, float_h)
  else
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
    vim.api.nvim_set_option_value("filetype", "sql", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = math.floor((vim.o.lines - float_h) / 2),
      col = math.floor((editor_cols - float_w) / 2),
      width = float_w,
      height = float_h,
      style = "minimal",
      border = "rounded",
      title = " Live SQL ",
      title_pos = "center",
      focusable = false,
    })
    session._live_sql_win = win
    session._live_sql_buf = buf
  end
end

function M._close_live_sql_float(session)
  if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
    vim.api.nvim_win_close(session._live_sql_win, true)
  end
  session._live_sql_win = nil
  session._live_sql_buf = nil
end

-- ── cursor → cell mapping ─────────────────────────────────────────────────
-- M.get_cell(bufnr) → {row_idx, col_name, col_idx, value} | nil
function M.get_cell(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session._render then return nil end

  local r = session._render
  local st = session.state
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_nr = cursor[1]  -- 1-based
  local col_nr  = cursor[2]  -- 0-based byte offset

  -- Data rows start at line 4 (title, header, sep) or 5 (with type row)
  local data_start = r.data_start or 4
  local data_end = data_start + #r.ordered - 1
  if line_nr < data_start or line_nr > data_end then return nil end

  local row_order_idx = line_nr - data_start + 1
  local row_idx = r.ordered[row_order_idx]
  if not row_idx then return nil end

  -- Use cached byte positions from build_render
  local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
  if bp_row then
    for i, col in ipairs(st.columns) do
      local bp = bp_row[col]
      if bp and col_nr >= bp.start and col_nr <= bp.finish then
        local value = data.effective_value(st, row_idx, col)
        return {
          row_idx = row_idx,
          col_name = col,
          col_idx = i,
          value = value,
        }
      end
    end
    -- Cursor is on a separator or border — snap to nearest column
    for i, col in ipairs(st.columns) do
      local bp = bp_row[col]
      if bp and col_nr < bp.start then
        local value = data.effective_value(st, row_idx, col)
        return {
          row_idx = row_idx,
          col_name = col,
          col_idx = i,
          value = value,
        }
      end
    end
  end

  return nil
end

-- ── open ──────────────────────────────────────────────────────────────────
-- Creates split, renders initial state, wires keymaps.
-- Returns bufnr.
function M.open(state, url, query_sql, opts)
  ensure_highlights()

  -- Create a new scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  local tbl = state.table_name or "query"
  local buf_name = "grip://" .. tbl
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)

  -- Register session before rendering
  M._sessions[bufnr] = {
    state = state,
    url = url,
    query_sql = query_sql,
    opts = opts or {},
  }

  -- Open in existing window (reuse_win) or a new horizontal split below
  local winid
  if opts and opts.reuse_win and vim.api.nvim_win_is_valid(opts.reuse_win) then
    winid = opts.reuse_win
    -- Save what was displayed so q can restore it
    local prev_buf = vim.api.nvim_win_get_buf(winid)
    M._sessions[bufnr].prev_buf = prev_buf
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)  -- focus grip window (Issue #3)
  else
    vim.cmd("botright split")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_height(winid, math.min(30, #state.rows + 8))
  end

  -- Render
  M.render(bufnr, state)

  -- Move cursor to first data cell, enable row tracking
  -- Byte offset 4 = after "║ " (║ is 3 bytes + 1 space)
  pcall(vim.api.nvim_win_set_cursor, winid, { 4, #("║ ") })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })
  vim.api.nvim_set_option_value("sidescrolloff", 5, { win = winid })

  -- Wire keymaps
  M._setup_keymaps(bufnr)

  -- Cleanup session on buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      local s = M._sessions[bufnr]
      if s then M._close_live_sql_float(s) end
      M._sessions[bufnr] = nil
    end,
  })

  return bufnr
end

-- ── focused info float helper ────────────────────────────────────────────
-- Opens a focused float with q/Esc to close. Caller stays in grip buffer.
local function open_info_float(grip_win, lines, float_opts)
  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end

  local width = float_opts.width or math.min(math.max(max_w + 2, 30), 80)
  local height = float_opts.height or math.min(#lines, 30)
  local relative = float_opts.relative or "editor"

  local row, col
  if relative == "cursor" then
    row = float_opts.row or 1
    col = float_opts.col or 0
  else
    row = math.floor((vim.o.lines - height) / 2)
    col = math.floor((vim.o.columns - width) / 2)
  end

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  if float_opts.filetype then
    vim.api.nvim_set_option_value("filetype", float_opts.filetype, { buf = popup_buf })
  end

  local win = vim.api.nvim_open_win(popup_buf, true, {
    relative = relative,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = float_opts.title or "",
    title_pos = "center",
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      if vim.api.nvim_win_is_valid(grip_win) then
        vim.api.nvim_set_current_win(grip_win)
      end
    end, { buffer = popup_buf })
  end

  return win, popup_buf
end

-- ── keymap wiring ─────────────────────────────────────────────────────────
function M._setup_keymaps(bufnr)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc, nowait = true })
  end

  -- q: close (restore previous buffer if opened via reuse_win)
  map("q", function()
    local session = M._sessions[bufnr]
    if session and data.has_changes(session.state) then
      local staged = data.count_staged(session.state)
      local choice = vim.fn.confirm(
        string.format("%d unapplied change(s). Close anyway?", staged),
        "&Close\n&Cancel", 2
      )
      if choice ~= 1 then return end
    end
    local prev = session and session.prev_buf
    if prev and vim.api.nvim_buf_is_valid(prev) then
      vim.api.nvim_win_set_buf(0, prev)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    else
      vim.cmd("bd")
    end
  end, "Close grip buffer")

  -- r: refresh
  map("r", function()
    local session = M._sessions[bufnr]
    if not session then return end
    -- Re-run query via init callback
    if session.on_refresh then session.on_refresh(bufnr) end
  end, "Refresh query")

  -- e: edit cell
  map("e", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("No cell under cursor", vim.log.levels.INFO)
      return
    end
    if session.on_edit then session.on_edit(bufnr, cell) end
  end, "Edit cell")

  -- d: toggle delete row
  map("d", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    if session.on_delete then session.on_delete(bufnr, cell.row_idx) end
  end, "Toggle delete row")

  -- o: insert new row
  map("o", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    local after = cell and cell.row_idx or #session.state.rows
    if session.on_insert then session.on_insert(bufnr, after) end
  end, "Insert row after cursor")

  -- a: apply all staged changes
  map("a", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    if not data.has_changes(session.state) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    local staged = data.count_staged(session.state)
    local choice = vim.fn.confirm(
      string.format("Apply %d staged change(s) to database?", staged),
      "&Apply\n&Cancel", 2
    )
    if choice ~= 1 then return end
    if session.on_apply then session.on_apply(bufnr) end
  end, "Apply staged changes")

  -- u: undo (pops from undo stack)
  map("u", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session._undo_stack or #session._undo_stack == 0 then
      vim.notify("Nothing to undo", vim.log.levels.INFO)
      return
    end
    local prev_state = table.remove(session._undo_stack)
    M.render(bufnr, prev_state)
    local remaining = #session._undo_stack
    if remaining > 0 then
      vim.notify("Undo (" .. remaining .. " more)", vim.log.levels.INFO)
    else
      vim.notify("Undo (back to original)", vim.log.levels.INFO)
    end
  end, "Undo last edit")

  -- U: undo all (resets to original state)
  map("U", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session._undo_stack or #session._undo_stack == 0 then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    local original = session._undo_stack[1]
    local count = #session._undo_stack
    session._undo_stack = {}
    M.render(bufnr, original)
    vim.notify("Undid all " .. count .. " change(s)", vim.log.levels.INFO)
  end, "Undo all changes")

  -- y: yank cell value
  map("y", function()
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to yank", vim.log.levels.INFO)
      return
    end
    local val = cell.value or ""
    vim.fn.setreg("+", val)
    vim.notify("Yanked: " .. val, vim.log.levels.INFO)
  end, "Yank cell value")

  -- Y: yank row as CSV
  map("Y", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to yank", vim.log.levels.INFO)
      return
    end
    local st = session.state
    local parts = {}
    for _, col in ipairs(st.columns) do
      local val = data.effective_value(st, cell.row_idx, col)
      table.insert(parts, val or "")
    end
    local csv = table.concat(parts, ",")
    vim.fn.setreg("+", csv)
    vim.notify("Yanked row as CSV", vim.log.levels.INFO)
  end, "Yank row as CSV")

  -- gY: yank table as CSV
  map("gY", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    local r = session._render
    if not r then return end
    local lines_out = { table.concat(st.columns, ",") }
    for _, row_idx in ipairs(r.ordered) do
      local parts = {}
      for _, col in ipairs(st.columns) do
        local val = data.effective_value(st, row_idx, col)
        table.insert(parts, val or "")
      end
      table.insert(lines_out, table.concat(parts, ","))
    end
    vim.fn.setreg("+", table.concat(lines_out, "\n"))
    vim.notify("Yanked " .. #r.ordered .. " rows as CSV", vim.log.levels.INFO)
  end, "Yank table as CSV")

  -- n: set cell to NULL
  map("n", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, nil)
    vim.notify(cell.col_name .. " set to NULL", vim.log.levels.INFO)
    M.apply_edit(bufnr, new_state)
  end, "Set cell to NULL")

  -- ── visual mode batch editing ──────────────────────────────────────────
  local function vmap(key, fn, desc)
    vim.keymap.set("x", key, fn, { buffer = bufnr, desc = desc, nowait = true })
  end

  -- Helper: collect row indices from visual selection
  local function get_visual_rows()
    local start_line = vim.fn.line("v")
    local end_line = vim.fn.line(".")
    if start_line > end_line then start_line, end_line = end_line, start_line end
    local session = M._sessions[bufnr]
    if not session or not session._render then return nil end
    local r = session._render
    local ds = r.data_start or 4
    local rows = {}
    for line = start_line, end_line do
      local row_order = line - ds + 1
      if row_order >= 1 and row_order <= #r.ordered then
        table.insert(rows, r.ordered[row_order])
      end
    end
    return rows
  end

  -- Visual e: batch edit (set all selected cells in column to same value)
  vmap("e", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    -- Exit visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local col_name = cell.col_name
    editor.open("Set " .. #row_indices .. " cells (" .. col_name .. ")", cell.value, function(new_val)
      if new_val == nil then return end
      local actual = new_val == editor.NULL_VALUE and nil or new_val
      local st = session.state
      for _, ri in ipairs(row_indices) do
        st = data.add_change(st, ri, col_name, actual)
      end
      M.apply_edit(bufnr, st)
      vim.notify("Set " .. #row_indices .. " cells in " .. col_name, vim.log.levels.INFO)
    end)
  end, "Batch edit selected cells")

  -- Visual d: toggle delete on all selected rows
  vmap("d", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local st = session.state
    for _, ri in ipairs(row_indices) do
      st = data.toggle_delete(st, ri)
    end
    M.apply_edit(bufnr, st)
    vim.notify("Toggled delete on " .. #row_indices .. " row(s)", vim.log.levels.INFO)
  end, "Batch toggle delete")

  -- Visual n: set all selected cells to NULL
  vmap("n", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local col_name = cell.col_name
    local st = session.state
    for _, ri in ipairs(row_indices) do
      st = data.add_change(st, ri, col_name, nil)
    end
    M.apply_edit(bufnr, st)
    vim.notify("Set " .. #row_indices .. " cells to NULL in " .. col_name, vim.log.levels.INFO)
  end, "Batch set NULL")

  -- gs: preview staged SQL in float
  map("gs", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    if not data.has_changes(st) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    if not st.table_name then
      vim.notify("SQL preview requires a table name", vim.log.levels.INFO)
      return
    end
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    local lines = {}
    for line in (preview .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, { title = " Staged SQL ", filetype = "sql" })
  end, "Preview staged SQL")

  -- gc: copy staged SQL to clipboard
  map("gc", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    if not data.has_changes(st) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    if not st.table_name then
      vim.notify("SQL preview requires a table name", vim.log.levels.INFO)
      return
    end
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    vim.fn.setreg("+", preview)
    vim.notify("Copied SQL to clipboard", vim.log.levels.INFO)
  end, "Copy staged SQL")

  -- gi: table info float
  map("gi", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    if not st.table_name then
      vim.notify("Table info requires a table name", vim.log.levels.INFO)
      return
    end
    -- Use cached column info if available
    if not session._column_info then
      local info, err = db.get_column_info(st.table_name, st.url)
      if err then
        vim.notify("Failed to get column info: " .. err, vim.log.levels.WARN)
        return
      end
      session._column_info = info
    end
    local info = session._column_info
    local lines = { " " .. st.table_name, " " .. string.rep("─", 40) }
    for _, col in ipairs(info) do
      local parts = { "  " .. col.column_name .. "  " .. col.data_type }
      if col.is_nullable == "NO" then table.insert(parts, "NOT NULL") end
      if col.column_default ~= "" then table.insert(parts, "DEFAULT " .. col.column_default) end
      if col.constraints ~= "" then table.insert(parts, "[" .. col.constraints .. "]") end
      table.insert(lines, table.concat(parts, "  "))
    end
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, { title = " Table Info " })
  end, "Table info")

  -- ge: explain cell
  map("ge", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    -- Fetch column info (cached)
    if not session._column_info and st.table_name then
      local info, err = db.get_column_info(st.table_name, st.url)
      if not err then session._column_info = info end
    end
    local col_info
    if session._column_info then
      for _, ci in ipairs(session._column_info) do
        if ci.column_name == cell.col_name then col_info = ci; break end
      end
    end
    local status = data.row_status(st, cell.row_idx)
    local is_staged = status == "modified" and st.changes[cell.row_idx] and st.changes[cell.row_idx][cell.col_name] ~= nil
    local lines = { " " .. cell.col_name }
    lines[#lines + 1] = " " .. string.rep("─", 30)
    if col_info then
      lines[#lines + 1] = "  Type: " .. col_info.data_type
      lines[#lines + 1] = "  Nullable: " .. col_info.is_nullable
      if col_info.column_default ~= "" then
        lines[#lines + 1] = "  Default: " .. col_info.column_default
      end
      if col_info.constraints ~= "" then
        lines[#lines + 1] = "  Constraints: " .. col_info.constraints
      end
    end
    lines[#lines + 1] = "  Value: " .. (cell.value or "NULL")
    lines[#lines + 1] = "  Status: " .. (is_staged and "staged" or "original")
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, {
      title = " Cell Info ",
      relative = "cursor",
      row = 1, col = 0,
    })
  end, "Explain cell")

  -- <CR>: expand cell popup
  map("<CR>", function()
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to expand", vim.log.levels.INFO)
      return
    end
    local val = cell.value or "(NULL)"
    local lines = {}
    for line in (val .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, {
      title = " " .. cell.col_name .. " ",
      relative = "cursor",
      row = 1, col = 0,
    })
  end, "Expand cell value")

  -- K: row view (vertical transpose)
  map("K", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    local st = session.state
    local max_name_w = 0
    for _, col in ipairs(st.columns) do
      max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col))
    end
    local lines = {}
    for _, col in ipairs(st.columns) do
      local val = data.effective_value(st, cell.row_idx, col)
      local display_val = val or "NULL"
      local pad = string.rep(" ", max_name_w - vim.fn.strdisplaywidth(col))
      table.insert(lines, " " .. col .. pad .. "   " .. display_val)
    end
    local grip_win = vim.api.nvim_get_current_win()
    local _, popup_buf = open_info_float(grip_win, lines, {
      title = " Row " .. cell.row_idx .. " ",
    })
    -- Highlight modified cells
    local status = data.row_status(st, cell.row_idx)
    if status == "modified" and st.changes[cell.row_idx] then
      local row_ns = vim.api.nvim_create_namespace("grip_row_view")
      for i, col in ipairs(st.columns) do
        if st.changes[cell.row_idx][col] ~= nil then
          vim.api.nvim_buf_set_extmark(popup_buf, row_ns, i - 1, 0, {
            end_col = #lines[i],
            hl_group = "GripModified",
          })
        end
      end
    elseif status == "inserted" then
      local row_ns = vim.api.nvim_create_namespace("grip_row_view")
      for i in ipairs(st.columns) do
        vim.api.nvim_buf_set_extmark(popup_buf, row_ns, i - 1, 0, {
          end_col = #lines[i],
          hl_group = "GripInserted",
        })
      end
    elseif status == "deleted" then
      local row_ns = vim.api.nvim_create_namespace("grip_row_view")
      for i in ipairs(st.columns) do
        vim.api.nvim_buf_set_extmark(popup_buf, row_ns, i - 1, 0, {
          end_col = #lines[i],
          hl_group = "GripDeleted",
        })
      end
    end
  end, "Row view")

  -- Tab: next column
  map("<Tab>", function()
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local session = M._sessions[bufnr]
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local next_idx = (cell.col_idx % #cols) + 1
    local target_col = cols[next_idx]
    local target_byte = bp_row[target_col].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Next column")

  -- S-Tab: previous column
  map("<S-Tab>", function()
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local session = M._sessions[bufnr]
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local prev_idx = cell.col_idx == 1 and #cols or cell.col_idx - 1
    local target_col = cols[prev_idx]
    local target_byte = bp_row[target_col].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Previous column")

  -- w: next column (alias for Tab)
  map("w", function()
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local session = M._sessions[bufnr]
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local next_idx = (cell.col_idx % #cols) + 1
    local target_col = cols[next_idx]
    local target_byte = bp_row[target_col].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Next column")

  -- b: previous column (alias for S-Tab)
  map("b", function()
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local session = M._sessions[bufnr]
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local prev_idx = cell.col_idx == 1 and #cols or cell.col_idx - 1
    local target_col = cols[prev_idx]
    local target_byte = bp_row[target_col].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Previous column")

  -- gg: first data row, same column
  map("gg", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local ds = r.data_start or 4
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { ds, cursor[2] })
  end, "First data row")

  -- G: last data row, same column
  map("G", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local ds = r.data_start or 4
    local last = ds + #r.ordered - 1
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { last, cursor[2] })
  end, "Last data row")

  -- ^: first column of current row (always)
  map("^", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local target_byte = bp_row[cols[1]].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "First column")

  -- 0: unpin all OR first column (dual behavior)
  map("0", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.pinned_count and session.pinned_count > 0 then
      session.pinned_count = 0
      vim.notify("Unpinned all columns", vim.log.levels.INFO)
      M.render(bufnr, session.state)
      return
    end
    -- Fallback: jump to first column
    if not session._render then return end
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local target_byte = bp_row[cols[1]].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Unpin all / first column")

  -- 1-9: pin N leftmost columns
  for n = 1, 9 do
    map(tostring(n), function()
      local session = M._sessions[bufnr]
      if not session then return end
      local cols = session.state.columns
      if n >= #cols then
        vim.notify("Only " .. #cols .. " columns", vim.log.levels.INFO)
        return
      end
      session.pinned_count = n
      vim.notify("Pinned " .. n .. " column(s)", vim.log.levels.INFO)
      M.render(bufnr, session.state)
    end, "Pin " .. n .. " column(s)")
  end

  -- $: last column of current row
  map("$", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cols = session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local target_byte = bp_row[cols[#cols]].start
    vim.api.nvim_win_set_cursor(0, { cursor[1], target_byte })
  end, "Last column")

  -- {: previous modified/staged row
  map("{", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local current_order = cursor[1] - ds + 1
    local st = session.state
    -- Scan backwards from current position, wrapping around
    for offset = 1, #r.ordered do
      local idx = current_order - offset
      if idx < 1 then idx = idx + #r.ordered end
      local row_idx = r.ordered[idx]
      if data.row_status(st, row_idx) ~= "clean" then
        vim.api.nvim_win_set_cursor(0, { ds + idx - 1, cursor[2] })
        return
      end
    end
    vim.notify("No modified rows", vim.log.levels.INFO)
  end, "Previous modified row")

  -- }: next modified/staged row
  map("}", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local current_order = cursor[1] - ds + 1
    local st = session.state
    -- Scan forward from current position, wrapping around
    for offset = 1, #r.ordered do
      local idx = ((current_order - 1 + offset) % #r.ordered) + 1
      local row_idx = r.ordered[idx]
      if data.row_status(st, row_idx) ~= "clean" then
        vim.api.nvim_win_set_cursor(0, { ds + idx - 1, cursor[2] })
        return
      end
    end
    vim.notify("No modified rows", vim.log.levels.INFO)
  end, "Next modified row")

  -- p: paste clipboard value into cell
  map("p", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    local clipboard = vim.fn.getreg("+")
    if clipboard == "" then
      vim.notify("Clipboard is empty", vim.log.levels.INFO)
      return
    end
    -- Trim trailing newline from clipboard
    clipboard = clipboard:gsub("\n$", "")
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, clipboard)
    vim.notify(cell.col_name .. " = " .. clipboard:sub(1, 30), vim.log.levels.INFO)
    M.apply_edit(bufnr, new_state)
  end, "Paste into cell")

  -- gl: toggle live SQL preview float
  map("gl", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session.state.table_name then
      vim.notify("Live SQL requires a table name", vim.log.levels.INFO)
      return
    end
    session.live_sql = not session.live_sql
    if session.live_sql then
      vim.notify("Live SQL: ON", vim.log.levels.INFO)
      M._update_live_sql_float(session)
    else
      vim.notify("Live SQL: OFF", vim.log.levels.INFO)
      M._close_live_sql_float(session)
    end
  end, "Toggle live SQL")

  -- T: toggle column types overlay
  map("T", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session.state.table_name then
      vim.notify("Column types requires a table name", vim.log.levels.INFO)
      return
    end
    -- Fetch column info if not cached
    if not session._column_info then
      local info, err = db.get_column_info(session.state.table_name, session.state.url)
      if err then
        vim.notify("Failed to get column info: " .. err, vim.log.levels.WARN)
        return
      end
      session._column_info = info
    end
    session.show_types = not session.show_types
    vim.notify("Column types: " .. (session.show_types and "ON" or "OFF"), vim.log.levels.INFO)
    M.render(bufnr, session.state)
  end, "Toggle column types")

  -- ── sort / filter / pagination keymaps ──────────────────────────────────

  -- Helper: warn if pending changes, return true if user wants to proceed
  local function confirm_discard_changes(action_name)
    local session_c = M._sessions[bufnr]
    if not session_c then return true end
    if not data.has_changes(session_c.state) then return true end
    local staged = data.count_staged(session_c.state)
    local choice = vim.fn.confirm(
      string.format("%s will discard %d unapplied change(s). Continue?", action_name, staged),
      "&Yes\n&Cancel", 2
    )
    return choice == 1
  end

  -- s: sort by column (replaces existing sort)
  map("s", function()
    local session_s = M._sessions[bufnr]
    if not session_s or not session_s.query_spec then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column to sort", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Sort") then return end
    local new_spec = qmod.toggle_sort(session_s.query_spec, cell.col_name)
    if session_s.on_requery then session_s.on_requery(bufnr, new_spec) end
  end, "Sort by column")

  -- S: add/toggle secondary sort (stacked)
  map("S", function()
    local session_s = M._sessions[bufnr]
    if not session_s or not session_s.query_spec then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column to sort", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Sort") then return end
    local new_spec = qmod.add_sort(session_s.query_spec, cell.col_name)
    if session_s.on_requery then session_s.on_requery(bufnr, new_spec) end
  end, "Add secondary sort")

  -- f: quick filter by cell value
  map("f", function()
    local session_f = M._sessions[bufnr]
    if not session_f or not session_f.query_spec then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a cell to filter", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Filter") then return end
    local new_spec = qmod.quick_filter(session_f.query_spec, cell.col_name, cell.value)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
    local display = cell.value and (cell.col_name .. " = " .. tostring(cell.value):sub(1, 30)) or (cell.col_name .. " IS NULL")
    vim.notify("Filtered: " .. display, vim.log.levels.INFO)
  end, "Quick filter by cell value")

  -- <C-f>: freeform WHERE clause filter
  map("<C-f>", function()
    local session_f = M._sessions[bufnr]
    if not session_f or not session_f.query_spec then return end
    if not confirm_discard_changes("Filter") then return end
    vim.ui.input({ prompt = "WHERE: " }, function(input)
      if not input or input == "" then return end
      local new_spec = qmod.add_filter(session_f.query_spec, input)
      if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
    end)
  end, "Filter rows (WHERE clause)")

  -- F: clear all filters
  map("F", function()
    local session_f = M._sessions[bufnr]
    if not session_f or not session_f.query_spec then return end
    if not qmod.has_filters(session_f.query_spec) then
      vim.notify("No active filters", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Clear filters") then return end
    local new_spec = qmod.clear_filters(session_f.query_spec)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
    vim.notify("Filters cleared", vim.log.levels.INFO)
  end, "Clear all filters")

  -- ]p: next page
  map("]p", function()
    local session_p = M._sessions[bufnr]
    if not session_p or not session_p.query_spec then return end
    -- Check if we're on the last page
    if session_p.total_rows then
      local total_pages = math.max(1, math.ceil(session_p.total_rows / session_p.query_spec.page_size))
      if session_p.query_spec.page >= total_pages then
        vim.notify("Already on last page", vim.log.levels.INFO)
        return
      end
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.next_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Next page")

  -- [p: previous page
  map("[p", function()
    local session_p = M._sessions[bufnr]
    if not session_p or not session_p.query_spec then return end
    if session_p.query_spec.page <= 1 then
      vim.notify("Already on first page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.prev_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Previous page")

  -- ]P: jump to last page
  map("]P", function()
    local session_p = M._sessions[bufnr]
    if not session_p or not session_p.query_spec then return end
    if not session_p.total_rows then
      vim.notify("Total rows unknown", vim.log.levels.INFO)
      return
    end
    local total_pages = math.max(1, math.ceil(session_p.total_rows / session_p.query_spec.page_size))
    if session_p.query_spec.page >= total_pages then
      vim.notify("Already on last page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.set_page(session_p.query_spec, total_pages)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Last page")

  -- [P: jump to first page
  map("[P", function()
    local session_p = M._sessions[bufnr]
    if not session_p or not session_p.query_spec then return end
    if session_p.query_spec.page <= 1 then
      vim.notify("Already on first page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.set_page(session_p.query_spec, 1)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "First page")

  -- X: reset all query modifiers (sorts, filters, page)
  map("X", function()
    local session_x = M._sessions[bufnr]
    if not session_x or not session_x.query_spec then return end
    local spec = session_x.query_spec
    if #spec.sorts == 0 and #spec.filters == 0 and spec.page == 1 then
      vim.notify("View already at defaults", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Reset view") then return end
    local new_spec = qmod.reset(session_x.query_spec)
    if session_x.on_requery then session_x.on_requery(bufnr, new_spec) end
    vim.notify("View reset", vim.log.levels.INFO)
  end, "Reset view (clear sort/filter/page)")

  -- ── FK navigation keymaps ─────────────────────────────────────────────

  -- gf: navigate to FK referenced row
  map("gf", function()
    local session_fk = M._sessions[bufnr]
    if not session_fk or not session_fk.state.table_name then
      vim.notify("FK navigation requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a cell", vim.log.levels.INFO)
      return
    end
    if cell.value == nil then
      vim.notify("NULL value — cannot follow FK", vim.log.levels.INFO)
      return
    end

    -- Fetch FK metadata (cached per table)
    if not session_fk.fk_cache then session_fk.fk_cache = {} end
    local tbl = session_fk.state.table_name
    if not session_fk.fk_cache[tbl] then
      local fks, fk_err = db.get_foreign_keys(tbl, session_fk.state.url)
      if fk_err then
        vim.notify("FK lookup failed: " .. fk_err, vim.log.levels.WARN)
        return
      end
      session_fk.fk_cache[tbl] = fks or {}
    end

    -- Find FK for this column
    local fk_info
    for _, fk in ipairs(session_fk.fk_cache[tbl]) do
      if fk.column == cell.col_name then
        fk_info = fk
        break
      end
    end
    if not fk_info then
      vim.notify(cell.col_name .. " is not a foreign key", vim.log.levels.INFO)
      return
    end

    -- Push current state to nav stack
    if not session_fk.nav_stack then session_fk.nav_stack = {} end
    table.insert(session_fk.nav_stack, {
      query_spec = session_fk.query_spec,
      state = session_fk.state,
      table_name = tbl,
      cursor_pos = vim.api.nvim_win_get_cursor(0),
      total_rows = session_fk.total_rows,
    })

    -- Build query for referenced row
    local ref_spec = qmod.new_table(fk_info.ref_table, session_fk.query_spec.page_size)
    ref_spec = qmod.add_filter(ref_spec, sql.quote_ident(fk_info.ref_column) .. " = " .. sql.quote_value(cell.value))
    local ref_sql = qmod.build_sql(ref_spec)

    local result, err = db.query(ref_sql, session_fk.state.url)
    if err then
      table.remove(session_fk.nav_stack) -- pop on failure
      vim.notify("FK query failed: " .. err, vim.log.levels.WARN)
      return
    end

    -- Fetch PKs for referenced table
    local pks = db.get_primary_keys(fk_info.ref_table, session_fk.state.url) or {}
    result.primary_keys = pks
    result.table_name = fk_info.ref_table
    result.url = session_fk.state.url
    result.sql = ref_sql

    local new_state = data.new(result)
    session_fk.query_spec = ref_spec
    session_fk.total_rows = #result.rows
    M.render(bufnr, new_state)
    vim.notify(tbl .. "." .. cell.col_name .. " → " .. fk_info.ref_table, vim.log.levels.INFO)
  end, "Follow FK to referenced row")

  -- <C-o>: go back in FK navigation stack
  map("<C-o>", function()
    local session_nav = M._sessions[bufnr]
    if not session_nav then return end
    if not session_nav.nav_stack or #session_nav.nav_stack == 0 then
      vim.notify("No FK navigation history", vim.log.levels.INFO)
      return
    end
    local frame = table.remove(session_nav.nav_stack)
    session_nav.query_spec = frame.query_spec
    session_nav.total_rows = frame.total_rows
    M.render(bufnr, frame.state)
    -- Restore cursor
    if frame.cursor_pos then
      pcall(vim.api.nvim_win_set_cursor, 0, frame.cursor_pos)
    end
    vim.notify("Back to " .. (frame.table_name or "previous"), vim.log.levels.INFO)
  end, "Go back (FK navigation)")

  -- ── aggregate / column stats / export keymaps ─────────────────────────

  -- ga: aggregate selected cells (works after visual selection)
  map("ga", function()
    local session_a = M._sessions[bufnr]
    if not session_a or not session_a._render then return end
    local r = session_a._render
    local st_a = session_a.state

    -- Get visual selection range (uses '< and '> marks)
    local start_line = vim.fn.line("'<")
    local end_line = vim.fn.line("'>")
    local ds = r.data_start or 4
    if start_line == 0 or end_line == 0 then
      -- No visual selection — use current cell
      local cell = M.get_cell(bufnr)
      if not cell then
        vim.notify("Select cells first (visual mode) or position on a cell", vim.log.levels.INFO)
        return
      end
      start_line = vim.api.nvim_win_get_cursor(0)[1]
      end_line = start_line
    end

    -- Collect values from selected rows
    local values = {}
    local numeric_values = {}
    for line = start_line, end_line do
      local row_order = line - ds + 1
      if row_order >= 1 and row_order <= #r.ordered then
        local row_idx = r.ordered[row_order]
        for _, col in ipairs(st_a.columns) do
          local val = data.effective_value(st_a, row_idx, col)
          if val ~= nil then
            table.insert(values, val)
            local num = tonumber(val)
            if num then table.insert(numeric_values, num) end
          end
        end
      end
    end

    if #values == 0 then
      vim.notify("No values in selection", vim.log.levels.INFO)
      return
    end

    local agg_parts = { "Count: " .. #values }
    if #numeric_values > 0 then
      local sum = 0
      local min_v, max_v = numeric_values[1], numeric_values[1]
      for _, n in ipairs(numeric_values) do
        sum = sum + n
        if n < min_v then min_v = n end
        if n > max_v then max_v = n end
      end
      local avg = sum / #numeric_values
      table.insert(agg_parts, string.format("Sum: %g", sum))
      table.insert(agg_parts, string.format("Avg: %.2f", avg))
      table.insert(agg_parts, string.format("Min: %g", min_v))
      table.insert(agg_parts, string.format("Max: %g", max_v))
    end

    vim.notify(table.concat(agg_parts, "  │  "), vim.log.levels.INFO)
  end, "Aggregate selected cells")

  -- gS: column statistics
  map("gS", function()
    local session_cs = M._sessions[bufnr]
    if not session_cs or not session_cs.state.table_name then
      vim.notify("Column stats requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column", vim.log.levels.INFO)
      return
    end
    local tbl = session_cs.state.table_name
    local col_q = sql.quote_ident(cell.col_name)
    local stats_sql = string.format(
      "SELECT COUNT(*) AS total, COUNT(DISTINCT %s) AS distinct_count, " ..
      "COUNT(*) - COUNT(%s) AS null_count, MIN(%s) AS min_val, MAX(%s) AS max_val " ..
      "FROM %s",
      col_q, col_q, col_q, col_q, sql.quote_ident(tbl)
    )
    local result, err = db.query(stats_sql, session_cs.state.url)
    if err then
      vim.notify("Stats query failed: " .. err, vim.log.levels.WARN)
      return
    end
    if not result or #result.rows == 0 then
      vim.notify("No stats returned", vim.log.levels.INFO)
      return
    end
    local row = result.rows[1]
    local info = {
      " " .. cell.col_name .. " — Column Statistics",
      " " .. string.rep("─", 40),
      "  Total:    " .. (row[1] or "?"),
      "  Distinct: " .. (row[2] or "?"),
      "  Nulls:    " .. (row[3] or "?"),
      "  Min:      " .. (row[4] or "NULL"),
      "  Max:      " .. (row[5] or "NULL"),
    }

    -- Try to get top 5 values
    local top_sql = string.format(
      "SELECT %s, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL " ..
      "GROUP BY %s ORDER BY cnt DESC LIMIT 5",
      col_q, sql.quote_ident(tbl), col_q, col_q
    )
    local top_result = db.query(top_sql, session_cs.state.url)
    if top_result and #top_result.rows > 0 then
      table.insert(info, "")
      table.insert(info, "  Top values:")
      for _, r_top in ipairs(top_result.rows) do
        local val = r_top[1] or "?"
        local cnt = r_top[2] or "?"
        table.insert(info, "    " .. tostring(val):sub(1, 30) .. "  (" .. cnt .. ")")
      end
    end

    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, info, { title = " Column Stats " })
  end, "Column statistics")

  -- gE: export in multiple formats
  map("gE", function()
    local session_e = M._sessions[bufnr]
    if not session_e or not session_e._render then return end
    local st_e = session_e.state
    local r_e = session_e._render

    local formats = { "CSV", "TSV", "JSON", "SQL INSERT", "Markdown" }
    vim.ui.select(formats, { prompt = "Export format:" }, function(choice)
      if not choice then return end

      local cols = st_e.columns
      local rows_data = {}
      for _, row_idx in ipairs(r_e.ordered) do
        local row = {}
        for _, col in ipairs(cols) do
          table.insert(row, data.effective_value(st_e, row_idx, col))
        end
        table.insert(rows_data, row)
      end

      local output
      if choice == "CSV" then
        local lines_out = { table.concat(cols, ",") }
        for _, row in ipairs(rows_data) do
          local parts = {}
          for _, v in ipairs(row) do
            local s = v or ""
            if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
            table.insert(parts, s)
          end
          table.insert(lines_out, table.concat(parts, ","))
        end
        output = table.concat(lines_out, "\n")
      elseif choice == "TSV" then
        local lines_out = { table.concat(cols, "\t") }
        for _, row in ipairs(rows_data) do
          local parts = {}
          for _, v in ipairs(row) do table.insert(parts, v or "") end
          table.insert(lines_out, table.concat(parts, "\t"))
        end
        output = table.concat(lines_out, "\n")
      elseif choice == "JSON" then
        local objects = {}
        for _, row in ipairs(rows_data) do
          local obj_parts = {}
          for ci, col in ipairs(cols) do
            local v = row[ci]
            local json_val
            if v == nil then json_val = "null"
            elseif tonumber(v) then json_val = v
            elseif v == "true" or v == "false" then json_val = v
            else json_val = '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
            end
            table.insert(obj_parts, '    "' .. col .. '": ' .. json_val)
          end
          table.insert(objects, "  {\n" .. table.concat(obj_parts, ",\n") .. "\n  }")
        end
        output = "[\n" .. table.concat(objects, ",\n") .. "\n]"
      elseif choice == "SQL INSERT" then
        local stmts = {}
        local tbl = st_e.table_name or "table_name"
        for _, row in ipairs(rows_data) do
          local vals = {}
          for _, v in ipairs(row) do table.insert(vals, sql.quote_value(v)) end
          table.insert(stmts, string.format("INSERT INTO %s (%s) VALUES (%s);",
            sql.quote_ident(tbl),
            table.concat(vim.tbl_map(function(c) return sql.quote_ident(c) end, cols), ", "),
            table.concat(vals, ", ")))
        end
        output = table.concat(stmts, "\n")
      elseif choice == "Markdown" then
        local hdr = "| " .. table.concat(vim.tbl_map(function(c) return c:gsub("|", "\\|") end, cols), " | ") .. " |"
        local sep = "| " .. table.concat(vim.tbl_map(function() return "---" end, cols), " | ") .. " |"
        local lines_out = { hdr, sep }
        for _, row in ipairs(rows_data) do
          local parts = {}
          for _, v in ipairs(row) do
            table.insert(parts, (v or ""):gsub("|", "\\|"))
          end
          table.insert(lines_out, "| " .. table.concat(parts, " | ") .. " |")
        end
        output = table.concat(lines_out, "\n")
      end

      if output then
        vim.fn.setreg("+", output)
        vim.notify("Exported " .. #rows_data .. " rows as " .. choice .. " to clipboard", vim.log.levels.INFO)
      end
    end)
  end, "Export in multiple formats")

  -- gx: explain current query (shortcut for :GripExplain)
  map("gx", function()
    local session_x = M._sessions[bufnr]
    if not session_x then return end
    local explain_sql
    if session_x.query_spec then
      explain_sql = qmod.build_sql(session_x.query_spec)
    elseif session_x.query_sql then
      explain_sql = session_x.query_sql
    end
    if not explain_sql or explain_sql == "" then
      vim.notify("No query to explain", vim.log.levels.INFO)
      return
    end
    vim.cmd("GripExplain " .. explain_sql)
  end, "Explain current query")

  -- go: toggle schema sidebar
  map("go", function()
    local schema = require("dadbod-grip.schema")
    schema.toggle(url)
  end, "Toggle schema browser")

  -- gT: table picker
  map("gT", function()
    local picker = require("dadbod-grip.picker")
    picker.pick_table(url, function(name)
      local grip = require("dadbod-grip")
      grip.open(name, url)
    end)
  end, "Pick table")

  -- gQ: open query pad with current query pre-filled
  map("gQ", function()
    local query_pad = require("dadbod-grip.query_pad")
    local session_q = M._sessions[bufnr]
    local initial_sql
    if session_q and session_q.query_spec then
      initial_sql = qmod.build_sql(session_q.query_spec)
    elseif session_q and session_q.query_sql then
      initial_sql = session_q.query_sql
    end
    query_pad.open(url, initial_sql and { initial_sql = initial_sql } or nil)
  end, "Open query pad")

  -- ?: help popup
  map("?", function()
    local grip_win = vim.api.nvim_get_current_win()  -- save for restore on close
    local session = M._sessions[bufnr]
    local ro = session and session.state.readonly
    local help = {
      "",
      "          ██████╗ ██████╗ ██╗██████╗ ",
      "         ██╔════╝ ██╔══██╗██║██╔══██╗",
      "         ██║  ███╗██████╔╝██║██████╔╝",
      "         ██║   ██║██╔══██╗██║██╔═══╝ ",
      "         ╚██████╔╝██║  ██║██║██║     ",
      "          ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝    ",
      "",
      " ───────────────────────────────────────────",
      "",
      "  Navigation",
      "  j/k       Move between rows",
      "  h/l       Move cursor within row",
      "  w/b       Next / previous column",
      "  Tab/S-Tab Next / previous column",
      "  gg        First data row",
      "  G         Last data row",
      "  ^         First column",
      "  1-9       Pin N leftmost columns (freeze)",
      "  0         Unpin all / first column",
      "  $         Last column",
      "  {/}       Prev / next modified row",
      "  <CR>      Expand cell value in popup",
      "  K         Row view (vertical transpose)",
      "  y         Yank cell value to clipboard",
      "  Y         Yank row as CSV",
      "  gY        Yank entire table as CSV",
      "",
      "  Sort / Filter / Pagination",
      "  s         Toggle sort on column (ASC→DESC→off)",
      "  S         Stack secondary sort on column",
      "  f         Quick filter by cell value",
      "  <C-f>     Freeform WHERE clause filter",
      "  F         Clear all filters",
      "  X         Reset view (clear sort/filter/page)",
      "  ]p / [p   Next / previous page",
      "  ]P / [P   Last / first page",
      "",
      "  FK Navigation",
      "  gf        Follow foreign key under cursor",
      "  <C-o>     Go back in FK navigation stack",
      "",
      "  Analysis & Export",
      "  ga        Aggregate selected cells (visual mode)",
      "  gS        Column statistics popup",
      "  gx        Explain current query plan",
      "  gE        Export table (CSV, JSON, SQL, Markdown)",
      "",
      "  Schema & Workflow",
      "  go        Toggle schema browser",
      "  gT        Pick table (fuzzy finder)",
      "  gQ        Open query pad",
      "",
      "  Actions",
      "  r         Refresh (re-run query)",
      "  q         Close grip buffer",
      "  ?         Toggle this help",
    }
    if ro then
      vim.list_extend(help, {
        "",
        " ┌─ Read-Only Mode ────────────────────────┐",
        " │ This table has no primary key detected.  │",
        " │ Grip needs a PK to build WHERE clauses   │",
        " │ for UPDATE and DELETE statements.         │",
        " │ Without a PK, edits cannot target a      │",
        " │ specific row safely.                      │",
        " └──────────────────────────────────────────┘",
        "",
        " ───────────────────────────────────────────",
        "  dadbod-grip.nvim by Jory Pestorious",
      })
    else
      vim.list_extend(help, {
        "",
        "  Editing",
        "  e         Edit cell under cursor",
        "  n         Set cell to NULL",
        "  p         Paste clipboard into cell",
        "  o         Insert new row after cursor",
        "  d         Toggle delete on current row",
        "  u         Undo last edit (multi-level)",
        "  U         Undo all (reset to original)",
        "  a         Apply all staged changes to DB",
        "",
        "  Batch Edit (visual mode)",
        "  e         Set selected cells to same value",
        "  d         Toggle delete on selected rows",
        "  n         Set selected cells to NULL",
        "",
        "  Inspection",
        "  gs        Preview staged SQL",
        "  gc        Copy staged SQL to clipboard",
        "  gi        Table info (columns, types, PKs)",
        "  ge        Explain cell under cursor",
        "",
        "  Advanced",
        "  gl        Toggle live SQL preview",
        "  T         Toggle column type annotations",
        "",
        "  Colors: modified=blue  deleted=red  inserted=green",
        "          negative=red  true=green  false=red",
        "          past-date=dim  url=underline",
        "",
        " ───────────────────────────────────────────",
        "  dadbod-grip.nvim by Jory Pestorious",
      })
    end
    local max_w = 0
    for _, line in ipairs(help) do max_w = math.max(max_w, #line) end
    max_w = math.max(max_w + 2, 46)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, help)
    local win = vim.api.nvim_open_win(popup_buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - #help) / 2),
      col = math.floor((vim.o.columns - max_w) / 2),
      width = max_w,
      height = #help,
      style = "minimal",
      border = "rounded",
      title = " Help ",
      title_pos = "center",
    })
    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end
  end, "Show help")
end

-- Register callbacks for edit/delete/insert/apply/refresh from init.
function M.set_callbacks(bufnr, callbacks)
  local session = M._sessions[bufnr]
  if not session then return end
  for k, v in pairs(callbacks) do
    session[k] = v
  end
end

return M
