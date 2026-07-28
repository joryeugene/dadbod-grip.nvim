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

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nprofile_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
