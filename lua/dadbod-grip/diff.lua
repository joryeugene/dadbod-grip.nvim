-- diff.lua — data diff engine.
-- Compares two result sets by primary key and renders differences.

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

-- ── unified diff rendering ──────────────────────────────────────────────────

local function render_unified(diff_result, left, right, columns)
  local lines = {}
  local marks = {}  -- {line, start_col, end_col, hl_group}
  local diff_line_indices = {}  -- lines that are diff rows (for ]c/[c)

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
      for ci, col in ipairs(columns) do
        local idx = col_idx_l[col] or col_idx_r[col]
        local v = idx and row[idx] or ""
        widths[col] = math.min(math.max(widths[col], vim.fn.strdisplaywidth(v)), 30)
      end
    end
  end

  -- Render header
  local function pad(s, w) return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s))) end
  local function format_row(row_data, col_idx_map, suffix)
    local parts = {}
    for _, col in ipairs(columns) do
      local idx = col_idx_map[col]
      local v = idx and row_data[idx] or ""
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

  -- Summary
  local s = diff_result.summary
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

  -- Render
  local columns = left_state.columns
  local lines, marks, diff_lines = render_unified(diff_result, left_state, right_state, columns)

  -- Add title and summary
  local summary = diff_result.summary
  local title_str = left_arg .. " vs " .. right_arg
  local summary_str = string.format(
    "%d compared | %d changed | %d only-left | %d only-right",
    summary.total, summary.changed, summary.deleted, summary.added
  )

  table.insert(lines, 1, "")
  table.insert(lines, 1, "  " .. summary_str)
  table.insert(lines, 1, "  " .. title_str)
  -- Shift marks and diff_lines by 3 (header lines added)
  for _, m in ipairs(marks) do m.line = m.line + 3 end
  for i, dl in ipairs(diff_lines) do diff_lines[i] = dl + 3 end

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
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.line - 1, m.start_col, {
      end_col = m.end_col == -1 and #(lines[m.line] or "") or m.end_col,
      hl_group = m.hl,
    })
  end

  -- Keymaps
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
  end

  map("q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, "Close diff")

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

  -- Help
  map("?", function()
    vim.notify(table.concat({
      "Diff: " .. title_str,
      "]c  next change",
      "[c  prev change",
      "q   close",
    }, "\n"), vim.log.levels.INFO)
  end, "Help")

  return bufnr
end

return M
