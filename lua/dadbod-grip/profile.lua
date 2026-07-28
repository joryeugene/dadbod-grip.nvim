-- profile.lua -- table data profiling with sparkline distributions.
-- Shows per-column completeness, cardinality, min/max, and histogram sparklines.

local db  = require("dadbod-grip.db")
local sql = require("dadbod-grip.sql")
local ui  = require("dadbod-grip.ui")

local M = {}

local SPARK_CHARS = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84",
                      "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" }
-- Horizontal bars: a full block plus the seven eighth-width blocks, so a bar
-- resolves to 1/8 of a cell instead of a whole one.
local HBAR_FULL = "\xe2\x96\x88"
local HBAR_FRAC = { "\xe2\x96\x8f", "\xe2\x96\x8e", "\xe2\x96\x8d", "\xe2\x96\x8c",
                    "\xe2\x96\x8b", "\xe2\x96\x8a", "\xe2\x96\x89" }
local MAX_COLUMNS = 20
local BUCKET_COUNT = 8
local HBAR_WIDTH = 16      -- display cells a full-scale bar occupies
local HBAR_LABEL_MAX = 30  -- widest bucket/value label; matches the popup's old cut

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

--- Build a horizontal bar `width` display cells wide at full scale.
--- A non-zero count never renders as empty: anything that would round below one
--- eighth still gets the thinnest block. One row out of ten million has to stay
--- visible, otherwise it is indistinguishable from an empty bucket.
function M.hbar(count, max_count, width)
  width = width or HBAR_WIDTH
  local c = tonumber(count) or 0
  local mx = tonumber(max_count) or 0
  if c <= 0 or mx <= 0 or width <= 0 then return "" end

  local eighths = math.floor((c / mx) * width * 8 + 0.5)
  eighths = math.max(1, math.min(width * 8, eighths))
  local bar = string.rep(HBAR_FULL, math.floor(eighths / 8))
  local rem = eighths % 8
  if rem > 0 then bar = bar .. HBAR_FRAC[rem] end
  return bar
end

--- The BUCKET_COUNT ranges a numeric histogram spans, or nil when the column
--- cannot be bucketed at all (missing, equal or non-numeric bounds -- a date
--- whose MIN is a timestamp string lands here).
--- Buckets are half-open [lo, hi) except the last, whose hi is max_val and is
--- inclusive, because build_histogram_sql emits it as the CASE's ELSE arm.
--- This is the single source of truth for the step: the SQL thresholds and the
--- labels in the gS popup are both generated from it, so they cannot drift.
function M.bucket_bounds(min_val, max_val)
  if not min_val or not max_val or min_val == max_val then return nil end
  local min_n, max_n = tonumber(min_val), tonumber(max_val)
  if not min_n or not max_n then return nil end

  local step = (max_n - min_n) / BUCKET_COUNT
  local bounds = {}
  for b = 1, BUCKET_COUNT do
    bounds[b] = { lo = min_n + step * (b - 1), hi = min_n + step * b }
  end
  return bounds
end

--- Classify a column's data type into a profiling category.
--- Matches on the bare type name: everything inside parentheses is dropped
--- first, because it can carry user data that collides with the keywords below.
--- MySQL's COLUMN_TYPE spells enums out in full, so enum('printed','draft')
--- would match "int" inside "printed" and enum('daytime','night') would match
--- "time" inside "daytime". Dropping the parens also normalises the lengths and
--- precisions every adapter emits: nvarchar(max), decimal(10,2), varchar(100).
function M.classify_column(data_type)
  if not data_type then return "unknown" end
  local dt = (data_type:lower():gsub("%b()", ""))
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

--- Whether a column of `col_type` with these bounds gets CASE buckets rather
--- than a top-values GROUP BY. Callers need to know which shape a
--- build_histogram_sql result will have before they read its rows.
function M.is_bucketed(col_type, min_val, max_val)
  if col_type ~= "numeric" and col_type ~= "date" then return false end
  return M.bucket_bounds(min_val, max_val) ~= nil
end

