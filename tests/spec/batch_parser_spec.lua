-- batch_parser_spec.lua: unit tests for db.parse_batch() (TSV parser for MariaDB --batch output)
local db = require("dadbod-grip.db")

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

local function deep_eq(a, b, msg)
  if type(a) ~= type(b) then
    error((msg or "") .. ": type mismatch: " .. type(a) .. " vs " .. type(b))
  end
  if type(a) == "table" then
    for k, v in pairs(a) do deep_eq(v, b[k], (msg or "") .. "[" .. tostring(k) .. "]") end
    for k in pairs(b) do
      if a[k] == nil then error((msg or "") .. ": extra key " .. tostring(k)) end
    end
  else
    eq(a, b, msg)
  end
end

-- Basic parsing

test("simple TSV with headers parses correctly", function()
  local result = db.parse_batch("id\tname\n1\tAlice\n")
  deep_eq(result.columns, { "id", "name" }, "columns")
  eq(#result.rows, 1, "row count")
  deep_eq(result.rows[1], { "1", "Alice" }, "row 1")
end)

test("single column result", function()
  local result = db.parse_batch("count\n42\n")
  deep_eq(result.columns, { "count" }, "columns")
  deep_eq(result.rows[1], { "42" }, "row 1")
end)

test("multiple rows parsed correctly", function()
  local result = db.parse_batch("id\tname\n1\tAlice\n2\tBob\n3\tCharlie\n")
  eq(#result.rows, 3, "row count")
  deep_eq(result.rows[2], { "2", "Bob" }, "row 2")
  deep_eq(result.rows[3], { "3", "Charlie" }, "row 3")
end)

-- NULL handling

test("\\N field converted to empty string", function()
  local result = db.parse_batch("val\n\\N\n")
  eq(result.rows[1][1], "", "NULL becomes empty")
end)

test("\\N in middle of row", function()
  local result = db.parse_batch("a\tb\tc\n1\t\\N\tAlice\n")
  deep_eq(result.rows[1], { "1", "", "Alice" }, "middle NULL")
end)

test("row of all NULLs", function()
  local result = db.parse_batch("a\tb\n\\N\t\\N\n")
  deep_eq(result.rows[1], { "", "" }, "all NULLs")
end)

-- Escape handling

test("literal \\t unescaped to tab character", function()
  local result = db.parse_batch("val\nfoo\\tbar\n")
  eq(result.rows[1][1], "foo\tbar", "tab unescape")
end)

test("literal \\n unescaped to newline character", function()
  local result = db.parse_batch("val\nline1\\nline2\n")
  eq(result.rows[1][1], "line1\nline2", "newline unescape")
end)

test("literal \\\\ unescaped to single backslash", function()
  local result = db.parse_batch("val\npath\\\\file\n")
  eq(result.rows[1][1], "path\\file", "backslash unescape")
end)

test("mixed escapes in one field", function()
  local result = db.parse_batch("val\na\\tb\\nc\\\\\n")
  eq(result.rows[1][1], "a\tb\nc\\", "mixed escapes")
end)

-- Edge cases

test("empty input returns empty", function()
  local result = db.parse_batch("")
  eq(#result.columns, 0, "no columns")
  eq(#result.rows, 0, "no rows")
end)

test("nil input returns empty", function()
  local result = db.parse_batch(nil)
  eq(#result.columns, 0, "no columns")
  eq(#result.rows, 0, "no rows")
end)

test("header-only returns no data rows", function()
  local result = db.parse_batch("id\tname\n")
  deep_eq(result.columns, { "id", "name" }, "columns")
  eq(#result.rows, 0, "no rows")
end)

test("row with fewer fields than columns padded with empty", function()
  local result = db.parse_batch("a\tb\tc\n1\n")
  eq(#result.rows[1], 3, "padded to 3 fields")
  eq(result.rows[1][2], "", "padded field 2")
  eq(result.rows[1][3], "", "padded field 3")
end)

test("trailing newline does not create empty row", function()
  local result = db.parse_batch("id\n1\n")
  eq(#result.rows, 1, "only one data row")
end)

test("\\r\\n line endings handled correctly", function()
  local result = db.parse_batch("id\tname\r\n1\tAlice\r\n")
  deep_eq(result.columns, { "id", "name" }, "columns")
  deep_eq(result.rows[1], { "1", "Alice" }, "row")
end)

-- Contract parity with parse_csv

test("output shape matches parse_csv shape", function()
  local batch_result = db.parse_batch("id\tname\n1\tAlice\n")
  local csv_result = db.parse_csv("id,name\n1,Alice\n")
  assert(batch_result.columns ~= nil, "batch has columns")
  assert(batch_result.rows ~= nil, "batch has rows")
  assert(csv_result.columns ~= nil, "csv has columns")
  assert(csv_result.rows ~= nil, "csv has rows")
  deep_eq(batch_result.columns, csv_result.columns, "same columns")
  deep_eq(batch_result.rows, csv_result.rows, "same rows")
end)

-- Summary
print(string.format("\nbatch_parser_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
