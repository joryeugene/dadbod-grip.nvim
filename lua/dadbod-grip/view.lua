-- view.lua — buffer rendering + keymaps.
-- One buffer per grip session. State in M._sessions[bufnr].

local data    = require("dadbod-grip.data")
local sql     = require("dadbod-grip.sql")
local db      = require("dadbod-grip.db")
local qmod    = require("dadbod-grip.query")
local editor  = require("dadbod-grip.editor")
local VERSION = require("dadbod-grip.version")

local M = {}
M._sessions = {}  -- [bufnr] = { state, url, query_sql }

-- ── profiling (set GRIP_PROFILE=1 to enable) ───────────────────────────────
local PROFILE = os.getenv("GRIP_PROFILE")
local function profile(name, fn)
  if not PROFILE then return fn() end
  local start = vim.uv.hrtime()
  local result = fn()
  local elapsed = (vim.uv.hrtime() - start) / 1e6
  print(string.format("[grip] %s: %.1fms", name, elapsed))
  return result
end

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

-- ── highlight group setup ──────────────────────────────────────────────────
local function ensure_highlights()
  -- All grip-owned groups use hi! (unconditional) so colors apply reliably
  -- on re-source, colorscheme changes, and first load.
  -- Staged groups have guibg; conditional groups are fg-only.
  vim.cmd("hi! GripHeader    gui=bold cterm=bold")
  vim.cmd("hi! GripNull      gui=italic ctermfg=243 guifg=#6c7086")
  vim.cmd("hi! GripModified  gui=bold ctermfg=111 guifg=#89b4fa ctermbg=236 guibg=#1a1e2e")
  vim.cmd("hi! GripDeleted   gui=strikethrough ctermfg=203 guifg=#f38ba8 ctermbg=236 guibg=#2d1418")
  vim.cmd("hi! GripInserted  gui=bold ctermfg=113 guifg=#a6e3a1 ctermbg=236 guibg=#162d18")
  -- Staged NULL: pink fg on same dark-blue bg as GripModified — signals "value cleared" (distinct from red=deleted)
  vim.cmd("hi! GripNullStaged gui=bold ctermfg=219 guifg=#f5c2e7 ctermbg=236 guibg=#1a1e2e")
  vim.cmd("hi! GripReadonly  gui=italic ctermfg=243 guifg=#6c7086")
  vim.cmd("hi! GripBorder    gui=bold ctermfg=147 guifg=#cba6f7")
  vim.cmd("hi! GripStatusOk  gui=bold ctermfg=229 guifg=#f9e2af")
  vim.cmd("hi! GripStatusChg gui=bold ctermfg=229 guifg=#f9e2af")
  vim.cmd("hi! GripNegative  gui=bold ctermfg=203 guifg=#f38ba8")
  vim.cmd("hi! GripBoolTrue  gui=bold ctermfg=113 guifg=#a6e3a1")
  vim.cmd("hi! GripBoolFalse gui=bold ctermfg=203 guifg=#f38ba8")
  vim.cmd("hi! GripDatePast  gui=italic ctermfg=243 guifg=#6c7086")
  vim.cmd("hi! GripUrl       gui=underline ctermfg=117 guifg=#89b4fa")
end

-- ── column width calculation ──────────────────────────────────────────────
local function calc_col_widths(columns, rows, max_width)
  local widths = {}
  for _, col in ipairs(columns) do
    widths[col] = math.min(vim.fn.strdisplaywidth(col), max_width)
  end
  -- For large tables, sample first 100 + last 10 rows instead of scanning all
  local n = #rows
  local sample_end = n > 200 and 100 or n
  local function scan_row(row_data)
    for i, col in ipairs(columns) do
      local v = row_data[i] or ""
      local display = (v == nil or v == "") and NULL_DISPLAY or tostring(v)
      widths[col] = math.min(math.max(widths[col], vim.fn.strdisplaywidth(display)), max_width)
    end
  end
  for ri = 1, sample_end do scan_row(rows[ri]) end
  if n > 200 then
    for ri = math.max(sample_end + 1, n - 9), n do scan_row(rows[ri]) end
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
local function border_line(columns, widths, left, mid, sep, right, min_inner)
  local parts = { left }
  if #columns == 0 and min_inner and min_inner > 0 then
    table.insert(parts, string.rep(sep, min_inner))
  else
    for i, col in ipairs(columns) do
      table.insert(parts, string.rep(sep, widths[col] + 2))
      if i < #columns then
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
  local hidden_count = 0
  if session.hidden_columns then
    for _ in pairs(session.hidden_columns) do hidden_count = hidden_count + 1 end
  end
  if hidden_count > 0 then table.insert(badges, hidden_count .. " hidden") end
  local right_info = #badges > 0 and (" [" .. table.concat(badges, " | ") .. "] ") or " "

  -- Build title with connection name and breadcrumb for FK navigation
  local conn_label
  local conn_mod = require("dadbod-grip.connections")
  local conn_info = conn_mod.current()
  if conn_info and conn_info.name then
    conn_label = conn_info.name
  elseif session.url then
    conn_label = session.url:match("([^/]+)$") or session.url
  end
  local base_name = session._mutation_title
    or session.state.table_name
    or "(query result)"
  if session.nav_stack and #session.nav_stack > 0 then
    local crumbs = {}
    for _, frame in ipairs(session.nav_stack) do
      table.insert(crumbs, frame.table_name or "?")
    end
    table.insert(crumbs, base_name)
    base_name = table.concat(crumbs, " > ")
  end

  -- Progressive fit: try full title, then drop connection, then truncate
  local inner = total_width - 4  -- ╔═(2) + ═╗(2) = 4 border display cols
  local right_trimmed = right_info:gsub(" $", "")
  local right_dw = vim.fn.strdisplaywidth(right_trimmed)
  local available = inner - right_dw

  -- If badges alone overflow, drop them
  if available < 6 then
    right_trimmed = ""
    right_dw = 0
    available = inner
  end

  -- Try: table @ connection
  local title_text = base_name
  if conn_label and conn_label ~= "" then
    title_text = base_name .. " @ " .. conn_label
  end
  local title = " " .. title_text .. " "
  local title_dw = vim.fn.strdisplaywidth(title)

  -- If too wide, drop connection name
  if title_dw > available and conn_label then
    title = " " .. base_name .. " "
    title_dw = vim.fn.strdisplaywidth(title)
  end

  -- If still too wide, truncate
  if title_dw > available and available > 4 then
    title = vim.fn.strcharpart(title, 0, available - 1) .. "…"
    title_dw = vim.fn.strdisplaywidth(title)
  end

  -- If still too wide (e.g. available <= 4 — very narrow grid), show gH hint if it fits
  if title_dw > available then
    if inner >= 4 then
      title = " gH "
      title_dw = 4
    else
      title = ""
      title_dw = 0
    end
    right_trimmed = ""
    right_dw = 0
  end

  local filler = math.max(0, inner - title_dw - right_dw)
  return "╔═" .. title .. string.rep("═", filler) .. right_trimmed .. "═╗"
end