--- Build a histogram query for one column.
--- Text, boolean and unknown columns -- and anything numeric or date-like whose
--- bounds cannot be bucketed -- get the top BUCKET_COUNT values by frequency.
function M.build_histogram_sql(table_name, col_name, col_type, min_val, max_val)
  local tbl = sql.quote_ident(table_name)
  local col = sql.quote_ident(col_name)

  if not M.is_bucketed(col_type, min_val, max_val) then
    return string.format(
      "SELECT %s AS val, COUNT(*) AS cnt FROM %s WHERE %s IS NOT NULL GROUP BY %s ORDER BY cnt DESC LIMIT %d",
      col, tbl, col, col, BUCKET_COUNT
    )
  end

  -- Numeric or date: build CASE WHEN buckets. Only BUCKET_COUNT - 1 thresholds
  -- are emitted; the last bucket is the ELSE arm, so max lands inside it.
  local bounds = M.bucket_bounds(min_val, max_val)
  local cases = {}
  for b = 1, BUCKET_COUNT - 1 do
    table.insert(cases, string.format("WHEN CAST(%s AS REAL) < %s THEN %d", col, bounds[b].hi, b))
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
      -- Which shape the rows have is decided by the same predicate that chose
      -- the SQL. The open-coded version this replaced left "date" out, so a
      -- date column -- whose bounds are never numeric, hence always a
      -- GROUP BY -- fell into the bucketed branch below, where tonumber() on a
      -- timestamp string yields nil and every value collapsed into bucket 1: a
      -- single-spike sparkline that described nothing, with no top values to
      -- fall back on either.
      if not M.is_bucketed(p.category, p.min, p.max) then
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

--- Gather stats plus a distribution for a single column -- the gS popup.
--- Two queries, the same count the popup has always issued: the distribution
--- replaces its bespoke top-values query instead of adding to it.
--- `data_type` may be nil (column info unavailable), which classifies as
--- "unknown" and yields a top-values distribution rather than an error.
--- Returns (colstats, nil) or (nil, err). A failed *histogram* is not an error:
--- the caller still gets its statistics, with kind left nil, because losing the
--- whole popup over the optional half of it would be the worse trade.
function M.gather_column(table_name, col_name, data_type, url)
  local tbl = sql.quote_ident(table_name)
  local col = sql.quote_ident(col_name)

  local stats_sql = string.format(
    "SELECT COUNT(*) AS total, COUNT(DISTINCT %s) AS distinct_count, " ..
    "COUNT(*) - COUNT(%s) AS null_count, MIN(%s) AS min_val, MAX(%s) AS max_val " ..
    "FROM %s",
    col, col, col, col, tbl
  )
  local stats_result, stats_err = db.query(stats_sql, url)
  if stats_err then return nil, stats_err end
  if not stats_result or #stats_result.rows == 0 then return nil, "No stats returned" end

  local row = stats_result.rows[1]
  local cs = {
    name       = col_name,
    data_type  = data_type,
    category   = M.classify_column(data_type),
    total      = row[1],
    distinct   = row[2],
    nulls      = row[3],
    min        = row[4],
    max        = row[5],
    kind       = nil,  -- "buckets" | "values" | nil when the histogram failed
    buckets    = nil,
    top_values = nil,
  }

  local bucketed = M.is_bucketed(cs.category, cs.min, cs.max)
  local hist_result = db.query(
    M.build_histogram_sql(table_name, col_name, cs.category, cs.min, cs.max), url)
  if not hist_result or #hist_result.rows == 0 then return cs end

  if bucketed then
    local bounds = M.bucket_bounds(cs.min, cs.max)
    local counts = {}
    for b = 1, BUCKET_COUNT do counts[b] = 0 end
    -- Buckets absent from the result set are empty, not missing: GROUP BY only
    -- returns the ones that matched a row.
    for _, r in ipairs(hist_result.rows) do
      local b = math.max(1, math.min(BUCKET_COUNT, tonumber(r[1]) or 1))
      counts[b] = tonumber(r[2]) or 0
    end
    cs.kind = "buckets"
    cs.buckets = {}
    for b = 1, BUCKET_COUNT do
      cs.buckets[b] = { lo = bounds[b].lo, hi = bounds[b].hi, count = counts[b] }
    end
  else
    cs.kind = "values"
    cs.top_values = {}
    for _, r in ipairs(hist_result.rows) do
      table.insert(cs.top_values, { value = r[1], count = tonumber(r[2]) or 0 })
    end
  end

  return cs
end

-- ── display rendering ─────────────────────────────────────────────────────────

--- Format a percentage with one decimal place.
local function fmt_pct(v) return string.format("%.1f%%", v) end

