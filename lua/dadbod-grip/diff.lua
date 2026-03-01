-- diff.lua -- data diff engine.
-- Compares two result sets by primary key and renders differences.
-- Supports wide (columnar) and compact (stacked key-value) modes.

local db   = require("dadbod-grip.db")
local data = require("dadbod-grip.data")
local sql  = require("dadbod-grip.sql")

local M = {}

-- ── diff computation (pure) ─────────────────────────────────────────────────

--- Build a PK -> row_idx lookup map from a state's rows.
local function pk_index(state)
  local col_idx = {}
  for i, col in ipairs(state.columns) do col_idx[col] = i end

  local map = {}
  for row_i = 1, #state.rows do
    local pk_parts = {}
    for _, pk in ipairs(state.pks) do
      local idx = col_idx[pk]
      table.insert(pk_parts, idx and state.rows[row_i][idx] or "")
    end
    local pk_key = table.concat(pk_parts, "\0")
    map[pk_key] = row_i
  end
  return map, col_idx
end

--- Compute diff between two states that share the same columns and PKs.
--- Returns: { matched, left_only, right_only, summary }
function M.compute(left, right)
  if #left.pks == 0 then
    return nil, "Diff requires primary keys to match rows"
  end

  local left_pk_map, left_col_idx = pk_index(left)
  local right_pk_map, right_col_idx = pk_index(right)

  local matched = {}
  local left_only = {}
  local right_only = {}
  local changed_count = 0

  -- Check all left rows against right
  local seen_pks = {}
  for pk_key, left_row in pairs(left_pk_map) do
    seen_pks[pk_key] = true
    local right_row = right_pk_map[pk_key]
    if right_row then
      -- Present in both: compare cells
      local diffs = {}
      for _, col in ipairs(left.columns) do
        local li = left_col_idx[col]
        local ri = right_col_idx[col]
        local lv = li and left.rows[left_row][li] or ""
        local rv = ri and right.rows[right_row][ri] or ""
        if lv ~= rv then
          diffs[col] = { left = lv, right = rv }
        end
      end
      if next(diffs) then
        changed_count = changed_count + 1
      end
      table.insert(matched, {
        pk_key = pk_key,
        left_row = left_row,
        right_row = right_row,
        diffs = diffs,
        has_diffs = next(diffs) ~= nil,
      })
    else
      table.insert(left_only, { pk_key = pk_key, row = left_row })
    end
  end

  -- Check right rows not in left
  for pk_key, right_row in pairs(right_pk_map) do
    if not seen_pks[pk_key] then
      table.insert(right_only, { pk_key = pk_key, row = right_row })
    end
  end

  -- Sort for deterministic display
  table.sort(matched, function(a, b) return a.left_row < b.left_row end)
  table.sort(left_only, function(a, b) return a.row < b.row end)
  table.sort(right_only, function(a, b) return a.row < b.row end)

  return {
    matched = matched,
    left_only = left_only,
    right_only = right_only,
    summary = {
      total = #matched + #left_only + #right_only,
      changed = changed_count,
      same = #matched - changed_count,
      added = #right_only,
      deleted = #left_only,
    },
  }, nil
end

-- ── highlight groups ────────────────────────────────────────────────────────

local function ensure_diff_highlights()
  local groups = {
    GripDiffChanged = "gui=bold ctermfg=229 guifg=#f9e2af",
    GripDiffAdded   = "gui=bold ctermfg=113 guifg=#a6e3a1",
    GripDiffDeleted = "gui=bold ctermfg=203 guifg=#f38ba8",
    GripDiffSep     = "gui=bold ctermfg=243 guifg=#6c7086",
  }
  for name, attrs in pairs(groups) do
    if vim.fn.hlID(name) == 0 then
      vim.cmd("hi " .. name .. " " .. attrs)
    end
  end
end

-- ── wide (columnar) diff rendering ──────────────────────────────────────────

