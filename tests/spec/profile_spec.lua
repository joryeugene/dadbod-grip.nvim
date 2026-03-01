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
    print("FAIL: " .. name .. " — " .. tostring(err))
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
  local lines, marks = profile.build_lines(data, 120)
  assert(#marks > 0, "should have highlight marks")
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
