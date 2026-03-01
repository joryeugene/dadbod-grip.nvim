-- csv_parser_spec.lua — unit tests for db.parse_csv (RFC 4180 CSV parser)
local db = require("dadbod-grip.db")

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

-- ── basic parsing ───────────────────────────────────────────────────────────

test("basic: simple CSV", function()
  local r = db.parse_csv("name,age\nAlice,30\nBob,25\n")
  eq(#r.columns, 2)
  eq(r.columns[1], "name")
  eq(r.columns[2], "age")
  eq(#r.rows, 2)
  eq(r.rows[1][1], "Alice")
  eq(r.rows[1][2], "30")
  eq(r.rows[2][1], "Bob")
end)

test("basic: single column", function()
  local r = db.parse_csv("id\n1\n2\n3\n")
  eq(#r.columns, 1)
  eq(#r.rows, 3)
end)

-- ── empty input ─────────────────────────────────────────────────────────────

test("empty: nil input", function()
  local r = db.parse_csv(nil)
  eq(#r.columns, 0)
  eq(#r.rows, 0)
end)

test("empty: empty string", function()
  local r = db.parse_csv("")
  eq(#r.columns, 0)
  eq(#r.rows, 0)
end)

-- ── quoted fields ───────────────────────────────────────────────────────────

test("quoted: multiline field", function()
  local r = db.parse_csv('id,body\n1,"Line one\nLine two\nLine three"\n')
  eq(#r.rows, 1)
  eq(r.rows[1][2], "Line one\nLine two\nLine three")
end)

test("quoted: escaped double quotes", function()
  local r = db.parse_csv('col\n"he said ""hello"""\n')
  eq(r.rows[1][1], 'he said "hello"')
end)

test("quoted: comma inside quotes", function()
  local r = db.parse_csv('col\n"foo,bar"\n')
  eq(r.rows[1][1], "foo,bar")
end)

test("quoted: empty quoted field is filtered as empty row", function()
  -- A single-column row with empty string is filtered out by the parser
  -- (same as psql empty row behavior)
  local r = db.parse_csv('col\n""\n')
  eq(#r.rows, 0)
end)

test("quoted: empty quoted field preserved when other columns exist", function()
  local r = db.parse_csv('a,b\n1,""\n')
  eq(#r.rows, 1)
  eq(r.rows[1][2], "")
end)

-- ── edge cases ──────────────────────────────────────────────────────────────

test("edge: trailing empty field", function()
  local r = db.parse_csv("a,b,c\n1,2,\n")
  eq(#r.rows[1], 3)
  eq(r.rows[1][3], "")
end)

test("edge: SQL injection attempt", function()
  local r = db.parse_csv("id,name\n3,\"Robert'); DROP TABLE users;--\"\n")
  eq(r.rows[1][2], "Robert'); DROP TABLE users;--")
end)

test("edge: CRLF line endings", function()
  local r = db.parse_csv("a,b\r\n1,2\r\n3,4\r\n")
  eq(#r.rows, 2)
  eq(r.rows[1][1], "1")
  eq(r.rows[2][1], "3")
end)

test("edge: fewer fields than columns gets padded", function()
  local r = db.parse_csv("a,b,c\n1\n")
  eq(#r.rows[1], 3)
  eq(r.rows[1][2], "")
  eq(r.rows[1][3], "")
end)

-- ── psql footer handling ────────────────────────────────────────────────────

test("psql: footer is stripped", function()
  local r = db.parse_csv("name,age\nAlice,30\nBob,25\n(2 rows)\n")
  eq(#r.rows, 2)
end)

test("psql: single row footer", function()
  local r = db.parse_csv("id\n42\n(1 row)\n")
  eq(#r.rows, 1)
  eq(r.rows[1][1], "42")
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\ncsv_parser_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
