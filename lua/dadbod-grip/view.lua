-- view.lua: buffer rendering + keymaps.
-- One buffer per grip session. State in M._sessions[bufnr].

local data    = require("dadbod-grip.data")
local sql     = require("dadbod-grip.sql")
local esc = sql.escape_literal
local db      = require("dadbod-grip.db")
local qmod    = require("dadbod-grip.query")
local editor  = require("dadbod-grip.editor")
local VERSION = require("dadbod-grip.version")
local ui      = require("dadbod-grip.ui")
local filetypes = require("dadbod-grip.filetypes")

local M = {}
M._sessions = {}  -- [bufnr] = { state, url, query_sql }

--- Canonical content window finder: unpinned grid > welcome screen > nil.
--- Pinned sessions are excluded: callers must not auto-replace them.
--- All window-placement callers use this. Never returns sidebar or query pad.
function M.find_content_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  -- Pass 1: prefer an unpinned grip grid.
  for _, wid in ipairs(wins) do
    local s = M._sessions[vim.api.nvim_win_get_buf(wid)]
    if s and not s.pinned then return wid end
  end
  -- Pass 2: fall back to the welcome screen.
  for _, wid in ipairs(wins) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wid)) == "grip://welcome" then
      return wid
    end
  end
  -- All grids are pinned (or none exist): caller will create a new split.
  return nil
end

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

-- ── enum hint ──────────────────────────────────────────────────────────────
-- A column with few distinct values (a status/role/enum-ish column) gets its
-- values shown as a virtual hint line in the cell editor. Values are fetched
-- on demand (SELECT DISTINCT ... LIMIT threshold+1) and cached per session,
-- so repeat edits are instant. Columns with more distinct values, free-text
-- columns, and grids without a real table (ad-hoc SQL, staged-insert-only)
-- get no hint at all.
local ENUM_HINT_MAX = 8  -- show hint only for <= this many distinct non-NULL values

--- Known distinct values for session's table column, or nil when the column
--- isn't enum-ish. Cached on session.enum_cache[table][col] (false = negative).
function M.enum_hint_values(session, col_name)
  if not session or not session.state or not col_name then return nil end
  local tbl = session.state.table_name
  if not tbl then return nil end  -- no table context: ad-hoc query / staged-only grid

  session.enum_cache = session.enum_cache or {}
  session.enum_cache[tbl] = session.enum_cache[tbl] or {}
  local cached = session.enum_cache[tbl][col_name]
  if cached ~= nil then
    return cached or nil  -- false = cached negative
  end

  local col_q = sql.quote_ident(col_name)
  local distinct_sql = string.format(
    "SELECT DISTINCT %s FROM %s WHERE %s IS NOT NULL ORDER BY 1 LIMIT %d",
    col_q, sql.quote_ident(tbl), col_q, ENUM_HINT_MAX + 1
  )
  local result = db.query(distinct_sql, session.state.url)
  if not result or not result.rows or #result.rows == 0 or #result.rows > ENUM_HINT_MAX then
    session.enum_cache[tbl][col_name] = false  -- error / empty / too wide: cache negative
    return nil
  end

  local values = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(values, row[1]) end
  end
  if #values == 0 then
    session.enum_cache[tbl][col_name] = false
    return nil
  end
  session.enum_cache[tbl][col_name] = values
  return values
end

-- ── tab view system ─────────────────────────────────────────────────────────
-- 1=sidebar/connections  2=query-pad/history  3=grid/table-picker
-- 4=ER diagram  5=stats  6=columns  7=fk  8=indexes  9=constraints
local VIEW_KEYS = require("dadbod-grip.keymaps").TAB_VIEWS
local VIEW_LABELS = {
  records     = "Rec",
  columns     = "Col",
  fk          = "FK",
  indexes     = "Idx",
  constraints = "Con",
  stats       = "Stat",
  history     = "Hist",
  er_diagram  = "ER",
}

local SEP_COL = "│"
local SEP_HDR = "═"
local SEP_MID = "╪"
local MID_L   = "╠"
local MID_R   = "╣"
local BOT_L   = "╚"
local BOT_R   = "╝"
local BOT_MID = "╧"

-- ── highlight group setup ──────────────────────────────────────────────────
-- Groups are re-applied on ColorScheme so they survive :colorscheme switches.
local _hl_ag = vim.api.nvim_create_augroup("DadbodGripHL", { clear = true })

-- Per-connection accent palette. Every hex here is already in use by one of
-- the groups below, so a coloured connection tints the UI with the plugin's
-- own colours instead of introducing a second palette:
--   green  GripBoolTrue/GripInserted   orange GripNullStaged
--   red    GripNegative/GripDeleted    blue   GripUrl/GripWatch
--   violet GripBorder (the default)    yellow GripStatusOk
local ACCENTS = {
  green  = { hex = "#a6e3a1", cterm = 113 },
  orange = { hex = "#fab387", cterm = 216 },
  red    = { hex = "#f38ba8", cterm = 203 },
  blue   = { hex = "#89b4fa", cterm = 117 },
  violet = { hex = "#cba6f7", cterm = 147 },
  yellow = { hex = "#f9e2af", cterm = 229 },
}
-- No connection colour, an entry with no `color`, or a value neither this
-- palette nor #rrggbb: the UI looks exactly as it did before the option
-- existed. This is GripBorder's historical definition.
local DEFAULT_ACCENT = ACCENTS.violet