--- Pad or truncate a string to a fixed width. No ellipsis marker (matches
--- this module's original style: values are silently cut, not "…"-marked).
local function pad(s, w) return (ui.pad_display(s, w, false)) end
M._pad = pad  -- exposed for unit tests

--- Pick one number format for a whole histogram. Integral bounds throughout
--- print as integers, anything else as one decimal: switching format between
--- adjacent rows of the same histogram reads as noise.
local function bounds_formatter(buckets)
  for _, b in ipairs(buckets) do
    if b.lo % 1 ~= 0 or b.hi % 1 ~= 0 then
      return function(v) return string.format("%.1f", v) end
    end
  end
  return function(v) return string.format("%d", v) end
end

--- Render label/bar/count rows, aligned on display width. Widths come from
--- strdisplaywidth, never from #s: the popup used to cut values with
--- value:sub(1, 30) -- a byte offset derived from a display-cell budget -- which
--- corrupted any multibyte value (the same bug class already fixed in _pad).
local function bar_rows(rows)
  local max_count, label_w, count_w = 0, 0, 0
  for _, r in ipairs(rows) do
    max_count = math.max(max_count, r.count or 0)
    label_w = math.max(label_w, vim.fn.strdisplaywidth(r.label))
    count_w = math.max(count_w, #tostring(r.count))
  end
  label_w = math.min(label_w, HBAR_LABEL_MAX)

  local out = {}
  for _, r in ipairs(rows) do
    table.insert(out, "    " .. pad(r.label, label_w)
      .. "  " .. pad(M.hbar(r.count, max_count, HBAR_WIDTH), HBAR_WIDTH)
      .. "  " .. string.format("%" .. count_w .. "d", r.count))
  end
  return out, max_count
end

--- Build display lines for the single-column stats popup (gS).
function M.build_column_lines(cs)
  if not cs then return {} end

  local lines = {
    " " .. cs.name .. ": Column Statistics",
    " " .. string.rep("─", 40),
    "  Total:    " .. (cs.total or "?"),
    "  Distinct: " .. (cs.distinct or "?"),
    "  Nulls:    " .. (cs.nulls or "?"),
    "  Min:      " .. (cs.min or "NULL"),
    "  Max:      " .. (cs.max or "NULL"),
  }

  local header, rows = nil, {}
  if cs.kind == "buckets" and cs.buckets then
    header = "  Distribution (" .. BUCKET_COUNT .. " buckets)"
    local fmt = bounds_formatter(cs.buckets)
    for _, b in ipairs(cs.buckets) do
      -- ".." and not an en dash: a column with negative values would otherwise
      -- render bounds as "-12.5 - -3.0".
      table.insert(rows, { label = fmt(b.lo) .. " .. " .. fmt(b.hi), count = b.count })
    end
  elseif cs.kind == "values" and cs.top_values then
    header = "  Top values"
    for _, tv in ipairs(cs.top_values) do
      table.insert(rows, { label = tostring(tv.value or "?"), count = tv.count })
    end
  end
  if not header or #rows == 0 then return lines end

  local rendered, max_count = bar_rows(rows)
  -- An empty table (or a column that is entirely NULL) has nothing to plot;
  -- eight zero-height bars would only claim otherwise.
  if max_count == 0 then return lines end

  table.insert(lines, "")
  table.insert(lines, header)
  for _, l in ipairs(rendered) do table.insert(lines, l) end
  return lines
end

--- Build display lines for the profile buffer.
function M.build_lines(profile_data, term_width)
  if not profile_data then return {}, {} end

  local lines = {}
  local marks = {}

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
      local spark = p.histogram or ""
      local line = "  " .. pad(tostring(i), nw)
        .. "  " .. pad(p.name, cw)
        .. "  " .. pad(p.data_type, tw)
        .. "  " .. pad(fmt_pct(p.completeness), pw)
        .. "  " .. pad(fmt_pct(p.cardinality), dw)
        .. "  " .. pad(p.min, mnw)
        .. "  " .. pad(p.max, mxw)
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

  local data, err = ui.blocking("Profiling " .. table_name .. "...", function()
    return M.gather(table_name, url)
  end)
  if not data then
    vim.notify("GripProfile: " .. (err or "failed"), vim.log.levels.ERROR)
    return
  end

  local lines, marks = M.build_lines(data, vim.o.columns)

  local bufnr = ui.report_split(lines, "grip://profile/" .. table_name)

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