--- Shrink column widths proportionally if total exceeds available width.
local function adjust_widths(widths, columns, avail_width)
  local overhead = 2 + (#columns - 1) * 3 + 12  -- prefix + separators + suffix
  local total = overhead
  for _, col in ipairs(columns) do total = total + widths[col] end
  if total <= avail_width then return end
  local content_w = total - overhead
  local target = avail_width - overhead
  if target < #columns * 6 then target = #columns * 6 end
  local ratio = target / content_w
  for _, col in ipairs(columns) do
    widths[col] = math.max(6, math.floor(widths[col] * ratio))
  end
end

local function render_unified(diff_result, left, right, columns, avail_width)
  local lines = {}
  local marks = {}
  local diff_line_indices = {}

  local function add(s) table.insert(lines, s) end
  local function add_mark(hl, sc, ec)
    table.insert(marks, { line = #lines, hl = hl, start_col = sc or 0, end_col = ec or -1 })
  end

  -- Calculate column widths from both result sets
  local widths = {}
  for _, col in ipairs(columns) do
    widths[col] = math.min(vim.fn.strdisplaywidth(col), 30)
  end
  local col_idx_l, col_idx_r = {}, {}
  for i, col in ipairs(left.columns) do col_idx_l[col] = i end
  for i, col in ipairs(right.columns) do col_idx_r[col] = i end

  for _, rows in ipairs({ left.rows, right.rows }) do
    for _, row in ipairs(rows) do
      for _, col in ipairs(columns) do
        local idx = col_idx_l[col] or col_idx_r[col]
        local v = idx and row[idx] or ""
        widths[col] = math.min(math.max(widths[col], vim.fn.strdisplaywidth(v)), 30)
      end
    end
  end

  -- Shrink columns if too wide for the terminal
  if avail_width then
    adjust_widths(widths, columns, avail_width)
  end

  -- Render header
  local function pad(s, w) return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s))) end
  local function format_row(row_data, col_idx_map, suffix)
    local parts = {}
    for _, col in ipairs(columns) do
      local idx = col_idx_map[col]
      local v = idx and row_data[idx] or ""
      if vim.fn.strdisplaywidth(v) > widths[col] then
        v = v:sub(1, widths[col] - 1) .. "~"
      end
      table.insert(parts, pad(v, widths[col]))
    end
    local line = "  " .. table.concat(parts, " | ")
    if suffix then line = line .. "  " .. suffix end
    return line
  end

  local function format_header()
    local parts = {}
    for _, col in ipairs(columns) do
      table.insert(parts, pad(col, widths[col]))
    end
    return "  " .. table.concat(parts, " | ")
  end

  add(format_header())
  add("  " .. string.rep("-", #lines[1] - 2))

  -- Changed rows (show left then right)
  for _, m in ipairs(diff_result.matched) do
    if m.has_diffs then
      add(format_row(left.rows[m.left_row], col_idx_l, "(current)"))
      add_mark("GripDiffChanged", 0, -1)
      table.insert(diff_line_indices, #lines)
      add(format_row(right.rows[m.right_row], col_idx_r, "(was)"))
      add_mark("GripDiffDeleted", 0, -1)
    end
  end

  -- Deleted rows (only in left)
  for _, d in ipairs(diff_result.left_only) do
    add(format_row(left.rows[d.row], col_idx_l, "(deleted)"))
    add_mark("GripDiffDeleted", 0, -1)
    table.insert(diff_line_indices, #lines)
  end

  -- Added rows (only in right)
  for _, a in ipairs(diff_result.right_only) do
    add(format_row(right.rows[a.row], col_idx_r, "(added)"))
    add_mark("GripDiffAdded", 0, -1)
    table.insert(diff_line_indices, #lines)
  end

  -- Same rows (unchanged) - skip for brevity
  local same_count = diff_result.summary.same
  if same_count > 0 then
    add("")
    add("  ... " .. same_count .. " unchanged row(s) hidden")
  end

  return lines, marks, diff_line_indices
end

-- ── compact (stacked key-value) diff rendering ──────────────────────────────

local function render_compact(diff_result, left, right, columns)
  local lines = {}
  local marks = {}
  local diff_line_indices = {}

  local col_idx_l, col_idx_r = {}, {}
  for i, col in ipairs(left.columns) do col_idx_l[col] = i end
  for i, col in ipairs(right.columns) do col_idx_r[col] = i end

  local function add(s) table.insert(lines, s) end
  local function add_mark(hl, sc, ec)
    table.insert(marks, { line = #lines, hl = hl, start_col = sc or 0, end_col = ec or -1 })
  end

  -- Find max column name width for alignment
  local max_name_w = 0
  for _, col in ipairs(columns) do
    max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col))
  end

  local function pad_name(name)
    return name .. string.rep(" ", max_name_w - vim.fn.strdisplaywidth(name))
  end

  -- PK lookup
  local pk_set = {}
  for _, pk in ipairs(left.pks) do pk_set[pk] = true end

  -- Changed rows
  for _, m in ipairs(diff_result.matched) do
    if m.has_diffs then
      add("  -- Row (changed) " .. string.rep("-", 30))
      add_mark("GripDiffSep", 0, -1)
      table.insert(diff_line_indices, #lines)

      for _, col in ipairs(columns) do
        local li = col_idx_l[col]
        local ri = col_idx_r[col]
        local lv = li and left.rows[m.left_row][li] or ""
        local rv = ri and right.rows[m.right_row][ri] or ""

        if m.diffs[col] then
          add("  " .. pad_name(col) .. "  " .. rv .. "  ->  " .. lv)
          add_mark("GripDiffChanged", 0, -1)
        elseif pk_set[col] then
          add("  " .. pad_name(col) .. "  " .. lv)
        end
      end
      add("")
    end
  end

  -- Deleted rows (only in left/current)
  for _, d in ipairs(diff_result.left_only) do
    add("  -- Row (deleted) " .. string.rep("-", 30))
    add_mark("GripDiffDeleted", 0, -1)
    table.insert(diff_line_indices, #lines)
    for _, col in ipairs(columns) do
      local li = col_idx_l[col]
      local v = li and left.rows[d.row][li] or ""
      add("  " .. pad_name(col) .. "  " .. v)
      add_mark("GripDiffDeleted", 0, -1)
    end
    add("")
  end

  -- Added rows (only in right)
  for _, a in ipairs(diff_result.right_only) do
    add("  -- Row (added) " .. string.rep("-", 30))
    add_mark("GripDiffAdded", 0, -1)
    table.insert(diff_line_indices, #lines)
    for _, col in ipairs(columns) do
      local ri = col_idx_r[col]
      local v = ri and right.rows[a.row][ri] or ""
      add("  " .. pad_name(col) .. "  " .. v)
      add_mark("GripDiffAdded", 0, -1)
    end
    add("")
  end

  -- Same rows summary
  local same_count = diff_result.summary.same
  if same_count > 0 then
    add("  ... " .. same_count .. " unchanged row(s) hidden")
  end

  return lines, marks, diff_line_indices
end

-- ── open diff buffer ────────────────────────────────────────────────────────

function M.open(left_arg, right_arg, url)
  ensure_diff_highlights()

  if not url then
    url = db.get_url()
    if not url then
      vim.notify("GripDiff: no database connection", vim.log.levels.WARN)
      return
    end
  end

  -- Build queries for both sides
  local left_sql = "SELECT * FROM " .. sql.quote_ident(left_arg)
  local right_sql = "SELECT * FROM " .. sql.quote_ident(right_arg)

  -- Fetch both datasets
  local left_result, left_err = db.query(left_sql, url)
  if not left_result then
    vim.notify("GripDiff: left query failed: " .. (left_err or "unknown"), vim.log.levels.ERROR)
    return
  end

  local right_result, right_err = db.query(right_sql, url)
  if not right_result then
    vim.notify("GripDiff: right query failed: " .. (right_err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- Fetch PKs for the left table (used for matching)
  local pks, _ = db.get_primary_keys(left_arg, url)
  if not pks or #pks == 0 then
    vim.notify("GripDiff: no primary key on " .. left_arg .. " (needed for row matching)", vim.log.levels.ERROR)
    return
  end

  left_result.primary_keys = pks
  left_result.table_name = left_arg
  right_result.primary_keys = pks
  right_result.table_name = right_arg

  local left_state = data.new(left_result)
  local right_state = data.new(right_result)

  -- Compute diff
  local diff_result, diff_err = M.compute(left_state, right_state)
  if not diff_result then
    vim.notify("GripDiff: " .. (diff_err or "diff failed"), vim.log.levels.ERROR)
    return
  end

  local columns = left_state.columns
  local summary = diff_result.summary
  local title_str = left_arg .. " vs " .. right_arg
  local summary_str = string.format(
    "%d compared | %d changed | %d only-left | %d only-right",
    summary.total, summary.changed, summary.deleted, summary.added
  )

  -- Auto-detect mode based on terminal width
  local use_compact = vim.o.columns < 120

  -- Render function for either mode
  local function do_render(compact)
    local r_lines, r_marks, r_diff_lines
    if compact then
      r_lines, r_marks, r_diff_lines = render_compact(diff_result, left_state, right_state, columns)
    else
      r_lines, r_marks, r_diff_lines = render_unified(diff_result, left_state, right_state, columns, vim.o.columns)
    end
    -- Prepend title and summary (3 header lines)
    table.insert(r_lines, 1, "")
    table.insert(r_lines, 1, "  " .. summary_str)
    table.insert(r_lines, 1, "  " .. title_str)
    for _, m in ipairs(r_marks) do m.line = m.line + 3 end
    for i, dl in ipairs(r_diff_lines) do r_diff_lines[i] = dl + 3 end
    return r_lines, r_marks, r_diff_lines
  end

  local lines, marks, diff_lines = do_render(use_compact)

  -- Create buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_buf_set_name, bufnr, "grip://diff")

  -- Open in split
  vim.cmd("botright split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_height(winid, math.min(30, #lines + 2))
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("grip_diff")
  local function apply_highlights(hl_lines, hl_marks)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for _, m in ipairs(hl_marks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.line - 1, m.start_col, {
        end_col = m.end_col == -1 and #(hl_lines[m.line] or "") or m.end_col,
        hl_group = m.hl,
      })
    end
  end
  apply_highlights(lines, marks)

  -- Keymaps
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
  end

  local function close_diff()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  map("q", close_diff, "Close diff")
  map("<Esc>", close_diff, "Close diff")

  -- ]c / [c: navigate between diff rows
  map("]c", function()
    local row = vim.api.nvim_win_get_cursor(winid)[1]
    for _, dl in ipairs(diff_lines) do
      if dl > row then
        pcall(vim.api.nvim_win_set_cursor, winid, { dl, 0 })
        return
      end
    end
    vim.notify("No more changes", vim.log.levels.INFO)
  end, "Next change")

  map("[c", function()
    local row = vim.api.nvim_win_get_cursor(winid)[1]
    for i = #diff_lines, 1, -1 do
      if diff_lines[i] < row then
        pcall(vim.api.nvim_win_set_cursor, winid, { diff_lines[i], 0 })
        return
      end
    end
    vim.notify("No previous changes", vim.log.levels.INFO)
  end, "Previous change")

  -- gv: toggle between compact and wide mode
  map("gv", function()
    use_compact = not use_compact
    local new_lines, new_marks, new_diff_lines = do_render(use_compact)

    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

    apply_highlights(new_lines, new_marks)

    -- Update mutable state for navigation
    diff_lines = new_diff_lines
    lines = new_lines

    vim.api.nvim_win_set_height(winid, math.min(30, #new_lines + 2))

    local mode_name = use_compact and "compact" or "wide"
    vim.notify("Diff: " .. mode_name .. " mode", vim.log.levels.INFO)
  end, "Toggle compact/wide diff")

  -- Help
  map("?", function()
    vim.notify(table.concat({
      "Diff: " .. title_str,
      "]c  next change",
      "[c  prev change",
      "gv  toggle compact/wide",
      "q   close",
    }, "\n"), vim.log.levels.INFO)
  end, "Help")

  return bufnr
end

-- Exposed for testing
M._render_unified = render_unified
M._render_compact = render_compact
M._adjust_widths = adjust_widths

return M