--- Nearest xterm-256 index for a hex colour.
---
--- Every group in this file pairs a gui hex with a ctermfg, so an accent has
--- to carry one too or a 256-colour terminal would silently drop the colour a
--- palette name still gets. The palette names above ship their index; only a
--- user's own #rrggbb needs approximating.
---
--- The 240 colours above the ANSI 16 are a 6x6x6 cube (levels
--- 0/95/135/175/215/255) plus a 24-step grey ramp (8 + 10i). Both candidates
--- are computed and the nearer one wins: picking the ramp only for an exact
--- r == g == b makes a colour that is grey to within one unit -- #2f2f30 --
--- come back as a saturated dark blue, and picking the cube for every grey
--- loses the ramp's much finer steps.
local function cterm_for(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  local function dist(cr, cg, cb)
    return (r - cr) ^ 2 + (g - cg) ^ 2 + (b - cb) ^ 2
  end

  -- Cube. The levels are unevenly spaced at the bottom, hence the two special
  -- cases before the arithmetic takes over.
  local function level(v)
    if v < 48  then return 0 end
    if v < 115 then return 1 end
    return math.floor((v - 35) / 40)
  end
  local function level_value(i) return i == 0 and 0 or 55 + i * 40 end
  local ri, gi, bi = level(r), level(g), level(b)
  local cube_d = dist(level_value(ri), level_value(gi), level_value(bi))

  -- Grey ramp, indexed off the average channel.
  local gi_ramp = math.floor(((r + g + b) / 3 - 8) / 10 + 0.5)
  gi_ramp = math.max(0, math.min(23, gi_ramp))
  local grey = 8 + 10 * gi_ramp

  if dist(grey, grey, grey) < cube_d then return 232 + gi_ramp end
  return 16 + 36 * ri + 6 * gi + bi
end

--- A palette name or "#rrggbb" as an accent, or nil for anything else.
--- Unknown values are nil rather than an error: a typo in connections.json
--- must cost the colour, not the connection.
local function resolve_accent(color)
  if type(color) ~= "string" then return nil end
  local named = ACCENTS[color:lower()]
  if named then return named end
  local hex = color:match("^#%x%x%x%x%x%x$")
  if hex then return { hex = hex, cterm = cterm_for(hex) } end
  return nil
end

-- The accent of the connection currently switched to. Read by
-- ensure_highlights, so it is re-applied on every :colorscheme too.
local _accent = nil

local function ensure_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, "GripHeader",       { bold = true })
  -- Sticky-header counterpart of GripColHighlight: same bg, so the column the
  -- cursor is in reads the same in the winbar as it does in the grid.
  hl(0, "GripHeaderActive", { bold = true, bg = "#313244", ctermbg = 237 })
  hl(0, "GripNull",         { italic = true, fg = "#6c7086", ctermfg = 243 })
  -- Staged groups carry guibg to visually distinguish pending mutations.
  -- Staged NULL: peach/flamingo fg signals "value cleared" (distinct from red=deleted, violet=modified)
  hl(0, "GripModified",     { bold = true,         fg = "#c084fc", ctermfg = 177, bg = "#1a0a30", ctermbg = 236 })
  hl(0, "GripDeleted",      { strikethrough = true, fg = "#f38ba8", ctermfg = 203, bg = "#2d1418", ctermbg = 236 })
  hl(0, "GripInserted",     { bold = true,         fg = "#a6e3a1", ctermfg = 113, bg = "#162d18", ctermbg = 236 })
  hl(0, "GripNullStaged",   { bold = true,         fg = "#fab387", ctermfg = 216, bg = "#2d1800", ctermbg = 236 })
  hl(0, "GripReadonly",     { italic = true,       fg = "#6c7086", ctermfg = 243 })
  hl(0, "GripStatusOk",     { bold = true,         fg = "#f9e2af", ctermfg = 229 })
  hl(0, "GripStatusChg",    { bold = true,         fg = "#f9e2af", ctermfg = 229 })
  hl(0, "GripNegative",     { bold = true,         fg = "#f38ba8", ctermfg = 203 })
  hl(0, "GripBoolTrue",     { bold = true,         fg = "#a6e3a1", ctermfg = 113 })
  hl(0, "GripBoolFalse",    { bold = true,         fg = "#f38ba8", ctermfg = 203 })
  hl(0, "GripDatePast",     { italic = true,       fg = "#6c7086", ctermfg = 243 })
  hl(0, "GripUrl",          { underline = true,    fg = "#89b4fa", ctermfg = 117 })
  hl(0, "GripWatch",        { bold = true,         fg = "#89b4fa", ctermfg = 117 })
  hl(0, "GripColHighlight", { bg = "#313244", ctermbg = 237 })
  -- Dim marker group: filter-line bullets, column type annotations.
  hl(0, "GripColType",      { fg = "#6c7086", ctermfg = 243 })
  -- Connection accent. GripBorder is defined from it rather than beside the
  -- groups above, so an uncoloured connection restores its historical violet
  -- instead of leaving the last coloured connection's border behind.
  local accent = _accent or DEFAULT_ACCENT
  hl(0, "GripConnAccent",     {              fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripConnAccentBold", { bold = true, fg = accent.hex, ctermfg = accent.cterm })
  hl(0, "GripBorder",         { bold = true, fg = accent.hex, ctermfg = accent.cterm })
end
ensure_highlights() -- define groups on module load so welcome screen can use them
vim.api.nvim_create_autocmd("ColorScheme", {
  group    = _hl_ag,
  callback = ensure_highlights,
})

--- Tint the accent groups for the connection being switched to.
---
--- Called from connections.switch() with the entry's `color` -- nil, an
--- unknown name and a non-string all mean "no accent", which restores the
--- defaults rather than leaving the previous connection's colour on screen:
--- coming back from a red prod connection to an uncoloured local one must not
--- keep the red border.
---
--- The accent is stored, not just applied, because ensure_highlights() runs
--- again on every ColorScheme -- that is what keeps the accent alive across a
--- :colorscheme switch.
--- @param color string|nil  a palette name (green/orange/red/blue/violet/yellow) or "#rrggbb"
function M.set_connection_accent(color)
  _accent = resolve_accent(color)
  ensure_highlights()
end

-- Module-level augroup for all buffer/window lifecycle autocmds in this module.
-- Created once at require time with clear=true so re-sourcing never doubles handlers.
local _ag = vim.api.nvim_create_augroup("DadbodGripView", { clear = true })

-- ── column width calculation ──────────────────────────────────────────────
-- truncate_display/pad_display live in ui.lua so properties.lua, profile.lua,
-- diff.lua and er_diagram.lua share one display-width truncation/padding
-- instead of each rolling byte-length arithmetic. The ASCII fast path and the
-- note on 'ambiwidth' moved there with the code they explain.
local truncate_display = ui.truncate_display
local pad_display = ui.pad_display

-- Returns two tables keyed by column name:
--   widths  — display width clamped to max_width (what the grid actually renders)
--   natural — true (unclamped) content width, used to cap slack expansion so a
--             column is never padded wider than the data it holds
local function calc_col_widths(columns, rows, max_width)
  local widths = {}
  local natural = {}
  for _, col in ipairs(columns) do
    -- +3 reserves space for stacked sort indicators (e.g. " ▲1") so the col name is never truncated
    local w = vim.fn.strdisplaywidth(col) + 3
    natural[col] = w
    widths[col] = math.min(w, max_width)
  end
  -- For large tables, sample first 100 + last 10 rows instead of scanning all
  local n = #rows
  local sample_end = n > 200 and 100 or n
  local function scan_row(row_data)
    for i, col in ipairs(columns) do
      local v = row_data[i] or ""
      local display = (v == nil or v == "") and NULL_DISPLAY or tostring(v)
      local dw = vim.fn.strdisplaywidth(display)
      if dw > natural[col] then natural[col] = dw end
      widths[col] = math.min(math.max(widths[col], dw), max_width)
    end
  end
  for ri = 1, sample_end do scan_row(rows[ri]) end
  if n > 200 then
    for ri = math.max(sample_end + 1, n - 9), n do scan_row(rows[ri]) end
  end
  return widths, natural
end

--- Hand leftover horizontal space to truncated columns so a narrow table fills
--- the window — but never widen a column past its true content (`natural`),
--- otherwise hiding columns just pads the survivors with dead space. Each column
--- grows by at most `per_col_cap`. Layout reserves +3 per column (separators /
--- sort markers). Mutates and returns `widths`. Pure/testable.
function M._distribute_slack(columns, widths, natural, configured_max, available, per_col_cap)
  local total = 0
  for _, col in ipairs(columns) do total = total + widths[col] + 3 end
  local slack = available - total
  if slack <= 0 then return widths end
  for _, col in ipairs(columns) do
    if slack <= 0 then break end
    if widths[col] >= configured_max then           -- column was truncated at the cap
      local room = math.min(natural[col] - widths[col], per_col_cap)
      if room > 0 then
        local extra = math.min(slack, room)
        widths[col] = widths[col] + extra
        slack = slack - extra
      end
    end
  end
  return widths
end

-- ── cell display formatting ───────────────────────────────────────────────
local function format_cell(value, width, is_null_staged)
  if is_null_staged or value == nil then
    local s = pad_display(NULL_DISPLAY, width)
    return s, "GripNull"
  end
  value = tostring(value)
  if value:sub(1, #BINARY_PREFIX) == BINARY_PREFIX then
    local s = pad_display(value, width, false)
    return s, "GripReadonly"
  end
  local display = value ~= "" and value:gsub("\n", "↵"):gsub("\r", "") or NULL_DISPLAY
  local hl = value == "" and "GripNull" or nil
  return pad_display(display, width), hl
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

-- Returns true when the grid allows editing: either a table with detected
-- primary keys, or a local file in write mode (CSV, parquet, etc.).
local function is_editable(session)
  if not session or not session.state then return false end
  if not session.state.readonly then return true end
  return session.write_mode == true
    and filetypes.write_format(session.file_path) ~= nil
end
M._is_editable = is_editable  -- exposed for cell_buffer.lua

-- Build the title bar with connection/table info and staged count.
local function title_line(session, columns, widths, total_width)
  local staged = data.count_staged(session.state)
  local badges = {}
  if staged > 0 then table.insert(badges, staged .. " staged") end
  -- Metadata views: show view name as badge; suppress "read-only: no PK" noise
  if session.current_view and session.current_view ~= "records" then
    local vn = session.current_view
    local full_labels = {
      columns="Columns", fk="Foreign Keys", indexes="Indexes",
      constraints="Constraints", stats="Column Stats", history="History", explain="Explain",
    }
    table.insert(badges, full_labels[vn] or vn)
  elseif not is_editable(session) then
    table.insert(badges, "read-only: no PK")
  end
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
    title = truncate_display(title, available)
    title_dw = vim.fn.strdisplaywidth(title)
  end

  -- If still too wide (e.g. available <= 4: very narrow grid), show gH hint if it fits
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

  -- Resolve every cell's effective value exactly once. `effs` keeps the raw
  -- value (nil = NULL, which the render loop and the highlight loop both need
  -- to distinguish from ""), `display_rows` is the string view that
  -- calc_col_widths consumes. Both are indexed by column position, so nil
  -- holes in `effs` are fine — nothing iterates them with ipairs/#.
  local effs = {}
  local display_rows = {}
  for di, row_idx in ipairs(ordered) do
    local er, dr = {}, {}
    for i, col in ipairs(columns) do
      local eff = data.effective_value(st, row_idx, col)
      er[i] = eff
      dr[i] = eff or ""
    end
    effs[di] = er
    display_rows[di] = dr
  end

  -- Auto-fit: compute natural widths first (clamped to configured max);
  -- `natural_widths` keeps the true unclamped content width for slack capping.
  local widths, natural_widths = calc_col_widths(columns, display_rows, configured_max)

  -- Apply per-column width overrides (set by = keymap)
  if session.col_width_overrides then
    for col, override_w in pairs(session.col_width_overrides) do
      if widths[col] ~= nil then widths[col] = override_w end
    end
  end

  -- Smart auto-fit: if the table is narrower than the window, hand the leftover
  -- space to truncated columns — but never past their real content width, so
  -- hiding columns doesn't balloon the survivors with empty padding.
  if #columns > 0 then
    local available = vim.o.columns - 4  -- borders + padding
    M._distribute_slack(columns, widths, natural_widths, configured_max, available, 20)
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
      local is_ro = st.readonly and not is_editable(session)
      local prefix = is_ro and "~" or ""
      local sort_ind = qspec and qmod.get_sort_indicator(qspec, col) or nil
      local suffix = sort_ind and " " .. sort_ind or ""
      local label = prefix .. col .. suffix
      local w = widths[col]
      local lw = vim.fn.strdisplaywidth(label)
      if lw > w then
        label, lw = truncate_display(label, w)
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
        dtype, dw = truncate_display(dtype, w)
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
      local row_effs = effs[di]
      local row_parts = { ROW_PREFIX }
      local line_byte_positions = {}  -- {col_name = {start, finish}}
      local byte_pos = ROW_PREFIX_BYTES  -- after "║ " (4 bytes, not 2)

      for i, col in ipairs(columns) do
        local eff = row_effs[i]
        local w = widths[col]
        -- format_cell also returns a highlight group, but the authoritative
        -- one is computed in the highlight pass below; ignore it here.
        local cell_str = format_cell(eff, w, eff == nil)

        line_byte_positions[col] = { start = byte_pos, finish = byte_pos + #cell_str - 1 }

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
      for i, col in ipairs(columns) do
        local bp = line_byte_positions[col]
        if bp then
          local eff = row_effs[i]
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
    local page_str = qmod.page_info(session.query_spec, session.total_rows)
    -- Directional hints when result spans multiple pages
    local spec = session.query_spec
    local total_pages = math.max(1, math.ceil(session.total_rows / spec.page_size))
    if total_pages > 1 then
      local nav = {}
      if spec.page > 1 then nav[#nav + 1] = "H←" end
      if spec.page < total_pages then nav[#nav + 1] = "→L" end
      page_str = page_str .. "  " .. table.concat(nav, "  ")
    end
    table.insert(status_parts, page_str)
  else
    local row_str = #st.rows .. " rows"
    -- Safety hint: if result maxed out page_size, more data likely exists
    if session.query_spec and #st.rows >= session.query_spec.page_size then
      row_str = row_str .. "  →L?"
    end
    table.insert(status_parts, row_str)
  end

  local timing_str
  if session.elapsed_ms then
    local action = session.last_action or "query"
    timing_str = session.elapsed_ms .. "ms " .. action
    table.insert(status_parts, timing_str)
  end
  if staged_count > 0 then table.insert(status_parts, staged_count .. " staged") end
  if st.readonly and not is_editable(session) then table.insert(status_parts, "read-only") end
  local hidden_n = 0
  if session.hidden_columns then
    for _ in pairs(session.hidden_columns) do hidden_n = hidden_n + 1 end
  end
  if hidden_n > 0 then table.insert(status_parts, hidden_n .. " hidden") end

  local status_str = " " .. table.concat(status_parts, "  │  ")
  table.insert(lines, status_str)
  -- Highlight timing badge: query=yellow, applied=green
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

  -- ── Filter lines (one per active clause: always fully visible, never truncated) ──
  if session.query_spec and #session.query_spec.filters > 0 then
    for _, f in ipairs(session.query_spec.filters) do
      local fline = " \xE2\x96\xBE " .. f.clause  -- ▾ clause
      table.insert(lines, fline)
      -- Dim the ▾ bullet (space + ▾(3 bytes) + space = bytes 0–4)
      push_mark(#lines, 0, 5, "GripColType")
    end
  end

  -- ── Hint line ──
  local hints
  local cv = session.current_view
  if cv and cv ~= "records" then
    -- Metadata view: compact tab bar with current view marked (▶)
    local parts = {}
    for i = 4, 9 do
      local vn = VIEW_KEYS[i]
      local label = VIEW_LABELS[vn] or vn
      if vn == cv then
        table.insert(parts, "▶" .. i .. ":" .. label)
      else
        table.insert(parts, i .. ":" .. label)
      end
    end
    hints = " " .. table.concat(parts, "  ") .. "  │  r:refresh  q:query  ?:help"
  elseif session.pending_mutation then
    local mt = session.pending_mutation.type or "SQL"
    hints = " a:execute " .. mt .. "  U:cancel  gs:preview SQL  q:query"
  elseif st.readonly and not is_editable(session) then
    hints = " r:refresh  Tab/w:col  gy:markdown  gq:saved  q:query  A:ai  gL:pin  gJ:switch  4-9:views  ?:help"
  else
    hints = " i:edit  c:clone  d:delete  a:apply  r:refresh  gq:saved  q:query  A:ai  gL:pin  gJ:switch  4-9:views  ?:help"
  end
  table.insert(lines, hints)

  local data_start = has_type_row and 5 or 4
  return { lines = lines, marks = marks, widths = widths, ordered = ordered, byte_positions = row_byte_positions, hdr_byte_positions = hdr_byte_positions, type_row_byte_positions = type_row_byte_positions, data_start = data_start, visible_columns = columns }
end

-- ── namespace for extmarks ───────────────────────────────────────────────
local ns = vim.api.nvim_create_namespace("dadbod_grip")
local _col_hl_ns = vim.api.nvim_create_namespace("grip_col_hl")

-- M.update_table_sessions(old_name, new_name): patch all open grip sessions
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

-- M.render(bufnr, state): wipes and rewrites buffer, reapplies extmarks
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
  session._col_hl = nil       -- column-highlight memo belongs to the old render

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  local ok, err = pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered.lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, _col_hl_ns, 0, -1)

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

  -- The sticky header mirrors this render's column row; a new render (page
  -- turn, sort, FK jump, tab view) changes it, so refresh the winbar with it.
  -- Drop the cached connection mode with it: a render is rare enough to pay
  -- for the file read the RO badge needs, a CursorMoved is not.
  session._ro_mode = nil
  M._update_winbar(bufnr)
end

local UNDO_STACK_MAX = 50

-- M.apply_edit(bufnr, new_state): pushes current state to undo stack, then renders.
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

    local _ei = vim.o.eventignore
    vim.o.eventignore = "all"
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = math.max(0, vim.o.lines - float_h - 4),
      col = math.max(0, editor_cols - float_w - 2),
      width = float_w,
      height = float_h,
      style = "minimal",
      border = ui.border(),
      title = " Live SQL ",
      title_pos = "center",
      focusable = false,
      zindex = 40,
    })
    vim.o.eventignore = _ei
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

--- Close every grip-owned floating window.
--- Called at the start of every 1-9 surface keymap so pressing any number key
--- instantly dismisses open pickers / floats before the target surface opens.
--- @param session? table  grid session; may be nil (e.g. called from query pad)
function M.close_all_floats(session)
  if session then M._close_live_sql_float(session) end
  -- er_diagram tracks its own window; close() is a no-op when nothing is open
  pcall(function() require("dadbod-grip.er_diagram").close() end)
  -- close any grip_picker floats (stamped with grip_owned_float at creation)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" then
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf] and vim.b[buf].grip_owned_float then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
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
--- EXCEPT when the cursor is exactly one byte before a column start (last separator
--- byte): in that case snaps RIGHT to the next column. This ensures that actions
--- (edit, sort, filter) fire on the column the user is reaching toward, not the
--- one they left. Used by get_cell() and testable without vim state.
function M._snap_col(vis_cols, bp_row, col_nr)
  local best_col, best_idx = nil, nil
  for i, col in ipairs(vis_cols) do
    local bp = bp_row[col]
    if bp then
      if col_nr < bp.start then
        -- Last separator byte (touching the column) → snap RIGHT to this column.
        if col_nr == bp.start - 1 then
          return { col_name = col, col_idx = i }
        end
        break  -- mid-separator: best_col (previous column) is the snap target
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

--- Clamp a buffer line to the data-row range [data_start, data_start + #ordered - 1].
--- The title/header/type/separator rows sit above this range and the footer/hint
--- line sits below it; visual-mode navigation reuses this so `G`/`j`/`k` stop at the
--- last data row instead of overshooting onto the footer (issue #20). Pure/testable.
function M._clamp_data_line(r, line)
  local ds = r.data_start or 4
  local last = ds + #r.ordered - 1
  if last < ds then last = ds end  -- empty result set: collapse to data_start
  if line < ds then return ds end
  if line > last then return last end
  return line
end

--- Compute the horizontal scroll offset (leftcol) needed to bring a column's
--- right edge into view. `$` (grid_col_last) puts the cursor at the start of the
--- last column, but Neovim's default sidescroll leaves a wide column's right edge
--- off-screen. Given the current leftcol, the window's text width, and the
--- column's display-column span [start_vcol, finish_vcol] (all 1-based; a display
--- column c is visible iff leftcol < c <= leftcol + textwidth), return the new
--- leftcol that seats the right edge at the window's right, keeping the column's
--- start visible when the column fits. `margin` reveals that many extra display
--- columns past finish_vcol so the trailing separator/border glyph (" ║" / " │ ")
--- is shown too, not just the cell data. Returns nil when no scroll is needed.
--- Pure/testable.
function M._reveal_leftcol(leftcol, textwidth, start_vcol, finish_vcol, margin)
  margin = margin or 0
  if textwidth <= 0 then return nil end
  local want = finish_vcol + margin                  -- reveal this far to the right
  if want <= leftcol + textwidth then return nil end -- edge (incl. border) already visible
  local target = want - textwidth              -- seat the right edge at the window's right
  if target > start_vcol - 1 then              -- but never scroll the column's start off-screen
    target = start_vcol - 1                     -- (column wider than the window: show the start)
  end
  if target < 0 then target = 0 end
  if target == leftcol then return nil end
  return target
end

--- Map a cell's last byte to the START byte of the character it belongs to — the
--- furthest position a normal-mode cursor can actually reach in that cell. Cells
--- rendered with a trailing multibyte glyph (the … truncation marker or ·NULL·)
--- have bp.finish pointing mid-character; the cursor snaps to the glyph's start,
--- so `e` (grid_col_end) must compare against this instead of bp.finish or it
--- gets stuck re-seeking the same spot. `finish` is a 0-based byte offset.
--- Pure/testable.
function M._cell_end_byte(line, finish)
  local i = finish
  local b = line:byte(i + 1)
  while i > 0 and b and b >= 0x80 and b < 0xC0 do  -- UTF-8 continuation byte (10xxxxxx)
    i = i - 1
    b = line:byte(i + 1)
  end
  return i
end

--- After the cursor has been placed on a column at byte span `bp` on line `lnum`,
--- scroll the window horizontally (if needed) so the column's right edge is
--- visible. Converts the byte span to display columns — grid lines contain
--- multibyte box-drawing chars, so bytes ≠ screen cells — and applies the offset
--- from M._reveal_leftcol via winrestview. No-op when the edge already fits.
local function reveal_col_edge(win, buf, lnum, bp)
  if not (win and bp) then return end
  local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local start_vcol = vim.fn.strdisplaywidth(line:sub(1, bp.start)) + 1
  local finish_vcol = vim.fn.strdisplaywidth(line:sub(1, bp.finish + 1))
  local wininfo = vim.fn.getwininfo(win)[1]
  if not wininfo then return end
  local textwidth = wininfo.width - wininfo.textoff
  local vw = vim.fn.winsaveview()
  -- +2: the trailing " ║" / " │ " border sits 2 display columns past the cell data
  local new_leftcol = M._reveal_leftcol(vw.leftcol, textwidth, start_vcol, finish_vcol, 2)
  if new_leftcol then
    vw.leftcol = new_leftcol
    vim.fn.winrestview(vw)
  end
end

-- ── winbar: sticky header + badges ───────────────────────────────────────
-- One writer for 'winbar'. The watch/write badges came first and keep the
-- right edge; the sticky column header (view/sticky_header.lua) fills the rest.

--- Rebuild the winbar for bufnr: sticky column header plus watch/write badges.
function M._update_winbar(bufnr)
  local session = M._sessions[bufnr]
  if not session then return end
  -- Find the window showing this buffer
  local winid
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(wid) == bufnr then winid = wid; break end
  end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end

  local badges = {}
  -- The mode of the session's own connection, not the ambient one: a grid
  -- outliving a :GripConnect must still say what it is connected to. Cached
  -- on the session because this function runs on every CursorMoved while
  -- current_mode() reads connections.json. Two things clear the cache, and
  -- between them they cover everything that can change the answer:
  -- M.render (requery, page turn, refresh) and M.invalidate_mode_cache,
  -- which connections.switch calls.
  if session._ro_mode == nil then
    session._ro_mode =
      require("dadbod-grip.connections").current_mode(session.url) == "ro"
  end
  if session._ro_mode then
    table.insert(badges, { text = "RO", hl = "GripReadonly" })
  end
  if session.watch_ms then
    local secs = session.watch_ms / 1000
    local label = secs == math.floor(secs) and tostring(math.floor(secs)) .. "s" or tostring(secs) .. "s"
    table.insert(badges, { text = "↺ " .. label, hl = "GripWatch" })
  end
  if session.write_mode then
    table.insert(badges, { text = "✎ WRITE", hl = "ErrorMsg" })
  end

  local sticky = require("dadbod-grip").get_opts().sticky_header ~= false
  local view_state = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
  -- Buffer line 2 IS the column-name row. While it is still on screen the winbar
  -- would only show it a second time, so it goes blank instead of duplicating —
  -- blank rather than unset, because unsetting drops the line and shifts the
  -- whole grid by one row exactly when scrolling crosses this threshold.
  --
  -- The "does the whole grid fit" test is not redundant with the topline one: on
  -- Neovim 0.10 a window that has not been drawn yet reports topline == the
  -- cursor line (verified against v0.10.0, the CI baseline), which reads as
  -- "scrolled" for a grid that cannot scroll at all. A buffer shorter than the
  -- window always shows its header, whatever topline claims.
  local fits_in_window =
    vim.api.nvim_buf_line_count(bufnr) <= vim.api.nvim_win_get_height(winid)
  local hdr_on_screen = fits_in_window or (view_state.topline or 1) <= 2
  local hdr_line = sticky and not hdr_on_screen and session._render
    and session._render.lines and session._render.lines[2] or nil
  local bar
  if hdr_line then
    local wininfo = vim.fn.getwininfo(winid)[1]
    -- A winbar spans the full window width, but the buffer text starts after the
    -- gutter ('number', 'signcolumn', folds). textoff is that gutter: it comes
    -- off the width AND goes back on as a leading indent, or the mirrored header
    -- renders one gutter to the left of the columns it is labelling.
    local textoff = wininfo and wininfo.textoff or 0
    local width = wininfo and (wininfo.width - textoff) or 0
    bar = require("dadbod-grip.view.sticky_header").build(
      hdr_line, view_state.leftcol or 0, width,
      M._active_col_bp(bufnr, winid), badges, textoff)
  else
    local parts = {}
    for _, b in ipairs(badges) do
      table.insert(parts, "%#" .. b.hl .. "#" .. b.text .. "%#Normal#")
    end
    bar = #parts > 0 and ("  " .. table.concat(parts, "  ")) or ""
    -- Hold the line open while the feature is on, so it neither appears nor
    -- disappears as the header scrolls in and out of view.
    if bar == "" and sticky then bar = " " end
  end
  pcall(function() vim.wo[winid].winbar = bar end)
end

--- Drop every session's cached connection mode and redraw the winbars.
---
--- connections.switch() calls this: a switch changes what current_mode()
--- answers, for the connection being switched to and for any connection whose
--- session override it just cleared. The grid in the current window is
--- replaced by the welcome screen and takes its session with it, but a grid in
--- any other window survives -- the sidebar and the query pad both hold focus
--- at switch time, and a pinned grid is skipped by find_content_win() -- and
--- would otherwise keep rendering its stale badge off the cache until its next
--- requery. A badge that says RO on a writable connection is worse than none.
function M.invalidate_mode_cache()
  for bufnr, session in pairs(M._sessions) do
    session._ro_mode = nil
    if vim.api.nvim_buf_is_valid(bufnr) then M._update_winbar(bufnr) end
  end
end

--- Start a watch timer for bufnr at interval ms. Stops any existing timer.
local function _start_watch(bufnr, ms)
  local session = M._sessions[bufnr]
  if not session then return end
  -- Stop existing timer if any
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = ms
  local timer = vim.uv.new_timer()
  session.watch_timer = timer
  timer:start(ms, ms, vim.schedule_wrap(function()
    local s = M._sessions[bufnr]
    if not s or not vim.api.nvim_buf_is_valid(bufnr) then
      pcall(function() timer:stop(); timer:close() end)
      return
    end
    -- Skip refresh when there are staged mutations pending
    local staged = s.state and (
      next(s.state.changes or {}) or
      next(s.state.deleted or {}) or
      next(s.state.inserted or {})
    )
    if staged then return end
    if s.on_refresh then s.on_refresh(bufnr) end
  end))
  M._update_winbar(bufnr)
end

--- Stop the watch timer for bufnr.
local function _stop_watch(bufnr)
  local session = M._sessions[bufnr]
  if not session then return end
  if session.watch_timer then
    pcall(function() session.watch_timer:stop(); session.watch_timer:close() end)
    session.watch_timer = nil
  end
  session.watch_ms = nil
  M._update_winbar(bufnr)
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
  -- For raw query results, embed a SQL preview so multiple results are distinguishable.
  if tbl == "result" and query_sql and query_sql ~= "" then
    local preview = query_sql:gsub("\n", " "):gsub("%s+", " "):gsub("|", "!"):sub(1, 20)
    buf_name = "grip://result [" .. preview .. "...]"
  end
  -- Ensure unique name (avoid collision with grip://query pad or duplicate table opens)
  if vim.fn.bufnr(buf_name) ~= -1 then
    buf_name = buf_name .. "#" .. bufnr
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)

  -- Register session before rendering. query_spec/total_rows are optional: a
  -- caller that already has them (init.open fetches the COUNT inside its
  -- spinner) hands them over here so the very first render can draw
  -- "Page 1/N (M rows)" instead of rendering twice.
  M._sessions[bufnr] = {
    state = state,
    url = url,
    query_sql = query_sql,
    opts = opts or {},
    hidden_columns = {},
    elapsed_ms = opts and opts.elapsed_ms or nil,
    write_mode = (opts and opts.write == true) and true or false,
    pinned = false,
    query_spec = opts and opts.query_spec or nil,
    total_rows = opts and opts.total_rows or nil,
  }

  -- Open in existing window (reuse_win) or a new horizontal split below
  local winid
  if opts and opts.reuse_win and vim.api.nvim_win_is_valid(opts.reuse_win) then
    winid = opts.reuse_win
    local prev_buf = vim.api.nvim_win_get_buf(winid)
    -- Inherit pin state before replacing (covers refresh, tab-view switches, apply).
    local prev_was_pinned = M._sessions[prev_buf] and M._sessions[prev_buf].pinned or false
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_set_current_win(winid)  -- focus grip window (Issue #3)
    if prev_was_pinned then M._sessions[bufnr].pinned = true end
    -- Clean up old grip session to prevent stale entries causing duplicate windows
    if prev_buf ~= bufnr and M._sessions[prev_buf] then
      local old_s = M._sessions[prev_buf]
      if old_s then M._close_live_sql_float(old_s) end
      M._sessions[prev_buf] = nil
      pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
    end
  else
    -- No explicit reuse_win: find the content window (grid > welcome) or create a split.
    local content_win = not (opts and opts.force_split) and M.find_content_win() or nil

    if content_win then
      winid = content_win
      local prev_buf = vim.api.nvim_win_get_buf(winid)
      -- Inherit pin state before replacing.
      local prev_was_pinned = M._sessions[prev_buf] and M._sessions[prev_buf].pinned or false
      vim.api.nvim_win_set_buf(winid, bufnr)
      vim.api.nvim_set_current_win(winid)
      if prev_was_pinned then M._sessions[bufnr].pinned = true end
      -- Clean up old grip session if we replaced a grid
      if prev_buf ~= bufnr and M._sessions[prev_buf] then
        local old_s = M._sessions[prev_buf]
        if old_s then M._close_live_sql_float(old_s) end
        M._sessions[prev_buf] = nil
        pcall(vim.api.nvim_buf_delete, prev_buf, { force = true })
      end
    else
      -- No grid or welcome screen: create a new split in the right area
      local schema_mod = require("dadbod-grip.schema")
      local right_win = schema_mod.is_open() and schema_mod.get_right_win()
      if right_win then
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("belowright split")
      else
        vim.cmd("botright split")
      end
      winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(winid, bufnr)
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

  -- Cleanup session on buffer wipe (also stops watch timer)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = _ag,
    buffer = bufnr,
    once = true,
    callback = function()
      local s = M._sessions[bufnr]
      if s then
        M._close_live_sql_float(s)
        if s.watch_timer then
          pcall(function() s.watch_timer:stop(); s.watch_timer:close() end)
          s.watch_timer = nil
        end
      end
      M._sessions[bufnr] = nil
    end,
  })

  -- Start watch timer if requested via opts; show badge for write/watch
  if (opts and opts.watch_ms) or (opts and opts.write) then
    vim.schedule(function()
      if opts.watch_ms then _start_watch(bufnr, opts.watch_ms) end
      M._update_winbar(bufnr)
    end)
  end

  return bufnr
end

-- ── JSON pretty-printer ──────────────────────────────────────────────────
-- Converts a decoded Lua value (from vim.fn.json_decode) into an indented
-- line table suitable for display floats and editor pre-fill.
-- cell_buffer.pretty_lines is the single implementation; the depth cap keeps
-- deeply nested payloads from flooding a float. Returns nil for nil input.
local MAX_JSON_DEPTH = 8
local function json_to_lines(decoded)
  if decoded == nil then return nil end  -- caller signals "no value"
  return require("dadbod-grip.cell_buffer").pretty_lines(decoded, 0, MAX_JSON_DEPTH)
end

-- Expose for testing
M._json_to_lines = json_to_lines

-- ── export formatter ─────────────────────────────────────────────────────
-- Pure function: rows is list-of-list (parallel to cols), nil values represent
-- SQL NULL. Rows may have holes, so every branch indexes `for ci = 1, #cols`
-- rather than iterating the row. Returns a list of strings (lines).
-- The single formatter behind :GripExport / gX (file), gE (clipboard) and gy
-- (markdown yank); `format` is one of csv, tsv, json, sql, markdown, grip.
local function format_export(rows, cols, format, table_name)
  local tbl = table_name or "_grip_result"

  if format == "csv" then
    local lines = { table.concat(cols, ",") }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do
        local v = row[ci]
        local s = v or ""
        if tostring(s):find('[,"\n]') then
          s = '"' .. tostring(s):gsub('"', '""') .. '"'
        end
        table.insert(parts, tostring(s))
      end
      table.insert(lines, table.concat(parts, ","))
    end
    return lines

  elseif format == "json" then
    local objects = {}
    for _, row in ipairs(rows) do
      local obj_parts = {}
      for ci, col in ipairs(cols) do
        local v = row[ci]  -- may be nil
        local json_val
        if v == nil then
          json_val = "null"
        elseif tonumber(v) then
          json_val = tostring(v)
        elseif v == "true" or v == "false" then
          json_val = v
        else
          json_val = '"' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
        end
        table.insert(obj_parts, '    "' .. col .. '": ' .. json_val)
      end
      table.insert(objects, "  {\n" .. table.concat(obj_parts, ",\n") .. "\n  }")
    end
    local lines = {}
    local json_str = "[\n" .. table.concat(objects, ",\n") .. "\n]"
    for _, l in ipairs(vim.split(json_str, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    return lines

  elseif format == "sql" then
    local sql_mod = require("dadbod-grip.sql")
    local col_list = table.concat(
      vim.tbl_map(function(c) return sql_mod.quote_ident(c) end, cols), ", ")
    local lines = {}
    for _, row in ipairs(rows) do
      local vals = {}
      for ci = 1, #cols do
        local v = row[ci]
        if v == nil then
          table.insert(vals, "NULL")
        else
          table.insert(vals, "'" .. esc(tostring(v)) .. "'")
        end
      end
      table.insert(lines, string.format(
        "INSERT INTO %s (%s) VALUES (%s);",
        sql_mod.quote_ident(tbl), col_list, table.concat(vals, ", ")))
    end
    return lines

  elseif format == "tsv" then
    local lines = { table.concat(cols, "\t") }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do table.insert(parts, row[ci] or "") end
      table.insert(lines, table.concat(parts, "\t"))
    end
    return lines

  elseif format == "markdown" then
    local function pipe_esc(s) return (tostring(s):gsub("|", "\\|")) end
    local lines = {
      "| " .. table.concat(vim.tbl_map(pipe_esc, cols), " | ") .. " |",
      "| " .. table.concat(vim.tbl_map(function() return "---" end, cols), " | ") .. " |",
    }
    for _, row in ipairs(rows) do
      local parts = {}
      for ci = 1, #cols do table.insert(parts, pipe_esc(row[ci] or "")) end
      table.insert(lines, "| " .. table.concat(parts, " | ") .. " |")
    end
    return lines

  elseif format == "grip" then
    -- Box-drawing table matching the grid style. NULL shows as the word NULL,
    -- numeric cells are right-aligned.
    local widths = {}
    for ci, col in ipairs(cols) do
      widths[ci] = vim.fn.strdisplaywidth(col)
    end
    for _, row in ipairs(rows) do
      for ci = 1, #cols do
        widths[ci] = math.max(widths[ci], vim.fn.strdisplaywidth(tostring(row[ci] or "NULL")))
      end
    end
    local rule_parts = {}
    for ci = 1, #cols do
      table.insert(rule_parts, string.rep("═", widths[ci] + 2))
    end
    local hdr_parts = {}
    for ci, col in ipairs(cols) do
      local pad = widths[ci] - vim.fn.strdisplaywidth(col)
      table.insert(hdr_parts, " " .. col .. string.rep(" ", pad) .. " ")
    end
    local lines = {
      "╔" .. table.concat(rule_parts, "╤") .. "╗",
      "║" .. table.concat(hdr_parts, "│") .. "║",
      "╠" .. table.concat(rule_parts, "╪") .. "╣",
    }
    for _, row in ipairs(rows) do
      local row_parts = {}
      for ci = 1, #cols do
        local v = row[ci]
        local display = v or "NULL"
        local pad = widths[ci] - vim.fn.strdisplaywidth(display)
        if v and tonumber(v) then
          table.insert(row_parts, " " .. string.rep(" ", pad) .. display .. " ")
        else
          table.insert(row_parts, " " .. display .. string.rep(" ", pad) .. " ")
        end
      end
      table.insert(lines, "║" .. table.concat(row_parts, "│") .. "║")
    end
    table.insert(lines, "╚" .. table.concat(rule_parts, "╧") .. "╝")
    return lines
  end

  return {}
end

-- Expose for testing
M._format_export = format_export

local function current_export_rows(session)
  local rows = {}
  local cols = session.state.columns or {}
  local ordered = session._render and session._render.ordered
  if not ordered then return session.state.rows or {}, cols end
  for _, row_idx in ipairs(ordered) do
    local row = {}
    for ci, col in ipairs(cols) do
      row[ci] = data.effective_value(session.state, row_idx, col)
    end
    rows[#rows + 1] = row
  end
  return rows, cols
end

local function matching_count(session)
  if session.total_rows ~= nil then return session.total_rows end
  if not session.query_spec then return nil, "All-row export requires a query-backed result" end
  local result, err = db.query(qmod.build_count_sql(session.query_spec), session.url)
  if not result then return nil, err or "Count query failed" end
  return tonumber(result.rows and result.rows[1] and result.rows[1][1]) or 0
end

--- Prompt for page/all scope before any format prompt, then provide the rows.
local function request_export_rows(session, destination, callback)
  vim.ui.select({ "Current page", "All matching rows" }, { prompt = "Export scope:" }, function(scope)
    if not scope then return end

    local rows, cols, count
    if scope == "All matching rows" then
      local count_err
      count, count_err = matching_count(session)
      if count == nil then
        vim.notify("Export failed: " .. tostring(count_err or "all-row count unavailable"),
          vim.log.levels.ERROR)
        return
      end
      if destination == "clipboard" and count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count > 10000 and not ui.confirm(string.format(
          "Export %d matching rows? (y/N): ", count)) then return end

      if not session.query_spec then
        vim.notify("Export failed: all-row export requires a query-backed result", vim.log.levels.ERROR)
        return
      end
      local result, err = db.query(
        qmod.build_sql(session.query_spec, { paginate = false }), session.url)
      if not result then
        vim.notify("Export failed: " .. tostring(err or "query failed"), vim.log.levels.ERROR)
        return
      end
      rows, cols = result.rows or {}, result.columns or session.state.columns or {}
      local fetched_count = #rows
      if destination == "clipboard" and fetched_count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count <= 10000 and fetched_count > 10000 and not ui.confirm(string.format(
          "Export %d matching rows? (y/N): ", fetched_count)) then return end
      count = fetched_count
    else
      rows, cols = current_export_rows(session)
      count = #rows
      if destination == "clipboard" and count > 100000 then
        vim.notify("Clipboard export is limited to 100,000 rows; export to a file instead",
          vim.log.levels.WARN)
        return
      end
      if count > 10000 and not ui.confirm(string.format(
          "Export %d rows from the current page? (y/N): ", count)) then return end
    end

    if count == 0 then
      vim.notify("No rows to export", vim.log.levels.WARN)
      return
    end
    callback(rows, cols, scope)
  end)
end

--- Stream an export to a same-directory temporary file, then atomically rename
--- it into place. Any formatter/write/rename failure removes only the temp file.
local function write_export_file(rows, cols, format, table_name, path)
  local temp = string.format("%s.grip-tmp-%d-%d", path, vim.fn.getpid(), vim.uv.hrtime())
  local file, open_err = io.open(temp, "wb")
  if not file then return nil, open_err end

  local ok, write_err = xpcall(function()
    local function write_lines(lines)
      if #lines == 0 then return end
      local wrote, err = file:write(table.concat(lines, "\n"), "\n")
      if not wrote then error(err or "write failed", 0) end
    end

    local batch_size = 1000
    if format == "json" then write_lines({ "[" }) end
    local first_batch = true
    for start = 1, #rows, batch_size do
      local batch = {}
      for i = start, math.min(start + batch_size - 1, #rows) do batch[#batch + 1] = rows[i] end
      local lines = format_export(batch, cols, format, table_name)
      if format == "csv" and not first_batch then table.remove(lines, 1) end
      if format == "json" then
        table.remove(lines, 1)
        table.remove(lines, #lines)
        if not first_batch and #lines > 0 then lines[1] = "," .. lines[1] end
      end
      write_lines(lines)
      first_batch = false
    end
    if format == "json" then write_lines({ "]" }) end
    local closed, close_err = file:close()
    if not closed then error(close_err or "close failed", 0) end
  end, debug.traceback)

  if not ok then
    pcall(function() file:close() end)
    vim.fn.delete(temp)
    return nil, write_err
  end
  local renamed, rename_err = vim.uv.fs_rename(temp, path)
  if not renamed then
    vim.fn.delete(temp)
    return nil, rename_err or "atomic rename failed"
  end
  return true
end

M._request_export_rows = request_export_rows
M._write_export_file = write_export_file

function M.export_to_clipboard(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session.state then
    vim.notify("No grip result to export", vim.log.levels.WARN)
    return
  end
  request_export_rows(session, "clipboard", function(rows, cols)
    local formats = { "CSV", "TSV", "JSON", "SQL INSERT", "Markdown", "Grip Table" }
    vim.ui.select(formats, { prompt = "Export format:" }, function(choice)
      if not choice then return end
      local ids = {
        ["CSV"] = "csv", ["TSV"] = "tsv", ["JSON"] = "json",
        ["SQL INSERT"] = "sql", ["Markdown"] = "markdown", ["Grip Table"] = "grip",
      }
      local output = table.concat(format_export(
        rows, cols, ids[choice], session.state.table_name or "table_name"), "\n")
      vim.fn.setreg("+", output)
      vim.notify(string.format("Exported %d rows as %s to clipboard", #rows, choice),
        vim.log.levels.INFO)
    end)
  end)
end

--- Export a page or all matching rows to a file.
--- Called by gX keymap and :GripExport command.
function M.do_export(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session.state then
    vim.notify("No grip result to export", vim.log.levels.WARN)
    return
  end

  request_export_rows(session, "file", function(rows, cols)
    -- Scope is intentionally chosen before format.
    local fmt = ui.input({ prompt = "Export format [csv/json/sql]: " })
    if not fmt then return end
    fmt = fmt:lower()
    if fmt ~= "csv" and fmt ~= "json" and fmt ~= "sql" then
      vim.notify("Unknown format: " .. fmt .. " (use csv, json, or sql)", vim.log.levels.ERROR)
      return
    end

    local ext = fmt == "sql" and "sql" or fmt
    local path = ui.input({
      prompt = "Save to: ",
      default = vim.fn.getcwd() .. "/grip_export." .. ext,
      completion = "file",
    })
    if not path then return end

    local ok, err = write_export_file(
      rows, cols, fmt, session.query_spec and session.query_spec.table_name, path)
    if ok then
      vim.notify(string.format("Exported %d rows → %s", #rows, path), vim.log.levels.INFO)
    else
      vim.notify("Export failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
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

  -- Editor-relative floats are centered by ui.info_float (row/col left nil).
  local row, col
  if relative == "cursor" then
    row = float_opts.row or 1
    col = float_opts.col or 0
  end

  -- Buffer is created here, not by info_float: filetype must be set before the
  -- window exists so FileType autocmds see the same state as before.
  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, flat)
  if float_opts.filetype then
    vim.api.nvim_set_option_value("filetype", float_opts.filetype, { buf = popup_buf })
  end

  local win = ui.info_float({
    buf = popup_buf,
    relative = relative,
    row = row,
    col = col,
    width = width,
    height = height,
    title = float_opts.title or "",
    title_pos = "center",
    zindex = 50,
  })

  ui.dismiss_float({ win = win, buf = popup_buf, caller_win = grip_win, group = _ag })

  return win, popup_buf
end

-- ── tab view system ──────────────────────────────────────────────────────────

-- Build a minimal read-only state table compatible with build_render.
-- rows = array of arrays matching the columns order.
local function make_meta_state(table_name, columns, rows)
  return {
    rows            = rows,
    columns         = columns,
    pks             = {},
    table_name      = table_name,
    changes         = {},
    deleted         = {},
    inserted        = {},
    _next_insert_idx = 1000,
    readonly        = true,
  }
end

-- Update the buffer name to reflect the current view.
local function update_buf_name(bufnr, table_name, view_name)
  local base = table_name or "result"
  local name
  if view_name and view_name ~= "records" then
    local full = {
      columns="Columns", fk="Foreign Keys", indexes="Indexes",
      constraints="Constraints", stats="Stats", history="History", explain="Explain",
    }
    name = "grip://" .. base .. " [" .. (full[view_name] or view_name) .. "]"
  else
    name = "grip://" .. base
  end
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

-- Per-view data fetchers. Each returns (columns, rows, err).
local function fetch_view_columns(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local cols, err = db_mod.get_column_info(table_name, url)
  if err and not cols then return nil, nil, err end
  if not cols then return nil, nil, "no column info returned" end
  local columns = { "column_name", "data_type", "nullable", "default", "key" }
  local rows = {}
  for _, c in ipairs(cols) do
    table.insert(rows, {
      c.column_name or "",
      c.data_type or "",
      c.is_nullable or "",
      (c.column_default and c.column_default ~= "") and c.column_default or "-",
      (c.constraints and c.constraints ~= "") and c.constraints or "",
    })
  end
  return columns, rows, nil
end

local function fetch_view_fk(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local fks, err = db_mod.get_foreign_keys(table_name, url)
  if err and not fks then return nil, nil, err end
  fks = fks or {}
  local columns = { "direction", "column", "ref_table", "ref_column" }
  local rows = {}
  -- Outbound: columns in this table pointing to other tables
  for _, fk in ipairs(fks) do
    table.insert(rows, { "→ outbound", fk.column or "", fk.ref_table or "", fk.ref_column or "" })
  end
  -- Inbound: other tables that reference this table. get_referencing_foreign_keys
  -- answers this in one query on every adapter that supports it (and falls back
  -- to the same list_tables + per-table scan otherwise), instead of spawning one
  -- CLI process per table in the schema. Same source as the gr keymap.
  local refs = db_mod.get_referencing_foreign_keys(table_name, url) or {}
  for _, ref in ipairs(refs) do
    -- Self-references are already listed above as outbound; don't repeat them.
    if ref.table ~= table_name then
      table.insert(rows, { "← inbound", (ref.table or "") .. "." .. (ref.column or ""), table_name, ref.ref_column or "" })
    end
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_indexes(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local indexes, err = db_mod.get_indexes(table_name, url)
  if err and not indexes then return nil, nil, err end
  indexes = indexes or {}
  local columns = { "index_name", "type", "columns" }
  local rows = {}
  for _, idx in ipairs(indexes) do
    table.insert(rows, {
      idx.name or "",
      idx.type or "INDEX",
      type(idx.columns) == "table" and table.concat(idx.columns, ", ") or (idx.columns or ""),
    })
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_constraints(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local constraints, err = db_mod.get_constraints(table_name, url)
  if err and not constraints then return nil, nil, err end
  constraints = constraints or {}
  local columns = { "constraint_name", "type", "definition" }
  local rows = {}
  for _, c in ipairs(constraints) do
    table.insert(rows, { c.name or "", c.type or "", c.definition or "" })
  end
  if #rows == 0 then
    table.insert(rows, { "(none)", "", "" })
  end
  return columns, rows, nil
end

local function fetch_view_stats(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  local cols, err = db_mod.get_column_info(table_name, url)
  if err and not cols then return nil, nil, err end
  if not cols or #cols == 0 then return nil, nil, "no columns found" end

  -- Build a UNION ALL query: one row per column with aggregate stats
  local safe_tbl = table_name:gsub('"', '""')
  local parts = {}
  for _, c in ipairs(cols) do
    local safe_col = c.column_name:gsub('"', '""')
    local quoted_col = '"' .. safe_col .. '"'
    local quoted_name = esc(c.column_name)
    parts[#parts + 1] = string.format(
      "SELECT '%s' AS col_name, COUNT(*) AS total_rows, COUNT(%s) AS non_null,"
      .. " COUNT(*) - COUNT(%s) AS null_count, COUNT(DISTINCT %s) AS distinct_count,"
      .. " CAST(MIN(%s) AS TEXT) AS min_val, CAST(MAX(%s) AS TEXT) AS max_val"
      .. " FROM \"%s\"",
      quoted_name, quoted_col, quoted_col, quoted_col, quoted_col, quoted_col, safe_tbl
    )
  end

  local stats_sql = table.concat(parts, "\nUNION ALL\n")

  local result, query_err = db_mod.query(stats_sql, url)
  if query_err then return nil, nil, "Stats query failed: " .. query_err end
  if not result then return nil, nil, "no stats result" end

  local columns = { "column", "total", "non_null", "nulls", "distinct", "min", "max" }
  local rows = {}
  for _, row in ipairs(result.rows) do
    -- row: col_name, total_rows, non_null, null_count, distinct_count, min_val, max_val
    local total = tonumber(row[2]) or 0
    local nulls = tonumber(row[4]) or 0
    local null_pct = total > 0 and string.format("%.1f%%", (nulls / total) * 100) or "-"
    table.insert(rows, {
      row[1] or "",               -- column
      tostring(total),            -- total
      tostring(row[3] or ""),     -- non_null
      null_pct,                   -- nulls (pct)
      tostring(row[5] or ""),     -- distinct
      row[6] or "-",              -- min
      row[7] or "-",              -- max
    })
  end
  return columns, rows, nil
end

local function fetch_view_explain(table_name, url, session)
  local db_mod = require("dadbod-grip.db")
  -- Use current query_sql or fall back to a simple SELECT
  local query_sql
  if session.query_spec then
    query_sql = require("dadbod-grip.query").build_sql(session.query_spec)
  elseif session.query_sql then
    query_sql = session.query_sql
  else
    query_sql = string.format('SELECT * FROM "%s" LIMIT 100', (table_name or ""):gsub('"', '""'))
  end

  local result, err = db_mod.explain(query_sql, url)
  if err then return nil, nil, "EXPLAIN failed: " .. err end
  if not result then return nil, nil, "no explain result" end

  local columns = { "query_plan" }
  local rows = {}
  for _, line in ipairs(result.lines or {}) do
    table.insert(rows, { line })
  end
  if #rows == 0 then
    table.insert(rows, { "(empty plan)" })
  end
  return columns, rows, nil
end

local VIEW_FETCHERS = {
  columns     = fetch_view_columns,
  fk          = fetch_view_fk,
  indexes     = fetch_view_indexes,
  constraints = fetch_view_constraints,
  stats       = fetch_view_stats,
  explain     = fetch_view_explain,
}

--- Switch the current grip buffer to a different view facet.
--- view_name: "records"|"columns"|"fk"|"indexes"|"constraints"|"stats"|"history"|"explain"
function M.switch_view(bufnr, view_name)
  local session = M._sessions[bufnr]
  if not session then return end

  -- Already on this view: show hint rather than silently re-fetching
  -- (history is excluded: it's a picker, re-opening it is fine)
  local actual_view = session.current_view or "records"
  if actual_view == view_name and view_name ~= "history" then
    local full_labels = {
      records = "Records", columns = "Columns", fk = "Foreign Keys",
      indexes = "Indexes", constraints = "Constraints", stats = "Stats", explain = "Explain",
    }
    local label = full_labels[view_name] or view_name
    vim.notify("Already on " .. label .. " · press 2 for Records", vim.log.levels.INFO)
    return
  end

  local table_name = session.state and session.state.table_name
  local url = session.url

  -- Tab 1 is the table picker, handled by the keymap directly (no view switch)
  if view_name == "records" then
    -- Save scroll position of current metadata view before switching back
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      session.view_cache = session.view_cache or {}
      local old_cv = session.current_view or "records"
      session.view_cache[old_cv] = { cursor = vim.api.nvim_win_get_cursor(win) }
    end
    session.current_view = "records"
    -- _records_state always holds the canonical records data
    local real_state = session._records_state or session.state
    M.render(bufnr, real_state)
    -- Restore records cursor if cached
    local cur_win = vim.fn.bufwinid(bufnr)
    if cur_win ~= -1 and session.view_cache and session.view_cache["records"] then
      pcall(vim.api.nvim_win_set_cursor, cur_win, session.view_cache["records"].cursor)
    end
    session._meta_state = nil
    update_buf_name(bufnr, table_name, nil)
    return
  end

  if not table_name then
    vim.notify("Grip: no table in focus for view switching", vim.log.levels.WARN)
    return
  end

  -- History opens the grip picker (same as gh) filtered to this table: not a grid
  if view_name == "history" then
    require("dadbod-grip.history").pick_for_table(table_name, function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
    return
  end

  -- Explain opens the Query Health popup (same as gQ): text format is far more readable than a grid
  if view_name == "explain" then
    local query_sql
    if session.query_spec then
      query_sql = require("dadbod-grip.query").build_sql(session.query_spec)
    elseif session.query_sql then
      query_sql = session.query_sql
    else
      query_sql = string.format('SELECT * FROM "%s" LIMIT 100', (table_name or ""):gsub('"', '""'))
    end
    -- Pass through nvim_cmd args: string form splits the argument on newlines
    -- (and on |), so a multi-line query pad SQL was executed as several
    -- Ex commands instead of being handed to :GripExplain.
    vim.cmd({ cmd = "GripExplain", args = { query_sql } })
    return
  end

  local fetcher = VIEW_FETCHERS[view_name]
  if not fetcher then
    vim.notify("Grip: unknown view '" .. view_name .. "'", vim.log.levels.WARN)
    return
  end

  -- Save scroll position of current view before switching
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    session.view_cache = session.view_cache or {}
    local old_cv = session.current_view or "records"
    session.view_cache[old_cv] = { cursor = vim.api.nvim_win_get_cursor(win) }
  end

  -- Preserve the canonical records state so it survives the render() call
  if not session._records_state or session.current_view == nil or session.current_view == "records" then
    session._records_state = session.state
  end

  -- Fetch view data
  local columns, rows, err = ui.blocking(
    "Loading " .. (VIEW_LABELS[view_name] or view_name) .. " for " .. table_name .. "...",
    function() return fetcher(table_name, url, session) end
  )
  if err then
    vim.notify("Grip " .. view_name .. ": " .. err, vim.log.levels.WARN)
    return
  end

  -- Build meta state and render (render sets session.state = meta_state temporarily)
  local meta_state = make_meta_state(table_name, columns, rows)
  session.current_view = view_name
  session._meta_state = meta_state  -- preserved for CR navigation (session.state is restored below)
  M.render(bufnr, meta_state)
  -- Restore the canonical records state so keymaps like `r` still work
  session.state = session._records_state

  -- Update buffer name and restore cached cursor for this view
  update_buf_name(bufnr, table_name, view_name)
  local cur_win = vim.fn.bufwinid(bufnr)
  if cur_win ~= -1 then
    if session.view_cache and session.view_cache[view_name] then
      pcall(vim.api.nvim_win_set_cursor, cur_win, session.view_cache[view_name].cursor)
    else
      -- Default: top of data
      pcall(vim.api.nvim_win_set_cursor, cur_win, { 5, 0 })
    end
  end
end

-- ── in-place navigation: query pad sync ───────────────────────────────────
--- Sync the query pad with a spec the grid just switched to.
--- init.open() syncs the pad for grids that open from outside it (sidebar, table
--- picker, :Grip). FK navigation instead swaps the spec inside an existing grid
--- and never goes through init.open(), so each in-place jump must sync itself —
--- otherwise the pad keeps advertising the table you started from, three FK hops
--- ago. clean_sql() keeps this honest: the pinned FK clause is included (the pad
--- describes the rows on screen) while sorts, user filters and pagination are not.
function M._sync_pad(spec)
  if not spec then return end
  require("dadbod-grip.query_pad").sync_query(qmod.clean_sql(spec))
end

-- ── reverse FK navigation ─────────────────────────────────────────────────
--- Jump from the current row to the rows in other tables that reference it.
--- Mirror of grid_fk_follow: same nav stack, query-spec, and render machinery.
--- Module-level (not a keymap closure) so tests can drive it directly.
function M._fk_referencing(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session.state or not session.state.table_name then
    vim.notify("Reverse FK navigation requires a table name", vim.log.levels.INFO)
    return
  end
  local tbl = session.state.table_name

  -- Compute the reverse-FK map once per session per table (mirrors fk_cache).
  if not session.rev_fk_cache then session.rev_fk_cache = {} end
  if not session.rev_fk_cache[tbl] then
    local refs, rev_err = db.get_referencing_foreign_keys(tbl, session.state.url)
    if rev_err and (not refs or #refs == 0) then
      vim.notify("Reverse FK lookup failed: " .. rev_err, vim.log.levels.WARN)
      return
    end
    session.rev_fk_cache[tbl] = refs or {}
  end
  local refs = session.rev_fk_cache[tbl]
  if #refs == 0 then
    vim.notify("No tables reference " .. tbl, vim.log.levels.INFO)
    return
  end

  local cell = M.get_cell(bufnr)
  if not cell then
    vim.notify("Move cursor to a data row", vim.log.levels.INFO)
    return
  end

  -- Source column: the cursor column if some FK references it,
  -- otherwise the row's single-column primary key.
  local referenced = {}
  for _, r in ipairs(refs) do referenced[r.ref_column] = true end
  local src_col, src_val
  if referenced[cell.col_name] then
    src_col, src_val = cell.col_name, cell.value
  else
    local pks = session.state.pks or {}
    if #pks ~= 1 then
      vim.notify(
        "No referenced column at cursor and no single-column primary key",
        vim.log.levels.INFO)
      return
    end
    src_col = pks[1]
    src_val = data.effective_value(session.state, cell.row_idx, src_col)
  end

  local candidates = {}
  for _, r in ipairs(refs) do
    if r.ref_column == src_col then table.insert(candidates, r) end
  end
  if #candidates == 0 then
    vim.notify("No tables reference " .. tbl .. "." .. src_col, vim.log.levels.INFO)
    return
  end
  -- effective_value returns nil for NULL originals, but staged INSERT rows
  -- (insert_row_with_values: GripFill, INSERT mutation preview) can carry a
  -- raw "" that it passes through — keep treating "" as NULL here.
  if src_val == nil or src_val == "" then
    vim.notify("NULL value: cannot find referencing rows", vim.log.levels.INFO)
    return
  end

  local function jump(ref)
    if ref.composite then
      vim.notify(
        "Composite foreign key " .. ref.table .. " (" .. ref.column ..
        "): reverse navigation not supported", vim.log.levels.INFO)
      return
    end

    -- Push current state to nav stack (shared with forward FK navigation)
    if not session.nav_stack then session.nav_stack = {} end
    table.insert(session.nav_stack, {
      query_spec = session.query_spec,
      state = session.state,
      table_name = tbl,
      cursor_pos = vim.api.nvim_win_get_cursor(0),
      total_rows = session.total_rows,
    })

    -- Build query for the referencing rows
    local page_size = session.query_spec and session.query_spec.page_size or 100
    local ref_spec = qmod.new_table(ref.table, page_size)
    -- Pinned: this clause is what the grid IS ("the rows referencing that row"),
    -- so F/X must not drop it and the [filtered] badge must not claim the user
    -- filtered anything.
    ref_spec = qmod.add_filter(ref_spec,
      sql.quote_ident(ref.column) .. " = " .. sql.quote_value(src_val),
      { pinned = true })
    local ref_sql = qmod.build_sql(ref_spec)

    -- Four round-trips (rows, columns, PKs, COUNT) behind one spinner: without
    -- it the jump is a dead editor for as long as the connection takes.
    -- One table out, never a bare `nil, err`: ui.blocking() forwards through
    -- table.unpack, which drops everything after a leading nil.
    local row_count
    local fetched = ui.blocking("  querying " .. ref.table .. "...", function()
      local res, qerr = db.query(ref_sql, session.state.url)
      if qerr then return { err = qerr } end

      -- Empty result: fetch columns from schema (same guard as grid_fk_follow)
      if #res.columns == 0 then
        local col_info = db.get_column_info(ref.table, session.state.url)
        if col_info then
          for _, ci in ipairs(col_info) do
            table.insert(res.columns, ci.column_name)
          end
        end
      end

      -- Fetch PKs for the referencing table
      res.primary_keys = db.get_primary_keys(ref.table, session.state.url) or {}
      -- FK navigation lands on a different table but the same connection, so a
      -- read-only one stays read-only here too.
      res.readonly = db.is_readonly(session.state.url)
      res.table_name = ref.table
      res.url = session.state.url
      res.sql = ref_sql

      -- Single cheap COUNT (after selection) for pagination + notify
      row_count = #res.rows
      local count_result = db.query(qmod.build_count_sql(ref_spec), session.state.url)
      if count_result and count_result.rows[1] then
        row_count = tonumber(count_result.rows[1][1]) or row_count
      end
      return { result = res }
    end)
    if not fetched or not fetched.result then
      table.remove(session.nav_stack) -- pop on failure
      vim.notify("Reverse FK query failed: " .. tostring((fetched and fetched.err) or "unknown error"),
        vim.log.levels.WARN)
      return
    end
    local result = fetched.result

    local new_state = data.new(result)
    session.query_spec = ref_spec
    session.total_rows = row_count
    M.render(bufnr, new_state)
    M._sync_pad(ref_spec)
    vim.notify(
      ref.table .. "." .. ref.column .. " ← " .. tbl ..
      " (" .. row_count .. (row_count == 1 and " row)" or " rows)"),
      vim.log.levels.INFO)
  end

  if #candidates == 1 then
    jump(candidates[1])
    return
  end
  require("dadbod-grip.grip_picker").pick({
    title = "Tables referencing " .. tbl .. "." .. src_col,
    items = candidates,
    display = function(c)
      return c.table .. "." .. c.column .. (c.composite and " (composite)" or "")
    end,
    on_select = jump,
  })
end

-- ── multi-cursor column set ───────────────────────────────────────────────
--- Stage the same value for the current column across ALL visible rows of the
--- current page (bulk-edit a status field without SQL or a visual selection).
--- Mirror of the visual-mode batch edit (grid_v_edit) over the rendered page:
--- rows staged as deleted are skipped, staged INSERT rows are included, and
--- rows outside the current page are never touched.
--- Module-level (not a keymap closure) so tests can drive it directly.
function M._column_set(bufnr)
  local session = M._sessions[bufnr]
  if not session or not session._render then return end
  if not is_editable(session) then
    vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
    return
  end
  local cell = M.get_cell(bufnr)
  if not cell then
    vim.notify("No cell under cursor", vim.log.levels.INFO)
    return
  end
  local col_name = cell.col_name

  -- Visible rows = exactly what the render enumerates for this page,
  -- minus rows already staged as deleted.
  local st = session.state
  local row_indices = {}
  for _, ri in ipairs(session._render.ordered) do
    if not st.deleted[ri] then table.insert(row_indices, ri) end
  end
  if #row_indices == 0 then return end

  -- Guard against accidental huge stages.
  if #row_indices > 50 then
    local choice = vim.fn.confirm(
      "Set " .. col_name .. " for " .. #row_indices .. " rows?",
      "&Yes\n&Cancel", 2
    )
    if choice ~= 1 then return end
  end

  editor.open("Set " .. #row_indices .. " rows (" .. col_name .. ")", cell.value, function(new_val)
    if new_val == nil then return end
    -- NOTE: explicit if, not `x == NULL_VALUE and nil or x` — that and/or
    -- chain short-circuits back to x when the comparison is true.
    local actual = new_val
    if new_val == editor.NULL_VALUE then actual = nil end
    local new_state = session.state
    for _, ri in ipairs(row_indices) do
      new_state = data.add_change(new_state, ri, col_name, actual)
    end
    M.apply_edit(bufnr, new_state)
    vim.notify("Set " .. #row_indices .. " rows in " .. col_name, vim.log.levels.INFO)
  end, {})
end

--- Resolve the byte-position map for any grid line, including the header and
--- the type-annotation row. Returns nil for lines past the rendered rows
--- unless `fallback` asks for the first data row (then the header) instead.
--- @param r table    session._render
--- @param line number  1-indexed buffer line
--- @param fallback? boolean
--- @return table|nil  map of column name -> { start, finish } byte offsets
local function resolve_row_bp(r, line, fallback)
  local ds = r.data_start or 4
  local di = line - ds + 1
  if di < 1 then
    if ds == 5 and line == ds - 2 then return r.type_row_byte_positions end
    return r.hdr_byte_positions
  end
  local bp = r.byte_positions and r.byte_positions[di]
  if bp then return bp end
  if fallback then
    return (r.byte_positions and r.byte_positions[1]) or r.hdr_byte_positions
  end
  return nil
end

--- Name of the column at (line, col_nr), resolved from whichever row the cursor
--- is on: a data row, the header, or the type-annotation row.
--- Always go through this rather than pairing _snap_col with hdr_byte_positions
--- by hand. The rows do not share byte offsets -- a type name truncated with "…"
--- spends 3 bytes on 1 display cell, so every column after it sits elsewhere in
--- the type row than in the header -- and four call sites open-coded that pairing
--- with three of them reading the header unconditionally, which resolved the
--- wrong column whenever the cursor was on the type row.
--- @return string|nil  column name, or nil without render state or columns
function M._resolve_col_at(r, cols, line, col_nr)
  if not r or not cols or #cols == 0 then return nil end
  local ref_bp = resolve_row_bp(r, line, true)
  if not ref_bp then return nil end
  local snap = M._snap_col(cols, ref_bp, col_nr)
  return snap and snap.col_name or nil
end

--- Byte range of the cursor's column inside the header row, for the sticky
--- header to highlight. Defined here rather than next to M._update_winbar
--- because it needs resolve_row_bp, which is declared above.
--- @return table|nil  { start, finish } from hdr_byte_positions
function M._active_col_bp(bufnr, winid)
  local session = M._sessions[bufnr]
  local r = session and session._render
  if not r or not r.hdr_byte_positions then return nil end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok then return nil end
  -- fallback: on the border/footer lines, keep labelling the column the cursor
  -- column falls in rather than dropping the highlight entirely.
  local ref_bp = resolve_row_bp(r, cursor[1], true)
  local snap = ref_bp and M._snap_col(r.visible_columns or {}, ref_bp, cursor[2]) or nil
  return snap and r.hdr_byte_positions[snap.col_name] or nil
end

-- ── keymap wiring ─────────────────────────────────────────────────────────
-- One module per keymap group under view/, each exporting setup(bufnr, ctx);
-- they all share the helper set built once by make_keymap_ctx() instead of
-- redefining it. Registration order matters: for a given lhs the last
-- vim.keymap.set() wins, so _setup_keymaps() walks KEYMAP_SECTIONS in order.
--
-- The section modules never require view.lua: this file requires them, so the
-- reverse would be a cycle. Anything they need from here rides on ctx.

--- The keymap sections, in registration order. This list IS the precedence
--- rule for a duplicated lhs, not a stylistic ordering: reordering it silently
--- changes which mapping survives. Append, do not shuffle.
local KEYMAP_SECTIONS = {
  require("dadbod-grip.view.keymaps_edit"),
  require("dadbod-grip.view.keymaps_visual_batch"),
  require("dadbod-grip.view.keymaps_inspect"),
  require("dadbod-grip.view.keymaps_nav"),
  require("dadbod-grip.view.keymaps_misc"),
  require("dadbod-grip.view.keymaps_sort_filter"),
  require("dadbod-grip.view.keymaps_fk"),
  require("dadbod-grip.view.keymaps_aggregate"),
  require("dadbod-grip.view.keymaps_schema"),
  require("dadbod-grip.view.keymaps_session"),
  require("dadbod-grip.view.keymaps_ai"),
  require("dadbod-grip.view.keymaps_results"),
  require("dadbod-grip.view.keymaps_tab_view"),
  require("dadbod-grip.view.column_highlight"),
  require("dadbod-grip.view.sticky_header"),
}

--- Helpers shared by every keymap section: the four map wrappers, the visual
--- selection row collector and the cell editor (also reached via <CR>).
--- ctx.view hands the sections this whole module; what they may reach through
--- it is spelled out at the assignment below, and M._sessions is not on that
--- list.
local function make_keymap_ctx(bufnr)
  local km = require("dadbod-grip.keymaps")
  local ctx = { km = km }

  -- Session accessor, deliberately a function: re-running a query replaces the
  -- session table wholesale, so a closure that captured the value would keep
  -- mutating a dead session. Every section must resolve it at call time.
  function ctx.session()
    return M._sessions[bufnr]
  end
  -- Same reason, plus is_editable() is file-local and unreachable once the
  -- sections live in their own modules. Named for its subject: it answers for
  -- ctx.session(), not for whatever session the caller happens to be holding.
  function ctx.session_is_editable()
    return is_editable(M._sessions[bufnr])
  end

  -- The column under the cursor, wherever the cursor is: a data row, the header
  -- or the type row. Column-scoped actions (sort, filter, stats, resize) should
  -- work from all three, and this is the only correct way to get there --
  -- pairing _snap_col with a byte-position map by hand is what got three
  -- handlers reading the header while the cursor sat on the type row.
  -- Actions that need the cell *value* still want view.get_cell(), which is
  -- nil off a data row by design.
  function ctx.cursor_column()
    local session = M._sessions[bufnr]
    local r = session and session._render
    if not r then return nil end
    local cols = r.visible_columns or (session.state and session.state.columns)
    local cursor = vim.api.nvim_win_get_cursor(0)
    return M._resolve_col_at(r, cols, cursor[1], cursor[2])
  end

  -- The view module itself. Handed over rather than require()d by the section
  -- modules: view.lua requires them at load time, so a require back would be a
  -- cycle. Injecting the table keeps the sections free of any view import.
  --
  -- Passing M whole is a shortcut, not a licence. The contract is this list of
  -- functions, and nothing else on M is part of it:
  --   render, switch_view, _snap_col, _clamp_data_line, get_cell,
  --   _cell_end_byte, apply_edit, close_all_floats, _close_live_sql_float,
  --   _update_live_sql_float, show_help, do_export, _format_export,
  --   _json_to_lines, enum_hint_values, _fk_referencing, _column_set
  -- M._sessions in particular is off limits: reaching into the registry lets a
  -- section read or mutate another buffer's session behind the accessors that
  -- exist for exactly that. Use ctx.session() for this buffer, ctx.each_session
  -- for the others.
  ctx.view = M

  -- gL/gJ need every live grid, not just this buffer's. An iterator instead of
  -- the registry table so no section has to name M._sessions.
  function ctx.each_session(fn)
    for b, s in pairs(M._sessions) do fn(b, s) end
  end

  -- File-local render/buffer helpers the sections call. Injected for the same
  -- reason as ctx.view: they are not part of the module's public surface.
  ctx.open_info_float = open_info_float
  ctx.resolve_row_bp  = resolve_row_bp
  ctx.reveal_col_edge = reveal_col_edge
  ctx.update_winbar   = M._update_winbar
  ctx.start_watch     = _start_watch
  ctx.stop_watch      = _stop_watch
  ctx.augroup         = _ag
  ctx.col_hl_ns       = _col_hl_ns
  ctx.NULL_DISPLAY    = NULL_DISPLAY
  ctx.VIEW_LABELS     = VIEW_LABELS

  function ctx.map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc, silent = true })
  end
  -- kmap: lookup action key via keymaps.lua, skip if false (user disabled)
  function ctx.kmap(action, fn, desc)
    local key = km.get(action)
    if key then ctx.map(key, fn, desc) end
  end
  function ctx.vmap(key, fn, desc)
    vim.keymap.set("x", key, fn, { buffer = bufnr, desc = desc, silent = true })
  end
  function ctx.kvmap(action, fn, desc)
    local key = km.get(action)
    if key then ctx.vmap(key, fn, desc) end
  end

  -- Helper: collect row indices from visual selection
  function ctx.get_visual_rows()
    local start_line = vim.fn.line("v")
    local end_line = vim.fn.line(".")
    if start_line > end_line then start_line, end_line = end_line, start_line end
    local session = ctx.session()
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

  -- e/i: edit cell
  function ctx.edit_cell()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
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

  return ctx
end

--- Wire all buffer-local grid keymaps and the column-highlight autocmd.
--- Section order is load bearing (see the note above make_keymap_ctx).
function M._setup_keymaps(bufnr)
  local ctx = make_keymap_ctx(bufnr)
  for _, section in ipairs(KEYMAP_SECTIONS) do
    section.setup(bufnr, ctx)
  end
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
      "  =         Cycle column width: compact → expanded → reset",
      "  $         Last column",
      "  e         Next column, land at end of cell",
      "  {/}       Prev / next modified row",
      "  <CR> / i  Edit cell under cursor (JSON cells: pretty-printed in editor)",
      "  gB        Open cell value in split buffer (JSON: ft=json; :w stages)",
      "  K         Row view (vertical transpose; JSON cells auto-expanded)",
      "  gK        JSON tree drilldown (expand/collapse keys, yank value or JSONPath)",
      "  y         Yank cell value to clipboard",
      "  Y         Yank row as CSV",
      "  gY        Yank entire table as CSV",
      "  gy        Yank table as Markdown pipe table",
      "",
      "  Sort / Filter / Pagination",
      "  s         Toggle sort on column (ASC→DESC→off)",
      "  S         Stack sort on column (stackable: press S on multiple cols for ▲1 ▼2 ▲3)",
      "  f         Quick filter by cell value",
      "  gn        Filter: column IS NULL",
      "  gF        Filter builder (=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL)",
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
      "  gV        Show CREATE TABLE DDL",
      "  gQ        Explain current query plan",
      "  gx        Open URL in current cell (http/https/ftp)",
      "  gD        Diff against another table",
      "  gE        Export to clipboard (CSV, TSV, JSON, SQL, Markdown)",
      "  gX        Export to file (csv/json/sql)  :GripExport",
      "",
      "  Tab Views (1-9)",
      "  Surface navigation (press again = secondary action):",
      "  1         Schema sidebar  (again: connections picker)",
      "  2         Query pad       (again: query history)",
      "  3         Grid / records  (again: table picker)",
      "  Depth views (consistent across grid, sidebar, query pad):",
      "  4         ER diagram: all tables and FK relationships",
      "  5         Column Stats: count, nulls%, distinct, min, max",
      "  6         Columns: name, type, nullable, default, key",
      "  7         Foreign Keys: outbound and inbound",
      "  8         Indexes: name, type, columns covered",
      "  9         Constraints: CHECK, UNIQUE, NOT NULL",
      "  (explain query plan: gQ)",
      "",
      "  Schema & Workflow",
      "  go/gT/gt  Pick table (floating picker)",
      "  gb        Schema browser (toggle/focus)",
      "  gG        ER diagram: focus current table neighborhood",
      "            ↳ <CR> on a table header to open that table",
      "            ↳ press gG again from the grid to return to the map",
      "  gO        Open as editable table (read-only → table)",
      "  gC/<C-g>  Switch database connection",
      "  gW        Toggle watch mode (auto-refresh on timer)",
      "  gL        Pin / unpin result (pinned: survives next query execution)",
      "  gJ        Result switcher (all open results, pick to focus)",
      "  g!        Toggle write mode (apply overwrites file)",
      "  Q         Welcome screen (home)",
      "  q         Open query pad",
      "  gq        Load saved query",
      "  gh        Query history browser",
      "  A         AI SQL generation",
      "  gA        AI row fill: stage 1 generated row  :GripFill N for more",
      "            ↳ context: schema DDL for <=30 tables (cols, types, PKs, FKs)",
      "            ↳ provider: ANTHROPIC_API_KEY -> OPENAI -> GEMINI -> Ollama",
      "            ↳ disable: setup({ ai = false }) skips schema pre-warm",
      "  gF        Format SQL (external tool cascade: sql-formatter, pg_format, sqlfluff)",
      "  :GripAttach  Attach external DB to DuckDB session",
      "  :GripDetach  Detach attached database",
      "  :GripOpen    Open file/HTTPS/s3:// without saving to connections",
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
        "  Connections",
        "  gc / gC     connection picker (* ok  o unknown  x fail)",
        "  T           retest file connection health (in picker)",
        "  s           save local file as named connection (in picker)",
        "  Softrear Inc. Analyst Portal\xe2\x84\xa2",
        "  :GripStart   Built-in case file (see docs/softrear-internal.md)",
        "",
        " ───────────────────────────────────────────",
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
        "  docs: jorypestorious.com/dadbod-grip-web",
      })
    else
      vim.list_extend(help, {
        "",
        "  Editing",
        "  <CR> / i  Edit cell under cursor",
        "  gB        Open cell value in split buffer (:w stages the change)",
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
        "  gd        Diff exactly 2 rows (highlights differing cells)",
        "  K         Stack selected rows in one float (vertical inspect)",
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
        "  Colors: modified=violet  deleted=red  inserted=green",
        "          negative=red  true=green  false=red",
        "          past-date=dim  url=underline",
        "",
        "  Connections",
        "  gc / gC     connection picker (* ok  o unknown  x fail)",
        "  T           retest file connection health (in picker)",
        "  s           save local file as named connection (in picker)",
        "  Softrear Inc. Analyst Portal\xe2\x84\xa2",
        "  :GripStart   Built-in case file (see docs/softrear-internal.md)",
        "",
        " ───────────────────────────────────────────",
        "",
        "  ╔═╦═╦═╗",
        '  ║d║b║g║  dadbod-grip v' .. VERSION,
        "  ╚═╩═╩═╝",
        "  docs: jorypestorious.com/dadbod-grip-web",
      })
    end
    local max_w = 0
    for _, line in ipairs(help) do max_w = math.max(max_w, #line) end
    max_w = math.max(max_w + 2, 46)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, help)
    -- Full help highlights: logo, section headers, keymap keys, separators, RO box, portal
    local ns_h = vim.api.nvim_create_namespace("grip_help_hl")
    local function hadd(ln, group, s, e)
      -- Missing or negative end column means "to the end of the line": add_highlight
      -- took col_end = -1 for that, set_extmark wants end_row = ln + 1 / end_col = 0.
      local ext = { hl_group = group }
      if e and e >= 0 then ext.end_col = e else ext.end_row, ext.end_col = ln + 1, 0 end
      vim.api.nvim_buf_set_extmark(popup_buf, ns_h, ln, s or 0, ext)
    end
    local in_ro_box = false
    for i, line in ipairs(help) do
      local ln = i - 1
      if    line:match("^    %a") then                                           hadd(ln, "Special")
      elseif line:find("╔═╦") or line:find("║d║") or line:find("╚═╩") then     hadd(ln, "Special")
      elseif line:find("┌─") then    in_ro_box = true;  hadd(ln, "DiagnosticWarn")
      elseif in_ro_box then          hadd(ln, "DiagnosticWarn"); if line:find("└──") then in_ro_box = false end
      elseif line:match("^%s+[─═]") then hadd(ln, "Comment")
      elseif line:find("\xe2\x86\xb3") then hadd(ln, "Comment")   -- ↳ continuation
      elseif line:find("Colors:")    then hadd(ln, "Comment")
      elseif line:find("Softrear Inc. Analyst Portal", 1, true) then hadd(ln, "Special")
      elseif line:find(":GripStart", 1, true) then
        local s, e = line:find(":GripStart")
        if s then hadd(ln, "Statement", s - 1, e) end
        if e then hadd(ln, "Comment",   e, -1) end
      elseif line:match("^  %S") and not line:find("%s%s", 3) then  hadd(ln, "Title")
      elseif line:match("^  %S") then
        local key_end = line:find("%s%s", 3)
        if key_end then hadd(ln, "Identifier", 2, key_end - 1) end
      end
    end
    local win = ui.info_float({
      buf = popup_buf,
      width = max_w,
      height = #help,
      title = " Help ",
      title_pos = "center",
      zindex = 50,
    })
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      group  = _ag,
      buffer = popup_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        close()
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end

    vim.keymap.set("n", "gx", function()
      local url = "https://jorypestorious.com/dadbod-grip-web"
      if vim.ui.open then
        vim.ui.open(url)
      elseif vim.fn.has("mac") == 1 then
        vim.fn.jobstart({ "open", url }, { detach = true })
      else
        vim.fn.jobstart({ "xdg-open", url }, { detach = true })
      end
    end, { buffer = popup_buf, desc = "Open docs" })
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
M._format_cell = format_cell
M._truncate_display = truncate_display

return M