-- ── main render ──────────────────────────────────────────────────────────
-- Returns {lines=[], extmarks=[{row, col, end_col, hl_group}]}
local function build_render(session, opts)
  local configured_max = (opts and opts.max_col_width) or MAX_COL_WIDTH
  local st = session.state
  local hidden = session.hidden_columns or {}
  local columns = {}
  for _, col in ipairs(st.columns) do
    if not hidden[col] then table.insert(columns, col) end
  end
  if #columns == 0 then columns = st.columns end  -- never hide all
  local ordered = data.get_ordered_rows(st)

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
  -- For tables with 0 columns, use a minimum width for the "(empty result)" message
  if #columns == 0 then total_inner = math.max(total_inner, 20) end
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
  local hdr_parts = { "║" }
  local qspec = session.query_spec
  -- Computed during assembly using #padded (byte length), not widths[col] (display width).
  -- Sort arrows (▲/▼ = 3 bytes, 1 display char) and ellipsis (… = 3 bytes) diverge from display
  -- widths; using display widths causes cursor positions to drift by 2 bytes per UTF-8 char.
  local hdr_byte_positions = {}
  if #columns == 0 then
    table.insert(hdr_parts, string.rep(" ", total_inner))
  else
    table.insert(hdr_parts, " ")
    local hbp = 4  -- "║ " = 3 + 1 bytes
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
      hdr_byte_positions[col] = { start = hbp, finish = hbp + #padded - 1 }
      hbp = hbp + #padded
      table.insert(hdr_parts, padded)
      if i < #columns then
        local col_sep = " " .. SEP_COL .. " "
        table.insert(hdr_parts, col_sep)
        hbp = hbp + #col_sep
      end
    end
    table.insert(hdr_parts, " ")
  end
  table.insert(hdr_parts, "║")
  local hdr_line = table.concat(hdr_parts)
  table.insert(lines, hdr_line)
  push_mark(#lines, 0, #hdr_line, "GripHeader")

  -- ── Type annotation row (T toggle) ──
  local has_type_row = false
  local type_row_byte_positions = nil
  if session.show_types and session._column_info then
    local type_map = {}
    for _, ci in ipairs(session._column_info) do
      type_map[ci.column_name] = ci.data_type
    end
    local type_parts = { "║ " }
    -- Track byte positions separately: "║ " = 4 bytes (3+1), then each cell's ACTUAL byte width.
    -- Type names truncated with "…" (3 bytes, 1 display char) diverge from hdr_byte_positions.
    type_row_byte_positions = {}
    local tbp = 4  -- after "║ "
    for i, col in ipairs(columns) do
      local dtype = type_map[col] or ""
      local w = widths[col]
      local dw = vim.fn.strdisplaywidth(dtype)
      if dw > w then
        dtype = vim.fn.strcharpart(dtype, 0, w - 1) .. "…"
        dw = w
      end
      local padded = dtype .. string.rep(" ", w - dw)
      type_row_byte_positions[col] = { start = tbp, finish = tbp + #padded - 1 }
      tbp = tbp + #padded
      table.insert(type_parts, padded)
      if i < #columns then
        local col_sep = " " .. SEP_COL .. " "
        table.insert(type_parts, col_sep)
        tbp = tbp + #col_sep
      end
    end
    table.insert(type_parts, " ║")
    local type_line = table.concat(type_parts)
    table.insert(lines, type_line)
    push_mark(#lines, 0, #type_line, "GripNull")
    has_type_row = true
  end

  -- ── Separator after header ──
  local sep_line = border_line(columns, widths, MID_L, SEP_MID, SEP_HDR, MID_R, total_inner)
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
    local msg_s = total_inner >= 16 and " (empty result) " or total_inner >= 9 and " (empty) " or ""
    if #msg_s > total_inner then msg_s = "" end
    local pad_total = total_inner - #msg_s
    local pad_left = math.floor(pad_total / 2)
    local pad_right = pad_total - pad_left
    local empty_line = "║" .. string.rep(" ", pad_left) .. msg_s .. string.rep(" ", pad_right) .. "║"
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
          local sep = COL_SEP
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
            -- NULL_SENTINEL = staged to be cleared → red fg (value absent) on blue bg (modified)
            if st.changes[row_idx][col] == data.NULL_SENTINEL then
              cell_hl = "GripNullStaged"
            else
              cell_hl = "GripModified"
            end
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
  local bot_line = border_line(columns, widths, BOT_L, BOT_MID, SEP_HDR, BOT_R, total_inner)
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

  local timing_str
  if session.elapsed_ms then
    local action = session.last_action or "query"
    timing_str = session.elapsed_ms .. "ms " .. action
    table.insert(status_parts, timing_str)
  end
  if staged_count > 0 then table.insert(status_parts, staged_count .. " staged") end
  if st.readonly then table.insert(status_parts, "read-only") end
  local hidden_n = 0
  if session.hidden_columns then
    for _ in pairs(session.hidden_columns) do hidden_n = hidden_n + 1 end
  end
  if hidden_n > 0 then table.insert(status_parts, hidden_n .. " hidden") end

  -- Filter summary
  if session.query_spec then
    local fs = qmod.filter_summary(session.query_spec)
    if fs ~= "" then table.insert(status_parts, fs) end
  end

  local status_str = " " .. table.concat(status_parts, "  │  ")
  table.insert(lines, status_str)
  -- Highlight timing badge — query=yellow, applied=green
  if timing_str then
    local ts, te = status_str:find(timing_str, 1, true)
    if ts then
      local action = session.last_action or "query"
      local timing_hl = (action == "query") and "GripStatusOk" or "GripBoolTrue"
      push_mark(#lines, ts - 1, te, timing_hl)
    end
  end
  -- Highlight "N staged" segment in GripStatusChg color
  if staged_count > 0 then
    local staged_text = staged_count .. " staged"
    local s, e = status_str:find(staged_text, 1, true)
    if s then push_mark(#lines, s - 1, e, "GripStatusChg") end
  end

  -- ── Hint line ──
  local hints
  if session.pending_mutation then
    local mt = session.pending_mutation.type or "SQL"
    hints = " a:execute " .. mt .. "  U:cancel  gs:preview SQL  q:query"
  elseif st.readonly then
    hints = " r:refresh  Tab/w:col  gy:markdown  gq:saved  q:query  A:ai  gC:connect  ?:help"
  else
    hints = " i:edit  c:clone  d:delete  a:apply  r:refresh  gq:saved  q:query  A:ai  ?:help"
  end
  table.insert(lines, hints)

  local data_start = has_type_row and 5 or 4
  return { lines = lines, marks = marks, widths = widths, ordered = ordered, byte_positions = row_byte_positions, hdr_byte_positions = hdr_byte_positions, type_row_byte_positions = type_row_byte_positions, data_start = data_start, visible_columns = columns }
end

-- ── namespace for extmarks ───────────────────────────────────────────────
local ns = vim.api.nvim_create_namespace("dadbod_grip")

-- M.update_table_sessions(old_name, new_name) — patch all open grip sessions
-- that reference old_name after a table rename, then refresh them.
function M.update_table_sessions(old_name, new_name)
  local sql_mod = require("dadbod-grip.sql")
  local old_quoted = sql_mod.quote_ident(old_name)
  local new_quoted = sql_mod.quote_ident(new_name)
  for bufnr, session in pairs(M._sessions) do
    if session.state and session.state.table_name == old_name then
      -- Update the query SQL string in-place (replace first occurrence, escaped)
      if session.query_sql then
        session.query_sql = session.query_sql:gsub(vim.pesc(old_quoted), new_quoted, 1)
      end
      -- Update query_spec.table_name so on_refresh rebuilds SQL with new name
      if session.query_spec and session.query_spec.table_name == old_name then
        session.query_spec = vim.tbl_extend("force", session.query_spec, { table_name = new_name })
      end
      -- Update state table_name
      session.state = vim.tbl_extend("force", session.state, { table_name = new_name })
      -- Refresh the buffer
      if session.on_refresh and vim.api.nvim_buf_is_valid(bufnr) then
        vim.schedule(function() session.on_refresh(bufnr) end)
      end
    end
  end
end

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
  local rendered = profile("build_render", function()
    return build_render(session, opts)
  end)
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
  session._redo_stack = nil  -- new edit clears redo
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
      row = math.max(0, vim.o.lines - float_h - 4),
      col = math.max(0, editor_cols - float_w - 2),
      width = float_w,
      height = float_h,
      style = "minimal",
      border = "rounded",
      title = " Live SQL ",
      title_pos = "center",
      focusable = false,
      zindex = 40,
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
  -- Iterate visible_columns so col_idx matches the rendered layout
  local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
  local vis_cols = r.visible_columns or st.columns
  if bp_row then
    for i, col in ipairs(vis_cols) do
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
    -- Cursor is on a separator or border -- snap to nearest LEFT column
    local snap = M._snap_col(vis_cols, bp_row, col_nr)
    if snap then
      return {
        row_idx  = row_idx,
        col_name = snap.col_name,
        col_idx  = snap.col_idx,
        value    = data.effective_value(st, row_idx, snap.col_name),
      }
    end
  end

  return nil
end

--- Pure helper: given visible columns, their byte positions, and a cursor byte offset,
--- return { col_name, col_idx } for the column the cursor belongs to.
--- Snaps LEFT (to the previous column) when cursor is in a separator region,
--- matching nav_col() behavior. Used by get_cell() and testable without vim state.
function M._snap_col(vis_cols, bp_row, col_nr)
  local best_col, best_idx = nil, nil
  for i, col in ipairs(vis_cols) do
    local bp = bp_row[col]
    if bp then
      if col_nr < bp.start then
        break  -- cursor is before this column; best_col is the snap target
      end
      best_col, best_idx = col, i
    end
  end
  if best_col then
    return { col_name = best_col, col_idx = best_idx }
  end
  -- Cursor is before ALL columns → snap to first
  local first = vis_cols[1]
  if first and bp_row[first] then
    return { col_name = first, col_idx = 1 }
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

  local tbl = state.table_name or "result"
  local buf_name = "grip://" .. tbl
  -- Ensure unique name (avoid collision with grip://query pad or duplicate table opens)
  if vim.fn.bufnr(buf_name) ~= -1 then
    buf_name = buf_name .. "#" .. bufnr
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)

  -- Register session before rendering
  M._sessions[bufnr] = {
    state = state,
    url = url,
    query_sql = query_sql,
    opts = opts or {},
    hidden_columns = {},
    elapsed_ms = opts and opts.elapsed_ms or nil,
  }

  -- Open in existing window (reuse_win) or a new horizontal split below
  local winid
  if opts and opts.reuse_win and vim.api.nvim_win_is_valid(opts.reuse_win) then
    winid = opts.reuse_win
    local prev_buf = vim.api.nvim_win_get_buf(winid)
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)  -- focus grip window (Issue #3)
    -- Clean up old grip session to prevent stale entries causing duplicate windows
    if prev_buf ~= bufnr and M._sessions[prev_buf] then
      local old_s = M._sessions[prev_buf]
      if old_s then M._close_live_sql_float(old_s) end
      M._sessions[prev_buf] = nil
      pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
    end
  else
    -- Defensive: scan for an existing grip grid window to reuse.
    -- Prevents window stacking when caller omits reuse_win.
    local found_grid_win
    if not (opts and opts.force_split) then
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(wid)
        if wbuf ~= bufnr and M._sessions[wbuf] then
          found_grid_win = wid
          break
        end
      end
    end

    if found_grid_win then
      -- Reuse the existing grid window (same logic as reuse_win above)
      winid = found_grid_win
      local prev_buf = vim.api.nvim_win_get_buf(winid)
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.api.nvim_set_current_win(winid)
      if prev_buf ~= bufnr and M._sessions[prev_buf] then
        local old_s = M._sessions[prev_buf]
        if old_s then M._close_live_sql_float(old_s) end
        M._sessions[prev_buf] = nil
        pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
      end
    else
      -- No existing grid: create a new split
      local cur_buf = vim.api.nvim_get_current_buf()
      local cur_name = vim.api.nvim_buf_get_name(cur_buf)
      if cur_name:match("grip://query") then
        vim.cmd("belowright split")
      else
        -- When sidebar is open, split within the right area (not full-width below)
        local schema_mod = require("dadbod-grip.schema")
        local right_win = schema_mod.is_open() and schema_mod.get_right_win()
        if right_win then
          vim.api.nvim_set_current_win(right_win)
          vim.cmd("belowright split")
        else
          vim.cmd("botright split")
        end
      end
      winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
      local available = vim.o.lines - 6
      vim.api.nvim_win_set_height(winid, math.min(available, math.max(15, #state.rows + 6)))
    end
  end

  -- Shrink query pad to fit its content so the grid gets more space
  for _, qw in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local qb = vim.api.nvim_win_get_buf(qw)
    if vim.api.nvim_buf_get_name(qb):match("grip://query") then
      local line_count = vim.api.nvim_buf_line_count(qb)
      vim.api.nvim_win_set_height(qw, math.max(4, math.min(12, line_count + 2)))
      break
    end
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
  -- nvim_buf_set_lines requires each element to contain no \n.
  -- Flatten any multi-line strings (e.g. cell values with embedded newlines).
  local flat = {}
  for _, l in ipairs(lines) do
    for _, sub in ipairs(vim.split(tostring(l), "\n", { plain = true })) do
      table.insert(flat, sub)
    end
  end

  local max_w = 0
  for _, l in ipairs(flat) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end

  local width = float_opts.width or math.min(math.max(max_w + 2, 30), 80)
  local height = float_opts.height or math.min(#flat, 30)
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
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, flat)
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
    zindex = 50,
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
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc, silent = true })
  end

  -- q: open query pad (pre-filled with current query)
  map("q", function()
    local query_pad = require("dadbod-grip.query_pad")
    local session_q = M._sessions[bufnr]
    local s_url = session_q and session_q.url
    local initial_sql
    if session_q and session_q.query_spec then
      initial_sql = qmod.build_sql(session_q.query_spec)
    elseif session_q and session_q.query_sql then
      initial_sql = session_q.query_sql
    end
    query_pad.open(s_url, initial_sql and { initial_sql = initial_sql } or nil)
  end, "Open query pad")

  -- r: refresh
  map("r", function()
    local session = M._sessions[bufnr]
    if not session then return end
    -- Re-run query via init callback
    if session.on_refresh then session.on_refresh(bufnr) end
  end, "Refresh query")

  -- e/i: edit cell
  local function edit_cell()
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
  end
  map("i", edit_cell, "Edit cell")

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

  -- c: clone current row (staged INSERT with copied values, PKs cleared)
  map("c", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if session.state.readonly then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to clone", vim.log.levels.INFO)
      return
    end
    if session.on_clone then session.on_clone(bufnr, cell.row_idx) end
  end, "Clone row (copy values, clear PKs)")

  -- a: apply all staged changes
  map("a", function()
    local session = M._sessions[bufnr]
    if not session then return end

    -- Mutation preview mode: execute the pending mutation
    if session.pending_mutation then
      local pm = session.pending_mutation
      local choice = vim.fn.confirm(
        string.format("Execute %s? (%d row%s affected)\n\n%s",
          pm.type, pm.row_count, pm.row_count == 1 and "" or "s",
          pm.sql:sub(1, 200)),
        "&Execute\n&Cancel", 2)
      if choice ~= 1 then return end
      local t0 = vim.uv.hrtime()
      local _, err = db.execute(pm.sql, session.url)
      local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
      if err then
        vim.notify("Failed: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("%s executed (%dms, %d row%s)",
        pm.type, ms, pm.row_count, pm.row_count == 1 and "" or "s"), vim.log.levels.INFO)
      local history = require("dadbod-grip.history")
      history.record({ sql = pm.sql, url = session.url, type = pm.type:lower(), elapsed_ms = ms })
      -- Clear mutation state and reopen the full table
      local tbl = pm.table_name
      local s_url = session.url
      session.pending_mutation = nil
      session._mutation_title = nil
      -- Reopen the full table (not the WHERE-filtered preview)
      local current_win = vim.api.nvim_get_current_win()
      local grip = require("dadbod-grip")
      grip.open(tbl, s_url, { reuse_win = current_win })
      return
    end

    -- Normal mode: apply staged changes
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

  -- u: two-tier undo
  -- Tier 0: mutation preview cancel
  -- Tier 1: local staging undo (uncommitted changes)
  -- Tier 2: transaction undo (reverse committed SQL)
  map("u", function()
    local session = M._sessions[bufnr]
    if not session then return end

    -- Tier 0: mutation preview — cancel (close the preview)
    if session.pending_mutation then
      session.pending_mutation = nil
      session._mutation_title = nil
      vim.notify("Mutation cancelled", vim.log.levels.INFO)
      -- Close the preview grid window
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then
        pcall(vim.api.nvim_win_close, win, true)
      end
      return
    end

    -- Tier 1: local staging undo
    if session._undo_stack and #session._undo_stack > 0 then
      if not session._redo_stack then session._redo_stack = {} end
      table.insert(session._redo_stack, session.state)
      local prev_state = table.remove(session._undo_stack)
      M.render(bufnr, prev_state)
      local remaining = #session._undo_stack
      if remaining > 0 then
        vim.notify("Undo (" .. remaining .. " more)", vim.log.levels.INFO)
      else
        vim.notify("Undo (back to original)", vim.log.levels.INFO)
      end
      return
    end

    -- Tier 2: transaction undo
    if session._txn_undo_stack and #session._txn_undo_stack > 0 then
      local reverse = session._txn_undo_stack[#session._txn_undo_stack]
      local count = #reverse
      local choice = vim.fn.confirm(
        "Undo last committed transaction? (" .. count .. " statement(s))",
        "&Yes\n&No", 2)
      if choice ~= 1 then return end
      local txn = "BEGIN;\n" .. table.concat(reverse, ";\n") .. ";\nCOMMIT;"
      local _, err = db.execute(txn, session.url)
      if err then
        vim.notify("Undo failed: " .. err, vim.log.levels.ERROR)
        return
      end
      table.remove(session._txn_undo_stack)
      vim.notify("Undid transaction (" .. count .. " statement(s))", vim.log.levels.INFO)
      if session.on_refresh then session.on_refresh(bufnr) end
      return
    end

    vim.notify("Nothing to undo", vim.log.levels.INFO)
  end, "Undo last edit")

  -- U: undo all (resets to original state) or cancel mutation
  map("U", function()
    local session = M._sessions[bufnr]
    if not session then return end
    -- Mutation preview: cancel
    if session.pending_mutation then
      session.pending_mutation = nil
      session._mutation_title = nil
      vim.notify("Mutation cancelled", vim.log.levels.INFO)
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then pcall(vim.api.nvim_win_close, win, true) end
      return
    end
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

  -- <C-r>: redo
  map("<C-r>", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session._redo_stack or #session._redo_stack == 0 then
      vim.notify("Nothing to redo", vim.log.levels.INFO)
      return
    end
    if not session._undo_stack then session._undo_stack = {} end
    table.insert(session._undo_stack, session.state)
    local redo_state = table.remove(session._redo_stack)
    M.render(bufnr, redo_state)
    local remaining = #session._redo_stack
    vim.notify("Redo" .. (remaining > 0 and " (" .. remaining .. " more)" or ""), vim.log.levels.INFO)
  end, "Redo")

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

  -- gy: yank table as Markdown pipe table
  map("gy", function()
    local session_gy = M._sessions[bufnr]
    if not session_gy or not session_gy._render then return end
    local st_gy = session_gy.state
    local r_gy = session_gy._render
    local cols = st_gy.columns
    local rows_data = {}
    for _, row_idx in ipairs(r_gy.ordered) do
      local row = {}
      for _, col in ipairs(cols) do
        table.insert(row, data.effective_value(st_gy, row_idx, col))
      end
      table.insert(rows_data, row)
    end
    local hdr = "| " .. table.concat(vim.tbl_map(function(c) return c:gsub("|", "\\|") end, cols), " | ") .. " |"
    local sep = "| " .. table.concat(vim.tbl_map(function() return "---" end, cols), " | ") .. " |"
    local lines_out = { hdr, sep }
    for _, row in ipairs(rows_data) do
      local parts = {}
      for _, v in ipairs(row) do table.insert(parts, ((v or ""):gsub("|", "\\|"))) end
      table.insert(lines_out, "| " .. table.concat(parts, " | ") .. " |")
    end
    vim.fn.setreg("+", table.concat(lines_out, "\n"))
    vim.notify("Copied as Markdown table (" .. #rows_data .. " rows)", vim.log.levels.INFO)
  end, "Yank table as Markdown")

  -- x: set cell to NULL
  map("x", function()
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
    vim.keymap.set("x", key, fn, { buffer = bufnr, desc = desc, silent = true })
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
      if st.inserted[ri] then
        st = data.undo_row(st, ri)
      else
        st = data.toggle_delete(st, ri)
      end
    end
    M.apply_edit(bufnr, st)
  end, "Batch toggle delete")

  -- Visual x: set all selected cells to NULL
  vmap("x", function()
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

  -- gs: preview staged SQL (or pending mutation SQL) in float
  map("gs", function()
    local session = M._sessions[bufnr]
    if not session then return end

    -- Mutation pending: show the pending SQL
    if session.pending_mutation then
      if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
        M._close_live_sql_float(session)
      else
        local pm_lines = {}
        for line in (session.pending_mutation.sql .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(pm_lines, line)
        end
        local grip_win = vim.api.nvim_get_current_win()
        open_info_float(grip_win, pm_lines, { title = " " .. session.pending_mutation.type .. " SQL ", filetype = "sql" })
      end
      return
    end

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

  -- gI: full table properties float
  map("gI", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local st = session.state
    if not st.table_name then
      vim.notify("Table properties requires a table name", vim.log.levels.INFO)
      return
    end
    local properties = require("dadbod-grip.properties")
    local grip_win = vim.api.nvim_get_current_win()
    properties.open(st.table_name, st.url, grip_win)
  end, "Table properties")

  -- gN: rename column under cursor
  map("gN", function()
    local session = M._sessions[bufnr]
    if not session or not session.state.table_name then
      vim.notify("Rename requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column", vim.log.levels.INFO)
      return
    end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.rename_column(session.state.table_name, cell.col_name, session.url, function()
      if session.on_refresh then session.on_refresh(bufnr) end
    end)
  end, "Rename column")

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
    local cell_staged = status == "modified"
      and st.changes[cell.row_idx]
      and st.changes[cell.row_idx][cell.col_name] ~= nil
    local display_status
    if status == "deleted" then
      display_status = "deleted"
    elseif status == "inserted" then
      display_status = "inserted"
    elseif cell_staged then
      display_status = "staged"
    else
      display_status = "original"
    end
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
    lines[#lines + 1] = "  Status: " .. display_status
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, {
      title = " Cell Info ",
      relative = "cursor",
      row = 1, col = 0,
    })
  end, "Explain cell")

  -- <CR>: expand cell popup
  map("<CR>", function()
    local session_cr = M._sessions[bufnr]
    if not session_cr or not session_cr._render then return end
    local cell = M.get_cell(bufnr)
    if cell then
      -- Data row: edit cell (spreadsheet-style Enter to edit)
      edit_cell()
    else
      -- Header/type row: detect column under cursor, show full name/type
      local r = session_cr._render
      local ref_bp = r.hdr_byte_positions
      if not ref_bp then return end
      local cols = r.visible_columns or session_cr.state.columns
      local col_nr = vim.api.nvim_win_get_cursor(0)[2]
      local found_col
      for _, col in ipairs(cols) do
        local bp = ref_bp[col]
        if bp and col_nr >= bp.start and col_nr <= bp.finish then
          found_col = col
          break
        end
      end
      if found_col then
        local info = { found_col }
        if session_cr._column_info then
          for _, ci in ipairs(session_cr._column_info) do
            if ci.column_name == found_col then
              table.insert(info, "Type: " .. (ci.data_type or "unknown"))
              if ci.is_nullable then table.insert(info, "Nullable: " .. ci.is_nullable) end
              break
            end
          end
        end
        local grip_win = vim.api.nvim_get_current_win()
        open_info_float(grip_win, info, {
          title = " " .. found_col .. " ",
          relative = "cursor",
          row = 1, col = 0,
        })
      end
    end
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
      local display_val = val and val:gsub("\n", "↵"):gsub("\r", "") or "NULL"
      local pad = string.rep(" ", max_name_w - vim.fn.strdisplaywidth(col))
      table.insert(lines, " " .. col .. pad .. "   " .. display_val)
    end
    local grip_win = vim.api.nvim_get_current_win()
    local _, popup_buf = open_info_float(grip_win, lines, {
      title = " Row " .. cell.row_idx .. " ",
    })
    -- Shadow ]p/[p: Vim's built-in "put indented" would E21 on modifiable=false popup buffers
    vim.keymap.set("n", "]p", "<Nop>", { buffer = popup_buf, silent = true })
    vim.keymap.set("n", "[p", "<Nop>", { buffer = popup_buf, silent = true })
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

  -- Shared helper: navigate to column by visible index offset.
  -- Works on data rows, header row, and type annotation row.
  local function nav_col(bufnr_l, offset, use_finish)
    local session_n = M._sessions[bufnr_l]
    if not session_n or not session_n._render then
      vim.notify("nav_col: no session or render", vim.log.levels.WARN)
      return
    end
    local r = session_n._render
    local cols = r.visible_columns or session_n.state.columns
    if #cols == 0 then
      vim.notify("nav_col: 0 columns", vim.log.levels.WARN)
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)

    -- Use current row's byte positions (handles per-row multibyte differences like ·NULL·).
    -- Fall back to hdr_byte_positions when on header/type/separator rows (di < 1).
    local data_start = r.data_start or 4
    local di = cursor[1] - data_start + 1
    local ref_bp
    if di < 1 then
      -- Type annotation row has its own byte positions when type names are truncated with "…".
      -- T row is at line (data_start - 2) when has_type_row (layout: title/hdr/type/sep/data).
      local type_row_line = r.data_start and (r.data_start - 2)
      if type_row_line and cursor[1] == type_row_line and r.type_row_byte_positions then
        ref_bp = r.type_row_byte_positions
      else
        ref_bp = r.hdr_byte_positions
      end
    elseif r.byte_positions and r.byte_positions[di] then
      ref_bp = r.byte_positions[di]
    else
      ref_bp = r.byte_positions and r.byte_positions[1] or r.hdr_byte_positions
    end
    if not ref_bp then
      vim.notify("nav_col: no byte positions", vim.log.levels.WARN)
      return
    end

    -- Determine current column index from cursor byte offset
    local col_nr = cursor[2]
    local current_idx = 1
    for i, col in ipairs(cols) do
      local bp = ref_bp[col]
      if bp and col_nr >= bp.start and col_nr <= bp.finish then
        current_idx = i
        break
      elseif bp and col_nr < bp.start then
        current_idx = math.max(1, i - 1)
        break
      end
      current_idx = i  -- past all known columns, snap to last
    end

    local target_idx
    if offset > 0 then
      target_idx = (current_idx % #cols) + 1
    else
      target_idx = current_idx == 1 and #cols or current_idx - 1
    end
    local target_col = cols[target_idx]
    local bp = ref_bp[target_col]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], use_finish and bp.finish or bp.start })
  end

  -- Tab: next column
  map("<Tab>", function() nav_col(bufnr, 1) end, "Next column")
  -- S-Tab: previous column
  map("<S-Tab>", function() nav_col(bufnr, -1) end, "Previous column")
  -- w: next column (alias for Tab)
  map("w", function() nav_col(bufnr, 1) end, "Next column")
  -- b: previous column (alias for S-Tab)
  map("b", function() nav_col(bufnr, -1) end, "Previous column")

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
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local bp = bp_row[cols[1]]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], bp.start })
  end, "First column")

  -- 0: first column (same as ^)
  map("0", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local bp = bp_row[cols[1]]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], bp.start })
  end, "First column")

  -- -: hide column under cursor
  map("-", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local cell = M.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column to hide", vim.log.levels.INFO)
      return
    end
    if not session.hidden_columns then session.hidden_columns = {} end
    -- Count visible columns
    local visible = 0
    for _, col in ipairs(session.state.columns) do
      if not session.hidden_columns[col] then visible = visible + 1 end
    end
    if visible <= 1 then
      vim.notify("Cannot hide last visible column", vim.log.levels.INFO)
      return
    end
    session.hidden_columns[cell.col_name] = true
    vim.notify("Hidden: " .. cell.col_name, vim.log.levels.INFO)
    M.render(bufnr, session.state)
  end, "Hide column under cursor")

  -- g-: restore all hidden columns
  map("g-", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session.hidden_columns or not next(session.hidden_columns) then
      vim.notify("No hidden columns", vim.log.levels.INFO)
      return
    end
    local count = 0
    for _ in pairs(session.hidden_columns) do count = count + 1 end
    session.hidden_columns = {}
    vim.notify("Restored " .. count .. " hidden column(s)", vim.log.levels.INFO)
    M.render(bufnr, session.state)
  end, "Restore all hidden columns")

  -- gH: column visibility picker
  map("gH", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session.hidden_columns then session.hidden_columns = {} end
    local items = {}
    for _, col in ipairs(session.state.columns) do
      local hidden = session.hidden_columns[col]
      local prefix = hidden and "[ ] " or "[x] "
      table.insert(items, prefix .. col)
    end
    vim.ui.select(items, { prompt = "Toggle column visibility:" }, function(choice)
      if not choice then return end
      local col_name = choice:sub(5)
      if session.hidden_columns[col_name] then
        session.hidden_columns[col_name] = nil
      else
        -- Check we're not hiding the last visible column
        local visible = 0
        for _, col in ipairs(session.state.columns) do
          if not session.hidden_columns[col] and col ~= col_name then visible = visible + 1 end
        end
        if visible == 0 then
          vim.notify("Cannot hide last visible column", vim.log.levels.INFO)
          return
        end
        session.hidden_columns[col_name] = true
      end
      M.render(bufnr, session.state)
    end)
  end, "Toggle column visibility")

  -- $: last column of current row
  map("$", function()
    local session = M._sessions[bufnr]
    if not session or not session._render then return end
    local r = session._render
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local row_order_idx = cursor[1] - ds + 1
    local bp_row = r.byte_positions and r.byte_positions[row_order_idx]
    if not bp_row then return end
    local bp = bp_row[cols[#cols]]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], bp.start })
  end, "Last column")

  -- e: end of current cell (last byte of cell's allocated space; shows truncation point)
  map("e", function() nav_col(bufnr, 1, true) end, "Next column (land at end of cell)")

  -- gq: load saved query (open query pad + picker)
  map("gq", function()
    local session_q = M._sessions[bufnr]
    local s_url = session_q and session_q.url
    local query_pad = require("dadbod-grip.query_pad")
    local saved = require("dadbod-grip.saved")
    query_pad.open(s_url, {})
    vim.schedule(function()
      saved.pick(function(sql_content)
        -- Find the query pad buffer and load SQL into it
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf):match("grip://query") then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sql_content, "\n"))
            vim.bo[buf].modified = false
            break
          end
        end
      end)
    end)
  end, "Load saved query")

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

  -- P: paste multi-line clipboard into consecutive rows (spread down)
  map("P", function()
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
    -- Split clipboard by newlines into values
    local values = {}
    for line in (clipboard .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(values, line)
    end
    -- Trim trailing empty entry from final newline
    if #values > 0 and values[#values] == "" then
      table.remove(values)
    end
    if #values <= 1 then
      -- Single value: just paste into one cell (same as p)
      local val = values[1] or clipboard:gsub("\n$", "")
      local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, val)
      M.apply_edit(bufnr, new_state)
      vim.notify(cell.col_name .. " = " .. val:sub(1, 30), vim.log.levels.INFO)
      return
    end
    -- Multiple values: spread into consecutive rows
    local r = session._render
    if not r then return end
    local ds = r.data_start or 4
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local start_order = cursor_line - ds + 1
    if start_order < 1 then return end
    local st = session.state
    local pasted = 0
    for i, val in ipairs(values) do
      local order_idx = start_order + i - 1
      if order_idx > #r.ordered then break end
      local row_idx = r.ordered[order_idx]
      st = data.add_change(st, row_idx, cell.col_name, val)
      pasted = pasted + 1
    end
    M.apply_edit(bufnr, st)
    vim.notify("Pasted " .. pasted .. " values into " .. cell.col_name, vim.log.levels.INFO)
  end, "Paste multi-line into consecutive rows")

  -- Visual y: yank selected cells in column (newline-separated)
  vmap("y", function()
    local session = M._sessions[bufnr]
    if not session then return end
    local cell = M.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local values = {}
    for _, ri in ipairs(row_indices) do
      local val = data.effective_value(session.state, ri, cell.col_name)
      table.insert(values, val or "")
    end
    local text = table.concat(values, "\n")
    vim.fn.setreg("+", text)
    vim.notify("Yanked " .. #values .. " cells from " .. cell.col_name, vim.log.levels.INFO)
  end, "Yank selected cells in column")

  -- gl: toggle live SQL preview float
  map("gl", function()
    local session = M._sessions[bufnr]
    if not session then return end

    -- Mutation preview mode: use gs instead
    if session.pending_mutation then
      vim.notify("gs: view mutation SQL  |  a: execute  |  U: cancel", vim.log.levels.INFO)
      return
    end

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
    local CANCEL = "\0"
    local ok, input = pcall(vim.fn.input, { prompt = "WHERE clause (e.g. status='x' AND amount>0): ", cancelreturn = CANCEL })
    if not ok or input == CANCEL or input == "" then return end
    local new_spec = qmod.add_filter(session_f.query_spec, input)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
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

  -- gp: load a saved filter preset
  map("gp", function()
    local session_fp = M._sessions[bufnr]
    if not session_fp or not session_fp.query_spec then return end
    local tbl = session_fp.state.table_name
    if not tbl then
      vim.notify("Filter presets require a table context", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Load filter preset") then return end
    local filters = require("dadbod-grip.filters")
    filters.pick(tbl, function(preset)
      local new_spec = qmod.set_filters(session_fp.query_spec, preset.clause)
      if session_fp.on_requery then session_fp.on_requery(bufnr, new_spec) end
      vim.notify("Filter: " .. preset.name, vim.log.levels.INFO)
    end)
  end, "Load filter preset")

  -- gP: save current filter as preset
  map("gP", function()
    local session_fp = M._sessions[bufnr]
    if not session_fp or not session_fp.query_spec then return end
    local tbl = session_fp.state.table_name
    if not tbl then
      vim.notify("Filter presets require a table context", vim.log.levels.INFO)
      return
    end
    if not qmod.has_filters(session_fp.query_spec) then
      vim.notify("No active filters to save", vim.log.levels.INFO)
      return
    end
    -- Combine all active filters into one clause
    local clauses = {}
    for _, f in ipairs(session_fp.query_spec.filters) do
      table.insert(clauses, "(" .. f.clause .. ")")
    end
    local combined = table.concat(clauses, " AND ")
    local CANCEL = "\0"
    local ok, name = pcall(vim.fn.input, { prompt = "Save filter as: ", cancelreturn = CANCEL })
    if not ok or name == CANCEL or name == "" then return end
    local filters = require("dadbod-grip.filters")
    filters.save(tbl, name, combined)
  end, "Save filter as preset")

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

  -- H/L: ergonomic page navigation (prev/next) — single-key aliases for [p/]p
  map("H", function()
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

  map("L", function()
    local session_p = M._sessions[bufnr]
    if not session_p or not session_p.query_spec then return end
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

    -- Empty result: fetch columns from schema (same guard as do_refresh in init.lua)
    if #result.columns == 0 then
      local col_info = db.get_column_info(fk_info.ref_table, session_fk.state.url)
      if col_info then
        for _, ci in ipairs(col_info) do
          table.insert(result.columns, ci.column_name)
        end
      end
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

  -- ga: aggregate current column (normal: all rows, visual: selected rows)
  map("ga", function()
    local session_a = M._sessions[bufnr]
    if not session_a or not session_a._render then return end
    local r = session_a._render
    local st_a = session_a.state

    -- Determine which column to aggregate from cursor position
    local col_name
    do
      local cell = M.get_cell(bufnr)
      if cell then
        col_name = cell.col_name
      else
        -- Cursor may be on header/type row — resolve via byte position
        local col_nr = vim.api.nvim_win_get_cursor(0)[2]
        local cols = r.visible_columns or st_a.columns
        if r.hdr_byte_positions then
          local snapped = M._snap_col(cols, r.hdr_byte_positions, col_nr)
          if snapped then col_name = snapped.col_name end
        end
      end
      if not col_name then
        vim.notify("Move cursor to a column first", vim.log.levels.INFO)
        return
      end
    end

    -- Get row range: visual selection or all data rows
    local start_line = vim.fn.line("'<")
    local end_line   = vim.fn.line("'>")
    local ds = r.data_start or 4
    if start_line == 0 or end_line == 0 then
      -- No visual selection — aggregate entire column
      start_line = ds
      end_line = ds + #r.ordered - 1
    end

    -- Collect values for the single column
    local values = {}
    local numeric_values = {}
    for line = start_line, end_line do
      local row_order = line - ds + 1
      if row_order >= 1 and row_order <= #r.ordered then
        local row_idx = r.ordered[row_order]
        local val = data.effective_value(st_a, row_idx, col_name)
        if val ~= nil then
          table.insert(values, val)
          local num = tonumber(val)
          if num then table.insert(numeric_values, num) end
        end
      end
    end

    if #values == 0 then
      vim.notify("ga: " .. col_name .. " — no values", vim.log.levels.INFO)
      return
    end

    local agg_parts = { "ga: " .. col_name .. "  Count: " .. #values }
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
  end, "Aggregate current column")

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

  -- gR: table profile report
  map("gR", function()
    local session_pr = M._sessions[bufnr]
    if not session_pr or not session_pr.state.table_name then
      vim.notify("Profile requires a table name", vim.log.levels.INFO)
      return
    end
    local profile = require("dadbod-grip.profile")
    profile.open(session_pr.state.table_name, session_pr.state.url)
  end, "Table profile report")

  -- gE: export in multiple formats
  map("gE", function()
    local session_e = M._sessions[bufnr]
    if not session_e or not session_e._render then return end
    local st_e = session_e.state
    local r_e = session_e._render

    local formats = { "CSV", "TSV", "JSON", "SQL INSERT", "Markdown", "Grip Table" }
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
            table.insert(parts, (tostring(v or ""):gsub("|", "\\|")))
          end
          table.insert(lines_out, "| " .. table.concat(parts, " | ") .. " |")
        end
        output = table.concat(lines_out, "\n")
      elseif choice == "Grip Table" then
        -- Box-drawing table matching the grid style
        local widths = {}
        for ci, col in ipairs(cols) do
          widths[ci] = vim.fn.strdisplaywidth(col)
        end
        for _, row in ipairs(rows_data) do
          for ci, v in ipairs(row) do
            widths[ci] = math.max(widths[ci], vim.fn.strdisplaywidth(tostring(v or "NULL")))
          end
        end
        -- Top border: ╔════╤════╗
        local top_parts = {}
        for ci = 1, #cols do
          table.insert(top_parts, string.rep("═", widths[ci] + 2))
        end
        local top = "╔" .. table.concat(top_parts, "╤") .. "╗"
        -- Header: ║ col │ col ║
        local hdr_parts = {}
        for ci, col in ipairs(cols) do
          local pad = widths[ci] - vim.fn.strdisplaywidth(col)
          table.insert(hdr_parts, " " .. col .. string.rep(" ", pad) .. " ")
        end
        local hdr = "║" .. table.concat(hdr_parts, "│") .. "║"
        -- Separator: ╠════╪════╣
        local sep_parts = {}
        for ci = 1, #cols do
          table.insert(sep_parts, string.rep("═", widths[ci] + 2))
        end
        local separator = "╠" .. table.concat(sep_parts, "╪") .. "╣"
        -- Data rows: ║ val │ val ║
        local data_lines = {}
        for _, row in ipairs(rows_data) do
          local row_parts = {}
          for ci, v in ipairs(row) do
            local display = v or "NULL"
            local pad = widths[ci] - vim.fn.strdisplaywidth(display)
            -- Right-align numbers
            if v and tonumber(v) then
              table.insert(row_parts, " " .. string.rep(" ", pad) .. display .. " ")
            else
              table.insert(row_parts, " " .. display .. string.rep(" ", pad) .. " ")
            end
          end
          table.insert(data_lines, "║" .. table.concat(row_parts, "│") .. "║")
        end
        -- Bottom border: ╚════╧════╝
        local bot_parts = {}
        for ci = 1, #cols do
          table.insert(bot_parts, string.rep("═", widths[ci] + 2))
        end
        local bot = "╚" .. table.concat(bot_parts, "╧") .. "╝"
        local lines_out = { top, hdr, separator }
        for _, dl in ipairs(data_lines) do table.insert(lines_out, dl) end
        table.insert(lines_out, bot)
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

  -- gD: diff against another table
  map("gD", function()
    local session_d = M._sessions[bufnr]
    if not session_d then return end
    local st = session_d.state
    if not st.table_name then
      vim.notify("Diff requires a table name", vim.log.levels.INFO)
      return
    end
    local CANCEL = "\0"
    local ok, other = pcall(vim.fn.input, { prompt = "Diff " .. st.table_name .. " against: ", cancelreturn = CANCEL })
    if not ok or other == CANCEL or other == "" then return end
    local diff_mod = require("dadbod-grip.diff")
    diff_mod.open(st.table_name, other, st.url)
  end, "Diff against table")

  -- gb: schema browser sidebar (toggle/focus)
  map("gb", function()
    local schema = require("dadbod-grip.schema")
    local s_url = M._sessions[bufnr] and M._sessions[bufnr].url
    schema.toggle(s_url)
  end, "Schema browser")

  -- go / gT / gt: table picker
  local function _pick_table()
    local picker = require("dadbod-grip.picker")
    local s_url = M._sessions[bufnr] and M._sessions[bufnr].url
    picker.pick_table(s_url, function(name)
      local grip = require("dadbod-grip")
      grip.open(name, s_url)
    end)
  end
  map("go", _pick_table, "Pick table")
  map("gT", _pick_table, "Pick table")
  map("gt", _pick_table, "Pick table")

  -- gC / <C-g>: switch database connection
  local function _pick_connection()
    require("dadbod-grip.connections").pick()
  end
  map("gC", _pick_connection, "Switch connection")
  map("<C-g>", _pick_connection, "Switch connection")

  -- gO: swap read-only query result to editable table
  map("gO", function()
    local session = M._sessions[bufnr]
    if not session then return end
    if not session.state.readonly then
      vim.notify("Already editable: i=edit  o=insert  d=delete", vim.log.levels.INFO)
      return
    end
    local grip = require("dadbod-grip")
    local s_url = session.url
    local current_win = vim.api.nvim_get_current_win()

    -- Try to auto-detect table name (check all sources)
    local detected = session.state.table_name
      or (session.query_spec and session.query_spec.table_name)
    local ambiguous = false

    -- Helper: extract table name from SQL (handles quoted and unquoted identifiers)
    local function extract_table_from_sql(sql_text)
      local flat = sql_text:gsub("\n", " ")
      -- Try quoted: FROM "table" or FROM `table`
      local quoted = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
        or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
      if quoted then return quoted end
      -- Unquoted: FROM table_name
      return flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
    end

    local function has_joins(sql_text)
      return sql_text:upper():match("JOIN%s") ~= nil
    end

    -- Fallback: parse base_sql from query spec (original unwrapped SQL)
    if not detected and session.query_spec and session.query_spec.base_sql then
      detected = extract_table_from_sql(session.query_spec.base_sql)
      ambiguous = has_joins(session.query_spec.base_sql)
    end

    -- Last resort: parse the wrapped query_sql (extract inner from _grip wrapper)
    if not detected then
      local sql_str = (session.query_sql or ""):gsub("\n", " ")
      local inner_sql = sql_str:match("%(%s*(.-)%s*%)%s+AS%s+_grip")
      local parse_target = inner_sql or sql_str
      detected = extract_table_from_sql(parse_target)
      ambiguous = ambiguous or has_joins(parse_target)
    end

    if detected and not ambiguous then
      vim.notify("Opening " .. detected .. " as editable table", vim.log.levels.INFO)
      grip.open(detected, s_url, { reuse_win = current_win })
    else
      -- Detection failed — show diagnostics so we can fix the root cause
      vim.notify(string.format(
        "gO: could not detect table\n table_name=%s | has_spec=%s | spec.table=%s\n spec.base_sql=%s\n query_sql=%s",
        tostring(session.state.table_name),
        tostring(session.query_spec ~= nil),
        tostring(session.query_spec and session.query_spec.table_name),
        tostring(session.query_spec and session.query_spec.base_sql and session.query_spec.base_sql:sub(1, 60)),
        tostring((session.query_sql or ""):sub(1, 60))
      ), vim.log.levels.WARN)
      -- Still offer picker as fallback
      local picker = require("dadbod-grip.picker")
      picker.pick_table(s_url, function(name)
        grip.open(name, s_url, { reuse_win = current_win })
      end)
    end
  end, "Open as editable table")

  -- gh: query history browser
  map("gh", function()
    local hist = require("dadbod-grip.history")
    local session_h = M._sessions[bufnr]
    local s_url = session_h and session_h.url
    hist.pick(function(sql_content)
      local query_pad = require("dadbod-grip.query_pad")
      query_pad.open(s_url, { initial_sql = sql_content })
    end)
  end, "Query history")

  -- A: AI SQL generation
  map("A", function()
    local session_ai = M._sessions[bufnr]
    local s_url = session_ai and session_ai.state.url
    if not s_url then
      s_url = require("dadbod-grip.db").get_url()
    end
    if not s_url then
      vim.notify("No database connection for AI", vim.log.levels.WARN)
      return
    end
    local ai = require("dadbod-grip.ai")
    ai.ask(s_url)
  end, "AI SQL generation")

  -- ?: help popup
  map("?", function()
    local session = M._sessions[bufnr]
    M.show_help({ readonly = session and session.state.readonly })
  end, "Show help")
end

--- Open the full help popup. Called from grid, query pad, and schema sidebar.
--- opts.readonly = true → show read-only notice instead of editing section.
function M.show_help(opts)
  opts = opts or {}
  local grip_win = vim.api.nvim_get_current_win()
  local ro = opts.readonly
  local help = {
      "",
      "    D   ███████╗███████╗██╗███████╗",
      "    A  ██╔═════╝██╔══██║██║██╔══██║",
      "    D  ██║  ███╗██████╔╝██║███████║",
      "    b  ██║   ██║██╔══██╗██║██╔════╝",
      "    o  ╚██████╔╝██║  ██║██║██║",
      "    d   ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝",
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
      "  0/^       First column",
      "  -         Hide column under cursor",
      "  g-        Restore all hidden columns",
      "  gH        Column visibility picker",
      "  $         Last column",
      "  e         Next column, land at end of cell",
      "  {/}       Prev / next modified row",
      "  <CR> / i  Edit cell under cursor",
      "  K         Row view (vertical transpose)",
      "  y         Yank cell value to clipboard",
      "  Y         Yank row as CSV",
      "  gY        Yank entire table as CSV",
      "  gy        Yank table as Markdown pipe table",
      "",
      "  Sort / Filter / Pagination",
      "  s         Toggle sort on column (ASC→DESC→off)",
      "  S         Stack sort on column (stackable — press S on multiple cols for ▲1 ▼2 ▲3)",
      "  f         Quick filter by cell value",
      "  <C-f>     Freeform WHERE clause filter",
      "            ↳ e.g.: status = 'active'",
      "            ↳ e.g.: created_at > '2024-01-01' AND amount > 100",
      "            ↳ e.g.: name ILIKE '%alice%'",
      "            ↳ F clears all filters",
      "  F         Clear all filters",
      "  gp        Load saved filter preset",
      "  gP        Save current filter as preset",
      "  X         Reset view (clear sort/filter/page)",
      "  L / H     Next / previous page",
      "  ]p / [p   Next / previous page (bracket alias)",
      "  ]P / [P   Last / first page",
      "",
      "  FK Navigation",
      "  gf        Follow foreign key under cursor",
      "  <C-o>     Go back in FK navigation stack",
      "",
      "  Analysis & Export",
      "  ga        Aggregate selected cells (visual mode)",
      "  gS        Column statistics popup",
      "  gR        Table profile (sparkline distributions)",
      "  gx        Explain current query plan",
      "  gD        Diff against another table",
      "  gE        Export (CSV, TSV, JSON, SQL, Markdown, Grip Table)",
      "",
      "  Schema & Workflow",
      "  go        Toggle schema browser",
      "  gT        Pick table (floating picker)",
      "  gO        Open as editable table (read-only → table)",
      "  gC/<C-g>  Switch database connection",
      "  q         Open query pad",
      "  gq        Load saved query",
      "  gh        Query history browser",
      "  A         AI SQL generation",
      "  gA        AI SQL generation (from query pad)",
      "            ↳ context: schema DDL for ≤30 tables (cols, types, PKs, FKs)",
      "            ↳ + existing query pad SQL if present (AI will modify it)",
      "            ↳ provider: ANTHROPIC_API_KEY → OPENAI → GEMINI → Ollama",
      "",
      "  Actions",
      "  r         Refresh (re-run query)",
      "  :q        Close grip buffer",
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
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  ᕦ( ᐛ )ᕤ  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
      })
    else
      vim.list_extend(help, {
        "",
        "  Editing",
        "  <CR> / i  Edit cell under cursor",
        "  x         Set cell to NULL",
        "  p         Paste clipboard into cell",
        "  P         Paste multi-line into rows",
        "  o         Insert new row after cursor",
        "  c         Clone row (copy values, clear PKs)",
        "  d         Toggle delete on current row",
        "  u         Undo last edit (multi-level)",
        "  <C-r>     Redo",
        "  U         Undo all (reset to original)",
        "  a         Apply all staged changes to DB",
        "",
        "  Batch Edit (visual mode)",
        "  e         Set selected cells to same value",
        "  d         Toggle delete on selected rows",
        "  x         Set selected cells to NULL",
        "  y         Yank selected cells in column",
        "",
        "  Inspection",
        "  gs        Preview staged SQL",
        "  gc        Copy staged SQL to clipboard",
        "  gi        Table info (columns, types, PKs)",
        "  gI        Table properties (full detail)",
        "  gN        Rename column under cursor",
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
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  ᕦ( ᐛ )ᕤ  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
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
      zindex = 50,
    })
    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end
end

-- Register callbacks for edit/delete/insert/apply/refresh from init.
function M.set_callbacks(bufnr, callbacks)
  local session = M._sessions[bufnr]
  if not session then return end
  for k, v in pairs(callbacks) do
    session[k] = v
  end
end

-- Exposed for testing
M._classify_cell = classify_cell

return M
