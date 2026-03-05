-- filter_spec.lua: TDD spec for query.build_filter_clause()
-- Run: just test
-- All tests should FAIL before implementation, PASS after.
local query = require("dadbod-grip.query")

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

-- ── build_filter_clause ──────────────────────────────────────────────────────

test("build_filter_clause: = with string value quotes it", function()
  local clause = query.build_filter_clause("name", "=", "Alice")
  eq(clause, '"name" = \'Alice\'')
end)

test("build_filter_clause: != with string value quotes it", function()
  local clause = query.build_filter_clause("status", "!=", "inactive")
  eq(clause, '"status" != \'inactive\'')
end)

test("build_filter_clause: > with numeric string does not quote", function()
  local clause = query.build_filter_clause("age", ">", "30")
  eq(clause, '"age" > 30')
end)

test("build_filter_clause: < with numeric string does not quote", function()
  local clause = query.build_filter_clause("amount", "<", "99.99")
  eq(clause, '"amount" < 99.99')
end)

test("build_filter_clause: negative number does not quote", function()
  local clause = query.build_filter_clause("balance", "=", "-1")
  eq(clause, '"balance" = -1')
end)

test("build_filter_clause: LIKE wraps value in quotes", function()
  local clause = query.build_filter_clause("email", "LIKE", "%@gmail%")
  eq(clause, '"email" LIKE \'%@gmail%\'')
end)

test("build_filter_clause: IN with comma-separated values quotes each part", function()
  local clause = query.build_filter_clause("status", "IN", "active,pending")
  eq(clause, '"status" IN (\'active\',\'pending\')')
end)

test("build_filter_clause: IN with numeric values does not quote", function()
  local clause = query.build_filter_clause("id", "IN", "1,2,3")
  eq(clause, '"id" IN (1,2,3)')
end)

test("build_filter_clause: IN with mixed values quotes strings, leaves numbers", function()
  local clause = query.build_filter_clause("tier", "IN", "gold,1")
  -- gold is a string → quoted; 1 is numeric → unquoted
  eq(clause, '"tier" IN (\'gold\',1)')
end)

test("build_filter_clause: NULL operator emits IS NULL (value ignored)", function()
  local clause = query.build_filter_clause("deleted_at", "NULL", nil)
  eq(clause, '"deleted_at" IS NULL')
end)

test("build_filter_clause: NOT NULL operator emits IS NOT NULL (value ignored)", function()
  local clause = query.build_filter_clause("deleted_at", "NOT NULL", nil)
  eq(clause, '"deleted_at" IS NOT NULL')
end)

test("build_filter_clause: date string is quoted (not treated as number)", function()
  local clause = query.build_filter_clause("created_at", ">", "2024-01-01")
  eq(clause, '"created_at" > \'2024-01-01\'')
end)

test("build_filter_clause: value with single quote is escaped", function()
  local clause = query.build_filter_clause("name", "=", "O'Brien")
  eq(clause, '"name" = \'O\'\'Brien\'')
end)

test("build_filter_clause: column name with spaces or caps is double-quoted", function()
  local clause = query.build_filter_clause("First Name", "=", "Alice")
  eq(clause, '"First Name" = \'Alice\'')
end)

-- ── integration: add_filter + build_filter_clause round-trip ────────────────

test("add_filter + build_filter_clause: clause appears in WHERE", function()
  local spec = query.new_table("users", 100)
  local clause = query.build_filter_clause("age", ">", "25")
  local new_spec = query.add_filter(spec, clause)
  local sql = query.build_sql(new_spec)
  assert(sql:find('"age" > 25', 1, true), "Expected WHERE clause in SQL: " .. sql)
end)

test("build_filter_clause: = with float string does not quote", function()
  local clause = query.build_filter_clause("score", "=", "3.14")
  eq(clause, '"score" = 3.14')
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nfilter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
