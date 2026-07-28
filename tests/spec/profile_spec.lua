-- profile_spec.lua -- unit tests for data profiling module
local profile = require("dadbod-grip.profile")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

-- ── sparkline ─────────────────────────────────────────────────────────────────

test("sparkline: uniform distribution returns equal bars", function()
  local result = profile.sparkline({10, 10, 10, 10}, 10)
  -- All counts equal max, should all be highest bar
  eq(#result, 12, "4 chars * 3 bytes each = 12") -- UTF-8 block elements are 3 bytes
  -- Each bar should be the same character
  local chars = {}
  for c in result:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    table.insert(chars, c)
  end
  eq(#chars, 4, "four sparkline characters")
  eq(chars[1], chars[2], "uniform bars")
end)

test("sparkline: single peak", function()
  local result = profile.sparkline({1, 1, 10, 1}, 10)
  local chars = {}
  for c in result:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    table.insert(chars, c)
  end
  eq(#chars, 4, "four chars")
  -- Third char should be highest
  assert(chars[3] ~= chars[1], "peak differs from base")
end)

test("sparkline: all zeros returns lowest bars", function()
  local result = profile.sparkline({0, 0, 0}, 0)
  local chars = {}
  for c in result:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    table.insert(chars, c)
  end
  eq(#chars, 3, "three chars")
end)

test("sparkline: empty counts returns empty string", function()
  eq(profile.sparkline({}, 0), "", "empty")
  eq(profile.sparkline(nil, 0), "", "nil")
end)

-- ── hbar ──────────────────────────────────────────────────────────────────────

local FULL = "\xe2\x96\x88"
local THINNEST = "\xe2\x96\x8f"

--- Count display cells, not bytes: every block glyph is 3 bytes wide.
local function cells(s) return vim.fn.strdisplaywidth(s) end

test("hbar: a full-scale count fills the whole width", function()
  eq(cells(profile.hbar(50, 50, 16)), 16, "16 cells")
  eq(profile.hbar(50, 50, 16), string.rep(FULL, 16), "all full blocks")
end)

test("hbar: half scale fills half the width", function()
  eq(profile.hbar(25, 50, 16), string.rep(FULL, 8), "eight full blocks")
end)

test("hbar: fractional remainder uses an eighth-block", function()
  -- 1/16 of full scale = one cell = 8 eighths... so take 1/32: half a cell.
  local bar = profile.hbar(1, 32, 16)
  eq(cells(bar), 1, "single cell")
  assert(bar ~= FULL, "a half cell is not a full block")
end)

test("hbar: a non-zero count is never invisible", function()
  -- The whole point of the eighth-blocks: one row out of ten million must not
  -- render as blank, or it is indistinguishable from an empty bucket.
  local bar = profile.hbar(1, 10000000, 16)
  assert(bar ~= "", "one-in-ten-million still draws")
  eq(bar, THINNEST, "thinnest block")
end)

test("hbar: zero count and zero scale render empty", function()
  eq(profile.hbar(0, 100, 16), "", "zero count")
  eq(profile.hbar(0, 0, 16), "", "zero count and scale")
  eq(profile.hbar(10, 0, 16), "", "zero scale")
end)

test("hbar: nil and non-numeric input is survivable", function()
  eq(profile.hbar(nil, nil), "", "both nil")
  eq(profile.hbar(nil, 100), "", "nil count")
  eq(profile.hbar(10, nil), "", "nil scale")
  eq(profile.hbar("abc", 100), "", "garbage count")
end)

test("hbar: never overflows the requested width", function()
  -- count > max_count should not happen, but a bar wider than its column would
  -- shift every count in the popup out of alignment if it did.
  eq(cells(profile.hbar(500, 50, 16)), 16, "clamped to width")
  eq(cells(profile.hbar(7, 10, 4)), 3, "narrow width respected")
end)

-- ── bucket_bounds ─────────────────────────────────────────────────────────────

test("bucket_bounds: 0..100 spans eight contiguous ranges", function()
  local b = profile.bucket_bounds("0", "100")
  eq(#b, 8, "eight buckets")
  eq(b[1].lo, 0, "starts at min")
  eq(b[8].hi, 100, "ends at max")
  eq(b[1].hi, 12.5, "step is 12.5")
  eq(b[2].lo, 12.5, "buckets are contiguous")
  for i = 1, 7 do
    eq(b[i].hi, b[i + 1].lo, "bucket " .. i .. " abuts " .. (i + 1))
  end
end)

test("bucket_bounds: negative ranges keep their arithmetic", function()
  local b = profile.bucket_bounds("-40", "40")
  eq(b[1].lo, -40, "starts at min")
  eq(b[4].hi, 0, "walks through zero")
  eq(b[8].hi, 40, "ends at max")
end)

test("bucket_bounds: unbucketable bounds return nil", function()
  eq(profile.bucket_bounds(nil, nil), nil, "both nil")
  eq(profile.bucket_bounds("5", "5"), nil, "min == max")
  eq(profile.bucket_bounds("", ""), nil, "empty (what gather passes for no data)")
  eq(profile.bucket_bounds("2024-01-01", "2024-06-01"), nil, "timestamps are not numeric")
end)

-- ── is_bucketed ───────────────────────────────────────────────────────────────

test("is_bucketed: only numeric and date with numeric bounds", function()
  eq(profile.is_bucketed("numeric", "0", "100"), true, "numeric")
  eq(profile.is_bucketed("text", "0", "100"), false, "text never buckets")
  eq(profile.is_bucketed("boolean", "0", "1"), false, "boolean never buckets")
  eq(profile.is_bucketed("unknown", "0", "100"), false, "unknown never buckets")
  eq(profile.is_bucketed("numeric", "7", "7"), false, "single-valued numeric")
  -- A date's MIN/MAX are timestamp strings, so it always falls back to values.
  eq(profile.is_bucketed("date", "2024-01-01", "2024-06-01"), false, "date bounds are not numeric")
end)

-- ── classify_column ───────────────────────────────────────────────────────────

test("classify_column: integer types", function()
  eq(profile.classify_column("integer"), "numeric")
  eq(profile.classify_column("INT"), "numeric")
  eq(profile.classify_column("bigint"), "numeric")
  eq(profile.classify_column("smallint"), "numeric")
  eq(profile.classify_column("SERIAL"), "numeric")
end)

test("classify_column: float types", function()
  eq(profile.classify_column("float"), "numeric")
  eq(profile.classify_column("DOUBLE PRECISION"), "numeric")
  eq(profile.classify_column("real"), "numeric")
  eq(profile.classify_column("numeric(10,2)"), "numeric")
  eq(profile.classify_column("decimal"), "numeric")
  eq(profile.classify_column("money"), "numeric")
end)

test("classify_column: text types", function()
  eq(profile.classify_column("varchar(255)"), "text")
  eq(profile.classify_column("TEXT"), "text")
  eq(profile.classify_column("character varying"), "text")
  eq(profile.classify_column("ENUM"), "text")
end)

test("classify_column: boolean", function()
  eq(profile.classify_column("boolean"), "boolean")
  eq(profile.classify_column("BOOL"), "boolean")
end)

test("classify_column: date types", function()
  eq(profile.classify_column("date"), "date")
  eq(profile.classify_column("timestamp"), "date")
  eq(profile.classify_column("TIMESTAMP WITH TIME ZONE"), "date")
  eq(profile.classify_column("interval"), "date")
end)

test("classify_column: unknown types", function()
  eq(profile.classify_column("json"), "unknown")
  eq(profile.classify_column("bytea"), "unknown")
  eq(profile.classify_column(nil), "unknown")
end)

test("classify_column: enum/set values must not leak into the classification", function()
  -- MySQL's COLUMN_TYPE spells the value list out, so the payload is user data:
  -- "printed" contains "int", "daytime" contains "time". Classifying on it would
  -- send AVG(CAST(col AS REAL)) at an enum column and bucket it as a number.
  eq(profile.classify_column("enum('printed','draft')"), "text", "int hidden in a value")
  eq(profile.classify_column("set('read','write','print')"), "text", "int hidden in a set value")
  eq(profile.classify_column("enum('daytime','night')"), "text", "time hidden in a value")
  eq(profile.classify_column("enum('happy','sad','neutral')"), "text", "plain enum")
end)

test("classify_column: lengths and precisions do not change the category", function()
  eq(profile.classify_column("nvarchar(max)"), "text", "sqlserver max length")
  eq(profile.classify_column("decimal(10,2)"), "numeric", "precision and scale")
  eq(profile.classify_column("tinyint(1)"), "numeric", "mysql boolean convention stays numeric")
  eq(profile.classify_column("bigint unsigned"), "numeric", "unsigned modifier")
  eq(profile.classify_column("timestamp(3) without time zone"), "date", "fractional seconds")
end)

-- ── build_lines ───────────────────────────────────────────────────────────────

local function mock_profile_data()
  return {
    table_name = "users",
    column_count = 3,
    shown_count = 3,
    total_rows = 100,
    profiles = {
      {
        name = "id", data_type = "integer", category = "numeric",
        total = 100, distinct = 100, nulls = 0,
        completeness = 100.0, cardinality = 100.0,
        min = "1", max = "100", mean = "50.5",
        histogram = profile.sparkline({10,12,13,11,14,12,15,13}, 15),
        top_values = nil,
      },
      {
        name = "name", data_type = "text", category = "text",
        total = 100, distinct = 85, nulls = 2,
        completeness = 98.0, cardinality = 86.7,
        min = "alice", max = "zoe", mean = nil,
        histogram = profile.sparkline({20,15,10,8,5,3,2,1}, 20),
        top_values = {
          { value = "alice", count = 20 },
          { value = "bob", count = 15 },
        },
      },
      {
        name = "status", data_type = "text", category = "text",
        total = 100, distinct = 3, nulls = 0,
        completeness = 100.0, cardinality = 3.0,
        min = "active", max = "pending", mean = nil,
        histogram = profile.sparkline({60,30,10}, 60),
        top_values = {
          { value = "active", count = 60 },
          { value = "pending", count = 30 },
          { value = "inactive", count = 10 },
        },
      },
    }
  }
end

test("build_lines: wide terminal produces tabular layout", function()
  local data = mock_profile_data()
  local lines = profile.build_lines(data, 120)
  local joined = table.concat(lines, "\n")
  contains(joined, "Table Profile: users", "has title")
  contains(joined, "Column", "has column header")
  contains(joined, "Complete", "has completeness header")
  contains(joined, "100.0%", "shows percentage")
  contains(joined, "Top Values", "has top values section")
  contains(joined, "active (60)", "shows top value")
end)

test("build_lines: narrow terminal produces stacked layout", function()
  local data = mock_profile_data()
  local lines = profile.build_lines(data, 60)
  local joined = table.concat(lines, "\n")
  contains(joined, "1. id (integer)", "stacked format")
  contains(joined, "Complete:", "has completeness")
  contains(joined, "Range:", "has range for numeric")
  contains(joined, "Top:", "has top values for text")
end)

test("build_lines: empty profiles produces header only", function()
  local data = {
    table_name = "empty",
    column_count = 0,
    shown_count = 0,
    total_rows = 0,
    profiles = {},
  }
  local lines = profile.build_lines(data, 120)
  assert(#lines >= 1, "at least header line")
  contains(lines[1], "Table Profile: empty", "title present")
end)

test("build_lines: highlight marks generated", function()
  local data = mock_profile_data()
  local _, marks = profile.build_lines(data, 120)
  assert(#marks > 0, "should have highlight marks")
end)

-- ── pad (display-width, not byte-length) ─────────────────────────────────────
-- Task 11: alignment must use display width, not #s. The old implementation
-- compared strdisplaywidth(s) >= w and then took s:sub(1, w) — a BYTE offset
-- computed from a DISPLAY-WIDTH number. For non-ASCII input that corrupted
-- even strings that exactly fit (no truncation should happen at all).

test("pad: ascii unchanged (fits, no truncation)", function()
  eq(profile._pad("id", 6), "id    ", "ascii pad")
end)

test("pad: ascii truncates by byte (unchanged behavior, no marker)", function()
  eq(profile._pad("abcdefgh", 4), "abcd", "ascii truncate, no ellipsis")
end)

test("pad: cyrillic value exactly at width is NOT corrupted", function()
  -- "имя" = 3 display cells, 6 bytes. Old code: strdisplaywidth("имя")=3 >= w=3
  -- -> "имя":sub(1,3) took the first 3 BYTES = 1.5 characters -> garbage.
  local out = profile._pad("имя", 3)
  eq(out, "имя", "exact-width cyrillic value survives intact")
end)

test("pad: cyrillic value narrower than width is padded with spaces", function()
  local out = profile._pad("имя", 6)
  eq(out, "имя   ", "cyrillic + 3 padding spaces")
  eq(vim.fn.strdisplaywidth(out), 6, "display width matches target")
end)

test("pad: cyrillic value wider than width truncates on a char boundary", function()
  local out = profile._pad("привет", 3)
  eq(vim.fn.strdisplaywidth(out), 3, "truncated to exactly 3 display cells")
  assert(pcall(vim.str_utf_pos, out), "output is valid UTF-8 (no split multibyte char)")
end)

test("pad: CJK (2 cells/char) truncates without splitting a character", function()
  local out = profile._pad("日本語テキスト", 5)
  eq(vim.fn.strdisplaywidth(out), 5, "truncated to exactly 5 display cells (even count for 2-wide chars)")
  assert(pcall(vim.str_utf_pos, out), "output is valid UTF-8")
end)

test("pad: emoji value exactly at width is NOT corrupted", function()
  local out = profile._pad("😀😀", 4)
  eq(out, "😀😀", "exact-width emoji value survives intact")
end)

-- ── build_lines: non-ASCII column data keeps the table aligned ──────────────
-- Real end-to-end check: a table with a Cyrillic column name/min/max and a
-- CJK/emoji column name/min/max must still line up its "Min"/"Max"/"Dist"
-- fields at the same display column across every data row.

test("build_lines: non-ASCII columns produce equal-width aligned rows", function()
  local data = {
    table_name = "смеси",
    column_count = 2,
    shown_count = 2,
    total_rows = 10,
    profiles = {
      {
        name = "категория", data_type = "text", category = "text",
        total = 10, distinct = 3, nulls = 0,
        completeness = 100.0, cardinality = 30.0,
        min = "активный", max = "приостановлен", mean = nil,
        histogram = profile.sparkline({1,2,3,4,5,6,7,8}, 8),
        top_values = nil,
      },
      {
        name = "商品名", data_type = "text", category = "text",
        total = 10, distinct = 2, nulls = 0,
        completeness = 100.0, cardinality = 20.0,
        min = "🍜ラーメン", max = "寿司セット", mean = nil,
        histogram = profile.sparkline({8,1,1,1,1,1,1,1}, 8),
        top_values = nil,
      },
    },
  }
  local lines = profile.build_lines(data, 120)

  -- Locate the two data rows (they follow the header + dashed separator).
  local row_lines = {}
  for _, l in ipairs(lines) do
    if l:find("активный", 1, true) or l:find("ラーメン", 1, true) then
      table.insert(row_lines, l)
    end
  end
  eq(#row_lines, 2, "found both non-ASCII data rows")

  -- Every data row must have the same display width up to (and including)
  -- the histogram, i.e. the whole line, since fields are padded to fixed
  -- display-width columns and the sparkline is always BUCKET_COUNT chars.
  local widths = {}
  for _, l in ipairs(row_lines) do
    table.insert(widths, vim.fn.strdisplaywidth(l))
  end
  eq(widths[1], widths[2], "cyrillic row and CJK/emoji row have equal display width")

  for _, l in ipairs(row_lines) do
    assert(pcall(vim.str_utf_pos, l), "row is valid UTF-8: " .. l)
  end
end)

-- ── build_column_lines (the gS popup) ─────────────────────────────────────────

local function bucket_colstats()
  local bounds = profile.bucket_bounds("18", "79")
  local counts = { 104, 182, 237, 165, 123, 87, 51, 39 }
  local buckets = {}
  for b = 1, 8 do
    buckets[b] = { lo = bounds[b].lo, hi = bounds[b].hi, count = counts[b] }
  end
  return {
    name = "age", data_type = "integer", category = "numeric",
    total = "1000", distinct = "62", nulls = "12", min = "18", max = "79",
    kind = "buckets", buckets = buckets,
  }
end

local function values_colstats(top_values)
  return {
    name = "status", data_type = "text", category = "text",
    total = "1000", distinct = "3", nulls = "0", min = "active", max = "pending",
    kind = "values", top_values = top_values or {
      { value = "active", count = 620 },
      { value = "pending", count = 260 },
      { value = "inactive", count = 120 },
    },
  }
end

--- The rows carrying bars: everything indented four spaces under a header.
local function bar_lines(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:find("^    %S") then table.insert(out, l) end
  end
  return out
end

test("build_column_lines: stats block is unchanged", function()
  local lines = profile.build_column_lines(bucket_colstats())
  eq(lines[1], " age: Column Statistics", "title")
  contains(table.concat(lines, "\n"), "  Total:    1000", "total")
  contains(table.concat(lines, "\n"), "  Distinct: 62", "distinct")
  contains(table.concat(lines, "\n"), "  Nulls:    12", "nulls")
  contains(table.concat(lines, "\n"), "  Min:      18", "min")
  contains(table.concat(lines, "\n"), "  Max:      79", "max")
end)

test("build_column_lines: numeric renders eight labelled buckets", function()
  local lines = profile.build_column_lines(bucket_colstats())
  local joined = table.concat(lines, "\n")
  contains(joined, "Distribution (8 buckets)", "distribution header")
  assert(not joined:find("Top values", 1, true), "numeric shows buckets instead of top values")
  eq(#bar_lines(lines), 8, "eight bucket rows")
  contains(joined, FULL, "bars are drawn")
  -- The tallest bucket (237) gets a full-width bar, so it is all full blocks.
  contains(joined, string.rep(FULL, 16), "peak bucket is full scale")
end)

test("build_column_lines: bucket labels are bounds joined by '..'", function()
  local lines = profile.build_column_lines(bucket_colstats())
  local joined = table.concat(lines, "\n")
  -- 18..79 over 8 buckets steps by 7.625, so bounds are fractional throughout.
  contains(joined, "18.0 .. 25.6", "first bucket")
  contains(joined, "71.4 .. 79.0", "last bucket ends at max")
  assert(not joined:find("–", 1, true), "no en dash: it is unreadable with negative bounds")
end)

test("build_column_lines: integral bounds print without decimals", function()
  local bounds = profile.bucket_bounds("0", "80")  -- step 10, every bound integral
  local buckets = {}
  for b = 1, 8 do
    buckets[b] = { lo = bounds[b].lo, hi = bounds[b].hi, count = b }
  end
  local joined = table.concat(profile.build_column_lines({
    name = "n", total = "36", distinct = "8", nulls = "0", min = "0", max = "80",
    kind = "buckets", buckets = buckets,
  }), "\n")
  contains(joined, "0 .. 10", "integral bounds")
  contains(joined, "70 .. 80", "integral bounds, last bucket")
  assert(not joined:find("0.0 .. 10.0", 1, true), "no gratuitous decimals")
end)

test("build_column_lines: one fractional bound switches the whole histogram", function()
  local bounds = profile.bucket_bounds("0", "81")  -- step 10.125
  local buckets = {}
  for b = 1, 8 do
    buckets[b] = { lo = bounds[b].lo, hi = bounds[b].hi, count = b }
  end
  local joined = table.concat(profile.build_column_lines({
    name = "n", total = "36", distinct = "8", nulls = "0", min = "0", max = "81",
    kind = "buckets", buckets = buckets,
  }), "\n")
  contains(joined, "0.0 .. 10.1", "first bound formatted as decimal too, not as '0'")
end)

test("build_column_lines: text renders top values with bars", function()
  local lines = profile.build_column_lines(values_colstats())
  local joined = table.concat(lines, "\n")
  contains(joined, "Top values", "top values header")
  assert(not joined:find("Distribution", 1, true), "no bucket header for text")
  eq(#bar_lines(lines), 3, "one row per value")
  contains(joined, "active", "value label")
  contains(joined, "620", "count")
end)

test("build_column_lines: a failed histogram still yields the stats", function()
  -- kind = nil is what gather_column returns when the histogram query fails.
  local cs = bucket_colstats()
  cs.kind, cs.buckets = nil, nil
  local lines = profile.build_column_lines(cs)
  contains(table.concat(lines, "\n"), "Total:    1000", "stats survive")
  eq(#bar_lines(lines), 0, "no bar rows")
end)

test("build_column_lines: an all-zero distribution is omitted, not drawn flat", function()
  local cs = bucket_colstats()
  for _, b in ipairs(cs.buckets) do b.count = 0 end
  local joined = table.concat(profile.build_column_lines(cs), "\n")
  assert(not joined:find("Distribution", 1, true), "eight empty bars would claim a shape that isn't there")
end)

test("build_column_lines: nil colstats yields no lines", function()
  eq(#profile.build_column_lines(nil), 0, "nil-safe")
end)

test("build_column_lines: bucket rows are all the same display width", function()
  local lines = bar_lines(profile.build_column_lines(bucket_colstats()))
  local w = vim.fn.strdisplaywidth(lines[1])
  for i, l in ipairs(lines) do
    eq(vim.fn.strdisplaywidth(l), w, "row " .. i .. " aligns")
  end
end)

test("build_column_lines: non-ASCII value labels stay aligned and valid UTF-8", function()
  -- The popup used to cut labels with value:sub(1, 30) -- a byte offset applied
  -- to a display-cell budget -- which corrupted multibyte values outright.
  local lines = bar_lines(profile.build_column_lines(values_colstats({
    { value = "категория-которая-заметно-длиннее-тридцати-символов", count = 500 },
    { value = "日本語テキスト", count = 300 },
    { value = "🍜ラーメン", count = 100 },
    { value = "ascii", count = 50 },
  })))
  eq(#lines, 4, "four rows")
  local w = vim.fn.strdisplaywidth(lines[1])
  for i, l in ipairs(lines) do
    eq(vim.fn.strdisplaywidth(l), w, "row " .. i .. " aligns")
    assert(pcall(vim.str_utf_pos, l), "row " .. i .. " is valid UTF-8: " .. l)
  end
end)

test("build_column_lines: the label column is sized in cells, not bytes", function()
  -- "日本語" is 6 display cells but 9 bytes. Sizing the label column off #s
  -- pads every row three cells wider than the widest label actually needs,
  -- which the equal-width checks above cannot see -- they only prove the rows
  -- match each other, and they still would.
  local lines = bar_lines(profile.build_column_lines(values_colstats({
    { value = "日本語", count = 10 },
    { value = "abc", count = 5 },
  })))
  eq(#lines, 2, "two rows")
  -- 4 indent + 6 label + 2 gap + 16 bar + 2 gap + 2 count
  eq(vim.fn.strdisplaywidth(lines[1]), 32, "row is exactly as wide as its parts")
end)

test("build_column_lines: a NULL-ish value label does not crash the render", function()
  local lines = profile.build_column_lines(values_colstats({
    { value = nil, count = 10 },
    { value = "x", count = 5 },
  }))
  contains(table.concat(lines, "\n"), "Top values", "still renders")
end)

-- ── SQL generation ────────────────────────────────────────────────────────────

test("build_stats_sql: generates valid SQL structure", function()
  local cols = {
    { column_name = "id", data_type = "integer" },
    { column_name = "name", data_type = "text" },
  }
  local result = profile.build_stats_sql("users", cols)
  contains(result, "SELECT", "has SELECT")
  contains(result, "_total", "has total count")
  contains(result, "_d1", "has distinct for col 1")
  contains(result, "_d2", "has distinct for col 2")
  contains(result, "_avg1", "has avg for numeric col")
  -- text column should not have avg
  assert(not result:find("_avg2"), "no avg for text column")
end)

test("build_histogram_sql: text column uses GROUP BY", function()
  local result = profile.build_histogram_sql("users", "name", "text", nil, nil)
  contains(result, "GROUP BY", "has GROUP BY")
  contains(result, "ORDER BY cnt DESC", "ordered by count")
  contains(result, "LIMIT 8", "limited to bucket count")
end)

test("build_histogram_sql: numeric column uses CASE buckets", function()
  local result = profile.build_histogram_sql("users", "age", "numeric", "0", "100")
  contains(result, "CASE", "has CASE")
  contains(result, "bucket", "has bucket alias")
end)

-- The exact thresholds are pinned, not just the presence of "CASE": the CASE
-- ladder and the bucket labels in the gS popup are generated from the same
-- bucket_bounds(), and this is what proves the two cannot drift apart. 0..100
-- over 8 buckets steps by 12.5, and only 7 WHEN arms are emitted -- the eighth
-- bucket is the ELSE, which is what makes it inclusive of max.
test("build_histogram_sql: CASE thresholds are exactly min + step*b", function()
  local result = profile.build_histogram_sql("users", "age", "numeric", "0", "100")
  for _, threshold in ipairs({ "12.5", "25", "37.5", "50", "62.5", "75", "87.5" }) do
    contains(result, 'WHEN CAST("age" AS REAL) < ' .. threshold .. " THEN", "threshold " .. threshold)
  end
  eq(select(2, result:gsub("WHEN", "")), 7, "seven WHEN arms")
  contains(result, "ELSE 8", "eighth bucket is the ELSE arm")
  assert(not result:find("< 100 THEN", 1, true), "max is never itself a threshold")
end)

test("build_histogram_sql: negative range keeps the step arithmetic", function()
  -- -40..40 steps by 10; the ladder must walk through zero, not around it.
  local result = profile.build_histogram_sql("t", "delta", "numeric", "-40", "40")
  for _, threshold in ipairs({ "-30", "-20", "-10", "0", "10", "20", "30" }) do
    contains(result, 'WHEN CAST("delta" AS REAL) < ' .. threshold .. " THEN", "threshold " .. threshold)
  end
end)

-- ── gather_column against a real database ────────────────────────────────────
-- Uses the committed tests/seed_sqlite.db, like the other DB-backed specs.
-- orders.total is REAL over 150 rows (5.0 .. 501.0); orders.status is TEXT with
-- 5 distinct values. Pure-function tests cannot catch a wrong column order in
-- the stats SELECT or a bucket index the adapter returns as a string.

local sqlite_url = "sqlite:tests/seed_sqlite.db"

test("gather_column: numeric column buckets a real distribution", function()
  local cs, err = profile.gather_column("orders", "total", "REAL", sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(cs.category, "numeric", "classified numeric")
  eq(cs.kind, "buckets", "bucketed")
  eq(tonumber(cs.total), 150, "row count")
  eq(#cs.buckets, 8, "eight buckets")

  local summed = 0
  for _, b in ipairs(cs.buckets) do summed = summed + b.count end
  eq(summed, 150 - tonumber(cs.nulls), "every non-NULL row lands in exactly one bucket")
  eq(cs.buckets[1].lo, tonumber(cs.min), "first bucket starts at MIN")
  eq(cs.buckets[8].hi, tonumber(cs.max), "last bucket ends at MAX")

  local lines = profile.build_column_lines(cs)
  contains(table.concat(lines, "\n"), "Distribution (8 buckets)", "renders a distribution")
end)

test("gather_column: every stats field comes from the right SELECT column", function()
  -- users.age is the one fixture column where total, distinct, nulls, min and
  -- max are five *different* numbers (15/13/2/19/51), so any two of them
  -- swapped in the result-row unpacking shows up here. With a column like
  -- orders.total, distinct and nulls are both plausible and a swap is silent.
  local cs, err = profile.gather_column("users", "age", "INTEGER", sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(tonumber(cs.total), 15, "total")
  eq(tonumber(cs.distinct), 13, "distinct")
  eq(tonumber(cs.nulls), 2, "nulls")
  eq(tonumber(cs.min), 19, "min")
  eq(tonumber(cs.max), 51, "max")
end)

test("gather_column: buckets the query never mentions come back as zero", function()
  -- products.price is skewed (20 rows, 1.99 .. 499.99, most of them cheap), so
  -- GROUP BY simply omits the buckets nothing fell into. Those slots must read
  -- as empty rather than inheriting whatever the counts table was seeded with.
  local cs, err = profile.gather_column("products", "price", "REAL", sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(cs.kind, "buckets", "bucketed")
  eq(#cs.buckets, 8, "eight buckets")

  local empty, summed = 0, 0
  for _, b in ipairs(cs.buckets) do
    summed = summed + b.count
    if b.count == 0 then empty = empty + 1 end
  end
  assert(empty > 0, "this fixture has gaps in its distribution, got none")
  eq(summed, 20, "the counts still add up to every row")
end)

test("gather_column: text column returns top values", function()
  local cs, err = profile.gather_column("orders", "status", "TEXT", sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(cs.kind, "values", "top values")
  assert(#cs.top_values > 0 and #cs.top_values <= 8, "between 1 and 8 values, got " .. #cs.top_values)

  local summed = 0
  for _, tv in ipairs(cs.top_values) do summed = summed + tv.count end
  eq(summed, 150, "orders.status has 5 distinct values, so all 150 rows are covered")

  local prev = math.huge
  for _, tv in ipairs(cs.top_values) do
    assert(tv.count <= prev, "values arrive ordered by descending count")
    prev = tv.count
  end
  contains(table.concat(profile.build_column_lines(cs), "\n"), "Top values", "renders top values")
end)

test("gather_column: a nil data_type degrades to top values, not an error", function()
  -- What the popup passes when get_column_info is unavailable.
  local cs, err = profile.gather_column("orders", "total", nil, sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(cs.category, "unknown", "unknown category")
  eq(cs.kind, "values", "falls back to top values")
end)

test("gather_column: a date column returns top values, not a collapsed bucket", function()
  local cs, err = profile.gather_column("orders", "ordered_at", "DATETIME", sqlite_url)
  assert(cs, "gather_column failed: " .. tostring(err))
  eq(cs.category, "date", "classified date")
  eq(cs.kind, "values", "timestamps cannot be bucketed by the CASE ladder")
  assert(#cs.top_values > 0, "has values")
end)

test("gather_column: a missing table reports an error instead of throwing", function()
  local cs = profile.gather_column("no_such_table_xyz", "id", "INTEGER", sqlite_url)
  eq(cs, nil, "no colstats for a table that does not exist")
end)

-- ── gather: date columns keep a meaningful sparkline ─────────────────────────

test("gather: date column carries top values, not a single-spike sparkline", function()
  local data, err = profile.gather("orders", sqlite_url)
  assert(data, "gather failed: " .. tostring(err))
  local ordered_at
  for _, p in ipairs(data.profiles) do
    if p.name == "ordered_at" then ordered_at = p end
  end
  assert(ordered_at, "found the ordered_at profile")
  eq(ordered_at.category, "date", "classified date")
  -- Before is_bucketed() drove this branch, a date fell into the bucketed path,
  -- where tonumber() on a timestamp yields nil and every row collapsed into
  -- bucket 1 -- one bar, seven zeros, and no top values to fall back on.
  assert(ordered_at.top_values and #ordered_at.top_values > 0, "date has top values")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nprofile_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
