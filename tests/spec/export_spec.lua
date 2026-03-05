-- export_spec.lua: TDD spec for view._format_export()
-- The pure formatting function is exported as view._format_export(rows, cols, format, table_name).
-- Run: just test
local view = require("dadbod-grip.view")

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

local function contains(s, pattern, msg)
  assert(tostring(s):find(pattern, 1, true),
    (msg or "") .. ": expected to contain '" .. pattern .. "', got: " .. tostring(s))
end

local function not_contains(s, pattern, msg)
  assert(not tostring(s):find(pattern, 1, true),
    (msg or "") .. ": expected NOT to contain '" .. pattern .. "', got: " .. tostring(s))
end

local fmt = view._format_export

-- ── CSV ─────────────────────────────────────────────────────────────────────

test("format_export csv: header row is first line", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "csv", "users")
  eq(lines[1], "name,age")
end)

test("format_export csv: data row follows header", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "csv", "users")
  eq(lines[2], "alice,30")
end)

test("format_export csv: value with comma is wrapped in quotes", function()
  local lines = fmt({ {"Smith, John", "25"} }, {"name", "age"}, "csv", "users")
  contains(lines[2], '"Smith, John"')
end)

test("format_export csv: NULL value is empty string in csv", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "csv", "users")
  -- nil value → empty field
  eq(lines[2], ",30")
end)

test("format_export csv: two rows produce three lines (header + 2)", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "csv", "t")
  eq(#lines, 3)
end)

-- ── JSON ─────────────────────────────────────────────────────────────────────

test("format_export json: output is valid JSON (parseable)", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "json", "users")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "Expected parseable JSON, got: " .. joined)
  assert(type(decoded) == "table" and #decoded == 1)
end)

test("format_export json: NULL value is json null (not string 'null')", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "json", "users")
  local joined = table.concat(lines, "\n")
  -- Raw null keyword must appear, not the string "null"
  contains(joined, '"name": null')
  not_contains(joined, '"name": "null"')
end)

test("format_export json: two rows produces array of two objects", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "json", "t")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "JSON parse failed: " .. joined)
  eq(#decoded, 2)
end)

-- ── SQL ──────────────────────────────────────────────────────────────────────

test("format_export sql: produces INSERT statements", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "INSERT INTO")
  contains(joined, "users")
end)

test("format_export sql: NULL value becomes SQL NULL keyword", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "NULL")
  -- should not be a quoted string 'NULL'
  not_contains(joined, "'NULL'")
end)

test("format_export sql: value with single quote is escaped", function()
  local lines = fmt({ {"O'Brien", "25"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "O''Brien")
end)

test("format_export sql: two rows produce two INSERT statements", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "sql", "t")
  local count = 0
  for _, line in ipairs(lines) do
    if line:find("INSERT INTO", 1, true) then count = count + 1 end
  end
  eq(count, 2)
end)

test("format_export sql: raw query uses _grip_result as table name when no table", function()
  local lines = fmt({ {"x"} }, {"col"}, "sql", nil)
  local joined = table.concat(lines, "\n")
  contains(joined, "_grip_result")
end)

test("format_export sql: column names are included in INSERT header", function()
  local lines = fmt({ {"alice"} }, {"full_name"}, "sql", "people")
  local joined = table.concat(lines, "\n")
  contains(joined, "full_name")
  contains(joined, "VALUES")
end)

test("format_export sql: multiple NULL columns all become NULL", function()
  local lines = fmt({ {nil, nil, "x"} }, {"a", "b", "c"}, "sql", "t")
  local joined = table.concat(lines, "\n")
  -- Two NULLs: pattern NULL, NULL must appear
  contains(joined, "NULL, NULL")
end)

-- ── CSV edge cases ────────────────────────────────────────────────────────────

test("format_export csv: value with double-quote is escaped by doubling", function()
  local lines = fmt({ {'say "hi"', "1"} }, {"msg", "n"}, "csv", "t")
  -- RFC 4180: embedded " → wrap in quotes and double each internal "
  contains(lines[2], '""hi""')
end)

test("format_export csv: value with newline is wrapped in quotes", function()
  local lines = fmt({ {"line1\nline2", "2"} }, {"text", "n"}, "csv", "t")
  contains(lines[2], '"line1\nline2"')
end)

-- ── JSON edge cases ───────────────────────────────────────────────────────────

test("format_export json: numeric value is unquoted in output", function()
  local lines = fmt({ {"alice", "42"} }, {"name", "score"}, "json", "t")
  local joined = table.concat(lines, "\n")
  -- "score": 42  (no quotes around 42)
  contains(joined, '"score": 42')
  not_contains(joined, '"score": "42"')
end)

test("format_export json: value with backslash is escaped", function()
  local lines = fmt({ {"C:\\path"} }, {"dir"}, "json", "t")
  local joined = table.concat(lines, "\n")
  -- backslash must be escaped as \\
  contains(joined, "C:\\\\path")
end)

test("format_export json: empty row list produces empty array", function()
  local lines = fmt({}, {"a", "b"}, "json", "t")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "Expected parseable JSON for empty rows")
  assert(type(decoded) == "table" and #decoded == 0)
end)

-- ── unknown format ────────────────────────────────────────────────────────────

test("format_export unknown format returns empty table", function()
  local lines = fmt({ {"x"} }, {"col"}, "nope", "t")
  eq(#lines, 0)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nexport_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
