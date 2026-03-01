-- profile.lua -- table data profiling with sparkline distributions.
-- Shows per-column completeness, cardinality, min/max, and histogram sparklines.

local db  = require("dadbod-grip.db")
local sql = require("dadbod-grip.sql")

local M = {}

local SPARK_CHARS = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84",
                      "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" }
local MAX_COLUMNS = 20
local BUCKET_COUNT = 8

-- ── pure helpers ──────────────────────────────────────────────────────────────

--- Build a sparkline string from bucket counts.
function M.sparkline(counts, max_count)
  if not counts or #counts == 0 then return "" end
  if not max_count or max_count == 0 then
    return string.rep(SPARK_CHARS[1], #counts)
  end
  local parts = {}
  for _, c in ipairs(counts) do
    local idx = math.max(1, math.min(BUCKET_COUNT, math.ceil((c / max_count) * BUCKET_COUNT)))
    table.insert(parts, SPARK_CHARS[idx])
  end
  return table.concat(parts)
end

--- Classify a column's data type into a profiling category.
function M.classify_column(data_type)
  if not data_type then return "unknown" end
  local dt = data_type:lower()
  if dt:match("bool") then return "boolean" end
  -- Date/time must come before numeric (timestamp contains "int")
  if dt:match("date") or dt:match("time") or dt:match("interval") then return "date" end
  if dt:match("int") or dt:match("serial") or dt:match("float") or dt:match("double")
    or dt:match("real") or dt:match("numeric") or dt:match("decimal") or dt:match("money")
    or dt:match("number") or dt:match("hugeint") then
    return "numeric"
  end
  if dt:match("char") or dt:match("text") or dt:match("varchar") or dt:match("clob")
    or dt:match("string") or dt:match("name") or dt:match("uuid") or dt:match("enum")
    or dt:match("set") then
    return "text"
  end
  return "unknown"
end

-- ── SQL generation ────────────────────────────────────────────────────────────

--- Build a batched stats query for multiple columns.
--- Returns one row with interleaved per-column stats.
function M.build_stats_sql(table_name, col_infos)
  local tbl = sql.quote_ident(table_name)
  local parts = { "(SELECT COUNT(*) FROM " .. tbl .. ") AS _total" }
  for i, ci in ipairs(col_infos) do
    local col = sql.quote_ident(ci.column_name)
    local cat = M.classify_column(ci.data_type)
    table.insert(parts, string.format("(SELECT COUNT(DISTINCT %s) FROM %s) AS _d%d", col, tbl, i))
    table.insert(parts, string.format("(SELECT COUNT(*) - COUNT(%s) FROM %s) AS _n%d", col, tbl, i))
    table.insert(parts, string.format("(SELECT MIN(%s) FROM %s) AS _min%d", col, tbl, i))
    table.insert(parts, string.format("(SELECT MAX(%s) FROM %s) AS _max%d", col, tbl, i))
    if cat == "numeric" then
      table.insert(parts, string.format("(SELECT AVG(CAST(%s AS REAL)) FROM %s) AS _avg%d", col, tbl, i))
    end
  end
  return "SELECT " .. table.concat(parts, ", ")
end

--- Build a histogram query for one column.
function M.build_histogram_sql(table_name, col_name, col_type, min_val, max_val)
  local tbl = sql.quote_ident(table_name)
  local col = sql.quote_ident(col_name)

  if col_type == "text" or col_type == "boolean" or col_type == "unknown" then
    return string.format(
      "SELECT %s AS val, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL GROUP BY %s ORDER BY cnt DESC LIMIT %d",
      col, tbl, col, col, BUCKET_COUNT
    )
  end

  -- Numeric or date: build CASE WHEN buckets
  if not min_val or not max_val or min_val == max_val then
    return string.format(
      "SELECT %s AS val, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL GROUP BY %s ORDER BY cnt DESC LIMIT %d",
      col, tbl, col, col, BUCKET_COUNT
    )
  end

  local min_n = tonumber(min_val)
  local max_n = tonumber(max_val)
  if not min_n or not max_n then
    -- Non-numeric min/max (dates): fall back to GROUP BY
    return string.format(
      "SELECT %s AS val, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL GROUP BY %s ORDER BY cnt DESC LIMIT %d",
      col, tbl, col, col, BUCKET_COUNT
    )
  end

  local step = (max_n - min_n) / BUCKET_COUNT
  local cases = {}
  for b = 1, BUCKET_COUNT - 1 do
    table.insert(cases, string.format("WHEN CAST(%s AS REAL) < %s THEN %d", col, min_n + step * b, b))
  end
  table.insert(cases, "ELSE " .. BUCKET_COUNT)

  return string.format(
    "SELECT CASE %s END AS bucket, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL GROUP BY bucket ORDER BY bucket",
    table.concat(cases, " "), tbl, col
  )
end

-- ── data gathering ────────────────────────────────────────────────────────────

--- Gather profile data for all columns of a table.
function M.gather(table_name, url)
  -- Get column info
  local col_infos, col_err = db.get_column_info(table_name, url)
  if not col_infos or #col_infos == 0 then
    return nil, col_err or "No column info for " .. table_name
  end

  -- Limit columns
  local limited = {}
  for i = 1, math.min(#col_infos, MAX_COLUMNS) do
    table.insert(limited, col_infos[i])
  end

  -- Fetch batched stats
  local stats_sql = M.build_stats_sql(table_name, limited)
  local stats_result, stats_err = db.query(stats_sql, url)
  if not stats_result or #stats_result.rows == 0 then
    return nil, stats_err or "Stats query returned no data"
  end

  local stats_row = stats_result.rows[1]
  local total = tonumber(stats_row[1]) or 0

  -- Parse per-column stats from the batched result
  local profiles = {}
  local col_offset = 2  -- first column is _total
  for i, ci in ipairs(limited) do
    local cat = M.classify_column(ci.data_type)
    local distinct = tonumber(stats_row[col_offset]) or 0
    local nulls = tonumber(stats_row[col_offset + 1]) or 0
    local min_val = stats_row[col_offset + 2] or ""
    local max_val = stats_row[col_offset + 3] or ""
    local mean = nil
    local field_count = 4
    if cat == "numeric" then
      mean = stats_row[col_offset + 4]
      field_count = 5
    end
    col_offset = col_offset + field_count

    local non_null = total - nulls
    local completeness = total > 0 and (non_null / total * 100) or 0
    local cardinality = non_null > 0 and (distinct / non_null) or 0

    table.insert(profiles, {
      name = ci.column_name,
      data_type = ci.data_type or "unknown",
      category = cat,
      total = total,
      distinct = distinct,
      nulls = nulls,
      completeness = completeness,
      cardinality = cardinality * 100,
      min = min_val,
      max = max_val,
      mean = mean,
      histogram = nil,
      top_values = nil,
    })
  end

  -- Fetch histograms per column
  for i, p in ipairs(profiles) do
    local hist_sql = M.build_histogram_sql(table_name, p.name, p.category, p.min, p.max)
    local hist_result = db.query(hist_sql, url)
    if hist_result and #hist_result.rows > 0 then
      if p.category == "text" or p.category == "boolean" or p.category == "unknown"
        or (p.category == "numeric" and (not tonumber(p.min) or p.min == p.max)) then
        -- Categorical: store as top_values and build sparkline from counts
        local top = {}
        local counts = {}
        for _, row in ipairs(hist_result.rows) do
          table.insert(top, { value = row[1], count = tonumber(row[2]) or 0 })
          table.insert(counts, tonumber(row[2]) or 0)
        end
        profiles[i].top_values = top
        local max_c = 0
        for _, c in ipairs(counts) do max_c = math.max(max_c, c) end
        profiles[i].histogram = M.sparkline(counts, max_c)
      else
        -- Bucketed: fill BUCKET_COUNT slots
        local buckets = {}
        for b = 1, BUCKET_COUNT do buckets[b] = 0 end
        for _, row in ipairs(hist_result.rows) do
          local b = tonumber(row[1]) or 1
          b = math.max(1, math.min(BUCKET_COUNT, b))
          buckets[b] = tonumber(row[2]) or 0
        end
        local max_c = 0
        for _, c in ipairs(buckets) do max_c = math.max(max_c, c) end
        profiles[i].histogram = M.sparkline(buckets, max_c)
      end
    end
  end

  return {
    table_name = table_name,
    column_count = #col_infos,
    shown_count = #limited,
    total_rows = total,
    profiles = profiles,
  }
end

-- ── display rendering ─────────────────────────────────────────────────────────

--- Format a percentage with one decimal place.
local function fmt_pct(v) return string.format("%.1f%%", v) end

--- Pad or truncate a string to a fixed width.
local function pad(s, w)
  local sw = vim.fn.strdisplaywidth(s)
  if sw >= w then return s:sub(1, w) end
  return s .. string.rep(" ", w - sw)
end

--- Build display lines for the profile buffer.
function M.build_lines(profile_data, term_width)
  if not profile_data then return {}, {} end

  local lines = {}
  local marks = {}
  local ns_name = "grip_profile"

  local function add(s) table.insert(lines, s) end
  local function mark(hl)
    table.insert(marks, { line = #lines, hl = hl })
  end

  local pd = profile_data
  local truncated = pd.shown_count < pd.column_count
  local header = "  Table Profile: " .. pd.table_name
    .. " (" .. pd.column_count .. " columns, ~" .. pd.total_rows .. " rows)"
  if truncated then
    header = header .. " [showing first " .. pd.shown_count .. "]"
  end
  add(header)
  add("")

  local wide = (term_width or 80) >= 80

  if wide then
    -- Tabular layout
    local nw, cw, tw, pw, dw, mnw, mxw = 2, 0, 0, 8, 8, 6, 6
    for _, p in ipairs(pd.profiles) do
      cw = math.max(cw, vim.fn.strdisplaywidth(p.name))
      tw = math.max(tw, vim.fn.strdisplaywidth(p.data_type))
      mnw = math.max(mnw, vim.fn.strdisplaywidth(p.min))
      mxw = math.max(mxw, vim.fn.strdisplaywidth(p.max))
    end
    cw = math.min(cw, 20)
    tw = math.min(tw, 14)
    mnw = math.min(mnw, 12)
    mxw = math.min(mxw, 12)

    add("  " .. pad("#", nw) .. "  " .. pad("Column", cw) .. "  " .. pad("Type", tw)
      .. "  " .. pad("Complete", pw) .. "  " .. pad("Distinct", dw)
      .. "  " .. pad("Min", mnw) .. "  " .. pad("Max", mxw) .. "  Dist")
    add("  " .. string.rep("-", nw) .. "  " .. string.rep("-", cw) .. "  " .. string.rep("-", tw)
      .. "  " .. string.rep("-", pw) .. "  " .. string.rep("-", dw)
      .. "  " .. string.rep("-", mnw) .. "  " .. string.rep("-", mxw) .. "  " .. string.rep("-", 8))
    mark("GripProfileHeader")

    for i, p in ipairs(pd.profiles) do
      local min_s = p.min:sub(1, mnw)
      local max_s = p.max:sub(1, mxw)
      local spark = p.histogram or ""
      local line = "  " .. pad(tostring(i), nw)
        .. "  " .. pad(p.name, cw)
        .. "  " .. pad(p.data_type, tw)
        .. "  " .. pad(fmt_pct(p.completeness), pw)
        .. "  " .. pad(fmt_pct(p.cardinality), dw)
        .. "  " .. pad(min_s, mnw)
        .. "  " .. pad(max_s, mxw)
        .. "  " .. spark
      add(line)

      -- Color by completeness
      if p.completeness < 50 then mark("DiagnosticError")
      elseif p.completeness < 90 then mark("DiagnosticWarn")
      end
    end

    -- Top values section
    local has_top = false
    for _, p in ipairs(pd.profiles) do
      if p.top_values and #p.top_values > 0 and p.category ~= "numeric" then
        has_top = true
        break
      end
    end

    if has_top then
      add("")
      add("  Top Values")
      add("  " .. string.rep("-", nw) .. "  " .. string.rep("-", cw) .. "  " .. string.rep("-", 40))
      mark("GripProfileHeader")

      for i, p in ipairs(pd.profiles) do
        if p.top_values and #p.top_values > 0 and p.category ~= "numeric" then
          local tv_parts = {}
          for _, tv in ipairs(p.top_values) do
            table.insert(tv_parts, tv.value .. " (" .. tv.count .. ")")
          end
          add("  " .. pad(tostring(i), nw) .. "  " .. pad(p.name, cw) .. "  " .. table.concat(tv_parts, "  "))
        end
      end
    end
  else
    -- Narrow (stacked) layout
    for i, p in ipairs(pd.profiles) do
      add("  " .. i .. ". " .. p.name .. " (" .. p.data_type .. ")")
      mark("GripProfileHeader")

      local stats_line = "     Complete: " .. fmt_pct(p.completeness)
        .. "  Distinct: " .. fmt_pct(p.cardinality)
      add(stats_line)

      if p.category == "numeric" and p.min ~= "" then
        local range_line = "     Range: " .. p.min .. " .. " .. p.max
        if p.mean then
          local mean_f = tonumber(p.mean)
          if mean_f then
            range_line = range_line .. "  Mean: " .. string.format("%.1f", mean_f)
          end
        end
        add(range_line)
      elseif p.top_values and #p.top_values > 0 then
        local tv_parts = {}
        for j = 1, math.min(3, #p.top_values) do
          local tv = p.top_values[j]
          table.insert(tv_parts, tv.value .. " (" .. tv.count .. ")")
        end
        add("     Top: " .. table.concat(tv_parts, ", "))
      end

      if p.histogram and p.histogram ~= "" then
        add("     " .. p.histogram)
      end
      add("")
    end
  end

  return lines, marks
end

-- ── buffer display ────────────────────────────────────────────────────────────

local function ensure_profile_highlights()
  if vim.fn.hlID("GripProfileHeader") == 0 then
    vim.cmd("hi GripProfileHeader gui=bold ctermfg=75 guifg=#89b4fa")
  end
end

--- Open a profiling report for a table.
function M.open(table_name, url)
  ensure_profile_highlights()

  vim.notify("Profiling " .. table_name .. "...", vim.log.levels.INFO)

  local data, err = M.gather(table_name, url)
  if not data then
    vim.notify("GripProfile: " .. (err or "failed"), vim.log.levels.ERROR)
    return
  end

  local lines, marks = M.build_lines(data, vim.o.columns)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_buf_set_name, bufnr, "grip://profile/" .. table_name)

  vim.cmd("botright split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_height(winid, math.min(30, #lines + 2))
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  -- Highlights
  local ns = vim.api.nvim_create_namespace("grip_profile")
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.line - 1, 0, {
      end_col = #(lines[m.line] or ""),
      hl_group = m.hl,
    })
  end

  -- Keymaps
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
  end

  map("q", function() vim.api.nvim_buf_delete(bufnr, { force = true }) end, "Close profile")
  map("<Esc>", function() vim.api.nvim_buf_delete(bufnr, { force = true }) end, "Close profile")
  map("r", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    M.open(table_name, url)
  end, "Refresh profile")

  return bufnr
end

return M
