-- undo_sql_spec.lua: TDD tests for undo reverse-SQL generation from raw CSV values.
--
-- All four adapters (PostgreSQL, MySQL, SQLite, DuckDB) represent NULL as ""
-- in their CSV output. The undo path must normalize "" → SQL NULL.
-- These tests drove the introduction of data.from_csv_raw().

local data = require("dadbod-grip.data")
local sql  = require("dadbod-grip.sql")

local NULL_SENTINEL = data.NULL_SENTINEL

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

local function no(s, pattern, msg)
  assert(not s:find(pattern, 1, true), (msg or "") .. ": must NOT contain '" .. pattern .. "' in: " .. s)
end

local function has(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

-- ── Helper: replicate init.lua's undo INSERT generation (fixed path) ─────────
-- Builds the reverse-INSERT SQL for a deleted row, using from_csv_raw().
local function build_undo_insert(table_name, columns, raw_row)
  local col_idx = {}
  for i, col in ipairs(columns) do col_idx[col] = i end
  local row_values = {}
  for _, col in ipairs(columns) do
    row_values[col] = data.from_csv_raw(raw_row[col_idx[col]])
  end
  return sql.build_insert(table_name, row_values, columns)
end

-- Builds the reverse-UPDATE SQL for changed columns, using from_csv_raw().
local function build_undo_update(table_name, pk_values, changed_cols, columns, raw_row)
  local col_idx = {}
  for i, col in ipairs(columns) do col_idx[col] = i end
  local orig_values = {}
  for _, col in ipairs(changed_cols) do
    orig_values[col] = data.from_csv_raw(raw_row[col_idx[col]])
  end
  return sql.build_update(table_name, pk_values, orig_values)
end

-- ── from_csv_raw() normalization ──────────────────────────────────────────────

test("from_csv_raw: nil → NULL_SENTINEL", function()
  eq(data.from_csv_raw(nil), NULL_SENTINEL)
end)

test("from_csv_raw: empty string → NULL_SENTINEL (CSV null for all 4 adapters)", function()
  eq(data.from_csv_raw(""), NULL_SENTINEL)
end)

test("from_csv_raw: 't' passes through (pg bool true)", function()
  eq(data.from_csv_raw("t"), "t")
end)

test("from_csv_raw: 'f' passes through (pg bool false)", function()
  eq(data.from_csv_raw("f"), "f")
end)

test("from_csv_raw: '1' passes through (mysql/sqlite bool true)", function()
  eq(data.from_csv_raw("1"), "1")
end)

test("from_csv_raw: '0' passes through (mysql/sqlite bool false)", function()
  eq(data.from_csv_raw("0"), "0")
end)

test("from_csv_raw: 'true' passes through (duckdb bool true)", function()
  eq(data.from_csv_raw("true"), "true")
end)

test("from_csv_raw: 'false' passes through (duckdb bool false)", function()
  eq(data.from_csv_raw("false"), "false")
end)

test("from_csv_raw: '(1,2)' passes through (pg point geometry)", function()
  eq(data.from_csv_raw("(1,2)"), "(1,2)")
end)

test("from_csv_raw: '[1,10)' passes through (pg int4range)", function()
  eq(data.from_csv_raw("[1,10)"), "[1,10)")
end)

test("from_csv_raw: real string passes through unchanged", function()
  eq(data.from_csv_raw("hello"), "hello")
end)

-- ── DELETE undo: INSERT reversal with NULL typed columns ──────────────────────
-- Columns: id(text), flag(boolean), small_num(integer)

local cols3 = { "id", "flag", "small_num" }

test("undo INSERT: pg bool NULL '' → emits SQL NULL not ''", function()
  -- row: id='3', flag=NULL(pg csv=""), small_num='5'
  local result = build_undo_insert("doopy", cols3, { "3", "", "5" })
  has(result, '"flag"', "flag column must be present")
  has(result, "NULL", "NULL bool must emit SQL NULL")
  no(result, "''", "must not emit empty string literal for NULL column")
end)

test("undo INSERT: mysql bool NULL '' → emits SQL NULL not ''", function()
  -- MySQL also uses "" for NULL in CSV
  local result = build_undo_insert("doopy", cols3, { "3", "", "5" })
  has(result, "NULL")
  no(result, "''")
end)

test("undo INSERT: duckdb bool NULL '' → emits SQL NULL not ''", function()
  -- DuckDB also uses "" for NULL in CSV
  local result = build_undo_insert("doopy", cols3, { "3", "", "5" })
  has(result, "NULL")
  no(result, "''")
end)

test("undo INSERT: multiple NULL columns → all emit SQL NULL", function()
  -- All nullable cols are NULL (full-null row except PK)
  local result = build_undo_insert("doopy", cols3, { "3", "", "" })
  -- Both flag and small_num NULL
  has(result, '"id"')
  has(result, '"flag"')
  has(result, '"small_num"')
  -- Count occurrences of NULL in VALUES
  local _, count = result:gsub("NULL", "NULL")
  assert(count >= 2, "expected 2+ NULL tokens, got " .. count .. " in: " .. result)
  no(result, "''")
end)

test("undo INSERT: mixed NULL and real values → only NULL cols emit NULL", function()
  -- flag=NULL, small_num=420 (real value)
  local result = build_undo_insert("doopy", cols3, { "3", "", "420" })
  has(result, "NULL", "flag must be NULL")
  has(result, "'420'", "small_num must be quoted '420'")
  no(result, "''")
end)

test("undo INSERT: pg geometry pt '(1,2)' → passes through as '(1,2)'", function()
  local cols = { "id", "pt" }
  local result = build_undo_insert("shapes", cols, { "1", "(1,2)" })
  has(result, "'(1,2)'")
  no(result, "NULL")
end)

test("undo INSERT: pg range '[1,10)' → passes through as '[1,10)'", function()
  local cols = { "id", "rng" }
  local result = build_undo_insert("ranges", cols, { "1", "[1,10)" })
  has(result, "'[1,10)'")
end)

test("undo INSERT: non-empty string gets single-quoted normally", function()
  local cols = { "id", "name" }
  local result = build_undo_insert("users", cols, { "5", "alice" })
  has(result, "'alice'")
  no(result, "NULL")
end)

test("undo INSERT: pg bool 't' survives round-trip (non-NULL)", function()
  local result = build_undo_insert("doopy", cols3, { "1", "t", "5" })
  has(result, "'t'")
  no(result, "NULL")
  no(result, "''")
end)

test("undo INSERT: pg bool 'f' survives round-trip (non-NULL)", function()
  local result = build_undo_insert("doopy", cols3, { "2", "f", "10" })
  has(result, "'f'")
  no(result, "NULL")
end)

test("undo INSERT: mysql/sqlite bool '0'/'1' survive round-trip", function()
  local result_true  = build_undo_insert("t", cols3, { "1", "1", "5" })
  local result_false = build_undo_insert("t", cols3, { "2", "0", "5" })
  has(result_true,  "'1'")
  has(result_false, "'0'")
end)

test("undo INSERT: duckdb 'true'/'false' survive round-trip", function()
  local result_t = build_undo_insert("t", cols3, { "1", "true",  "5" })
  local result_f = build_undo_insert("t", cols3, { "2", "false", "5" })
  has(result_t, "'true'")
  has(result_f, "'false'")
end)

-- ── UPDATE undo: restoring original NULL value ────────────────────────────────

test("undo UPDATE: original pg bool was NULL '' → SET col = NULL not ''", function()
  -- Row originally had flag=NULL. User changed it to something, now undoing.
  local result = build_undo_update("doopy", { id = "1" }, { "flag" }, cols3, { "1", "", "5" })
  has(result, '"flag" = NULL')
  no(result, "''")
end)

test("undo UPDATE: original mysql bool was NULL '' → SET col = NULL", function()
  local result = build_undo_update("doopy", { id = "1" }, { "flag" }, cols3, { "1", "", "5" })
  has(result, '"flag" = NULL')
  no(result, "''")
end)

test("undo UPDATE: original value was 't' → SET col = 't'", function()
  local result = build_undo_update("doopy", { id = "1" }, { "flag" }, cols3, { "1", "t", "5" })
  has(result, "\"flag\" = 't'")
  no(result, "NULL")
end)

test("undo UPDATE: multiple changed cols with some NULL → correct mix", function()
  -- flag was NULL, small_num was '100'
  local result = build_undo_update(
    "doopy", { id = "1" }, { "flag", "small_num" }, cols3, { "1", "", "100" }
  )
  has(result, '"flag" = NULL')
  has(result, "\"small_num\" = '100'")
  no(result, "''")
end)

-- ── Known limitation documentation ───────────────────────────────────────────

test("known limitation: empty string treated same as NULL (CSV ambiguity)", function()
  -- A TEXT NOT NULL DEFAULT '' column with value '' is indistinguishable from NULL
  -- in CSV output. Both produce SQL NULL in undo. Accepted trade-off: same behavior
  -- as effective_value() and clone_row() throughout the codebase.
  local result = build_undo_insert("t", { "id", "label" }, { "1", "" })
  -- "" in CSV → NULL in undo SQL (even if the real DB value was '')
  has(result, "NULL", "empty string treated as NULL (known limitation)")
end)

-- ── Summary ───────────────────────────────────────────────────────────────────
print(string.format("\nundo_sql_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
