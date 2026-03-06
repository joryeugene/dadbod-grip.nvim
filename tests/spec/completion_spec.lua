-- tests/spec/completion_spec.lua: unit tests for completion.lua
-- TDD: written before the implementation. All tests start RED.
dofile("tests/minimal_init.lua")

local completion = require("dadbod-grip.completion")
local db = require("dadbod-grip.db")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg or "eq", tostring(b), tostring(a)))
  end
end

local function ok(v, msg)
  if v then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. (msg or "expected truthy, got nil/false"))
  end
end

local function not_nil(v, msg)
  if v ~= nil then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. (msg or "expected non-nil, got nil"))
  end
end

-- ── parse_context (pure function, no mocks needed) ────────────────────────────

-- Helper: parse_context receives the text before the cursor.
-- Returns { type, word, qualifier?, alias?, table? } or nil.
local pc = completion.parse_context

-- Table context: after FROM / JOIN / UPDATE / INSERT INTO
eq(pc("SELECT * FROM "), "table",  "FROM: table context type")
eq(pc("SELECT * FROM use"), "table", "FROM partial word: table context")
eq(pc("select * from "), "table",  "FROM lowercase: table context")
eq(pc("JOIN "), "table",           "JOIN: table context")
eq(pc("LEFT JOIN "), "table",      "LEFT JOIN: table context")
eq(pc("INNER JOIN "), "table",     "INNER JOIN: table context")
eq(pc("UPDATE "), "table",         "UPDATE: table context")
eq(pc("INSERT INTO "), "table",    "INSERT INTO: table context")

-- Column context: after SELECT / WHERE / ORDER BY / GROUP BY / HAVING
eq(pc("SELECT "), "column",        "SELECT: column context")
eq(pc("SELECT id, "), "column",    "SELECT after comma: column context")
eq(pc("WHERE "), "column",         "WHERE: column context")
eq(pc("ORDER BY "), "column",      "ORDER BY: column context")
eq(pc("GROUP BY "), "column",      "GROUP BY: column context")
eq(pc("HAVING "), "column",        "HAVING: column context")
eq(pc("select "), "column",        "select lowercase: column context")

-- Dotted context: after qualifier. (table or attachment)
local ctx = completion.parse_context_full("SELECT s.")
not_nil(ctx, "dotted SELECT s.: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted: type")
eq(ctx and ctx.qualifier, "s",           "dotted: qualifier")
eq(ctx and ctx.word, "",                 "dotted: empty word")

ctx = completion.parse_context_full("FROM supplier.")
not_nil(ctx, "dotted FROM supplier.: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted FROM: type")
eq(ctx and ctx.qualifier, "supplier",    "dotted FROM: qualifier")

ctx = completion.parse_context_full("FROM supplier.shi")
not_nil(ctx, "dotted partial word: non-nil")
eq(ctx and ctx.type, "dotted",           "dotted partial: type")
eq(ctx and ctx.qualifier, "supplier",    "dotted partial: qualifier")
eq(ctx and ctx.word, "shi",              "dotted partial: word")

ctx = completion.parse_context_full("JOIN main.")
eq(ctx and ctx.type, "dotted",           "dotted JOIN main.: type")
eq(ctx and ctx.qualifier, "main",        "dotted JOIN main.: qualifier")

-- Federation column context: after alias.table. (three-part)
ctx = completion.parse_context_full("WHERE supplier.shipments.")
not_nil(ctx, "fed_column WHERE supplier.shipments.: non-nil")
eq(ctx and ctx.type, "fed_column",            "fed_column: type")
eq(ctx and ctx.alias, "supplier",             "fed_column: alias")
eq(ctx and ctx.table, "shipments",            "fed_column: table")
eq(ctx and ctx.word, "",                      "fed_column: empty word")

ctx = completion.parse_context_full("ORDER BY supplier.shipments.col")
eq(ctx and ctx.type, "fed_column",            "fed_column ORDER BY: type")
eq(ctx and ctx.alias, "supplier",             "fed_column ORDER BY: alias")
eq(ctx and ctx.table, "shipments",            "fed_column ORDER BY: table")
eq(ctx and ctx.word, "col",                   "fed_column ORDER BY: partial word")

ctx = completion.parse_context_full("SELECT s.shipments.dec")
eq(ctx and ctx.type, "fed_column",            "fed_column SELECT: type")
eq(ctx and ctx.alias, "s",                    "fed_column SELECT: alias")
eq(ctx and ctx.table, "shipments",            "fed_column SELECT: table")
eq(ctx and ctx.word, "dec",                   "fed_column SELECT: word")

-- Nil: no recognizable context
eq(completion.parse_context(""), nil,         "empty string: nil")
eq(completion.parse_context("--"), nil,       "comment: nil")

-- ── Schema cache + completion items ──────────────────────────────────────────
-- Mock db.list_tables and db.get_column_info to avoid real DB calls.

local function mock_db(tables_by_name)
  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_batch = db.get_schema_batch

  -- Return nil from batch so tests exercise the per-table fallback path
  -- (avoids real DuckDB CLI invocations in unit tests).
  db.get_schema_batch = function(url) return nil end

  db.list_tables = function(url)
    local result = {}
    for name, _ in pairs(tables_by_name) do
      table.insert(result, { name = name })
    end
    return result, nil
  end

  db.get_column_info = function(table_name, url)
    return tables_by_name[table_name] or {}, nil
  end

  return function()
    db.list_tables      = orig_list
    db.get_column_info  = orig_cols
    db.get_schema_batch = orig_batch
  end
end

local PG_URL   = "postgresql://localhost/test"
local MYSQL_URL = "mysql://root:pass@localhost/testdb"
local SQLITE_URL = "sqlite:test.db"
local DUCK_URL  = "duckdb:test.duckdb"

local USERS_COLS = {
  { column_name = "id",    data_type = "integer",  is_nullable = "NO"  },
  { column_name = "email", data_type = "text",     is_nullable = "NO"  },
  { column_name = "name",  data_type = "text",     is_nullable = "YES" },
}
local ORDERS_COLS = {
  { column_name = "id",       data_type = "integer", is_nullable = "NO"  },
  { column_name = "user_id",  data_type = "integer", is_nullable = "NO"  },
  { column_name = "total",    data_type = "numeric", is_nullable = "YES" },
}

-- Postgres: table completions
do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("SELECT * FROM ", PG_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["users"],  "pg: users in table completions")
  ok(names["orders"], "pg: orders in table completions")
  restore()
end

-- Postgres: column completions (returns all known columns from all tables)
do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("SELECT ", PG_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["id"],      "pg: id in column completions")
  ok(names["email"],   "pg: email in column completions")
  ok(names["user_id"], "pg: user_id in column completions")
  ok(names["total"],   "pg: total in column completions")
  restore()
end

-- MySQL: same contract, different URL
do
  local restore = mock_db({ customers = {
    { column_name = "cust_id", data_type = "int", is_nullable = "NO" },
    { column_name = "region",  data_type = "varchar", is_nullable = "YES" },
  }})
  completion.invalidate(MYSQL_URL)
  local items = completion.complete("FROM ", MYSQL_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["customers"], "mysql: customers in table completions")
  restore()
end

-- SQLite: PRAGMA-style column info (same field names)
do
  local restore = mock_db({ products = {
    { column_name = "sku",   data_type = "TEXT",    is_nullable = "YES" },
    { column_name = "price", data_type = "REAL",    is_nullable = "YES" },
  }})
  completion.invalidate(SQLITE_URL)
  local items = completion.complete("SELECT ", SQLITE_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["sku"],   "sqlite: sku in column completions")
  ok(names["price"], "sqlite: price in column completions")
  restore()
end

-- DuckDB single-DB: table completion
do
  local restore = mock_db({ shipments = {
    { column_name = "ship_date",        data_type = "DATE",    is_nullable = "NO"  },
    { column_name = "declared_contents",data_type = "VARCHAR", is_nullable = "YES" },
  }})
  completion.invalidate(DUCK_URL)
  local items = completion.complete("FROM ", DUCK_URL)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"], "duckdb: shipments in table completions")
  restore()
end

-- ── Cache invalidation ────────────────────────────────────────────────────────

do
  local call_count = 0
  local orig_list = db.list_tables
  local orig_cols = db.get_column_info

  db.list_tables = function(url)
    call_count = call_count + 1
    return { { name = "t" } }, nil
  end
  db.get_column_info = function(tn, url)
    return { { column_name = "id", data_type = "integer", is_nullable = "NO" } }, nil
  end

  local url = "postgresql://localhost/cache_test"
  completion.invalidate(url)
  completion.complete("FROM ", url)
  completion.complete("FROM ", url)  -- second call: should use cache
  eq(call_count, 1, "cache: list_tables called only once on second complete")

  completion.invalidate(url)
  completion.complete("FROM ", url)
  eq(call_count, 2, "cache: list_tables called again after invalidate")

  db.list_tables = orig_list
  db.get_column_info = orig_cols
end

-- ── Dotted qualifier: column completion from named table ──────────────────────

do
  local restore = mock_db({ users = USERS_COLS, orders = ORDERS_COLS })
  completion.invalidate(PG_URL)
  -- "FROM users u SELECT u." -> columns of users
  local items = completion.complete("SELECT u.", PG_URL, { ["u"] = "users" })
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["id"],    "dotted: u.id from users alias")
  ok(names["email"], "dotted: u.email from users alias")
  restore()
end

-- ── Completion item structure ─────────────────────────────────────────────────

do
  local restore = mock_db({ users = USERS_COLS })
  completion.invalidate(PG_URL)
  local items = completion.complete("FROM ", PG_URL)
  local first = items[1]
  not_nil(first,            "item exists")
  not_nil(first.word,       "item has word")
  not_nil(first.menu,       "item has menu annotation")
  restore()
end

-- ── extract_aliases ───────────────────────────────────────────────────────────

local ea = completion.extract_aliases

-- FROM table alias (no AS)
do
  local a = ea("SELECT * FROM employees e WHERE e.id = 1")
  eq(a["e"], "employees", "extract: FROM table alias")
end

-- FROM table AS alias
do
  local a = ea("SELECT * FROM employees AS e")
  eq(a["e"], "employees", "extract: FROM table AS alias")
end

-- JOIN table alias
do
  local a = ea("FROM orders o JOIN employees e ON o.emp_id = e.id")
  eq(a["o"], "orders",    "extract: JOIN o=orders")
  eq(a["e"], "employees", "extract: JOIN e=employees")
end

-- Multi-join: FROM + two JOINs
do
  local a = ea("SELECT * FROM orders o JOIN employees e ON e.id = o.emp_id JOIN departments d ON d.id = e.dept_id")
  eq(a["o"], "orders",      "extract: multi o=orders")
  eq(a["e"], "employees",   "extract: multi e=employees")
  eq(a["d"], "departments", "extract: multi d=departments")
end

-- SQL keyword as alias is skipped (FROM employees WHERE)
do
  local a = ea("SELECT * FROM employees WHERE id = 1")
  eq(a["where"], nil, "extract: WHERE is not an alias")
end

-- No aliases in a plain single-table query
do
  local a = ea("SELECT id, name FROM employees")
  eq(next(a), nil, "extract: no aliases in simple query")
end

-- AS form wins over bare form for the same alias key
do
  local a = ea("FROM employees AS e JOIN employees e ON true")
  eq(a["e"], "employees", "extract: AS form preserved")
end

-- Alias tracking integrates with complete() via dotted context
do
  local restore = mock_db({ employees = {
    { column_name = "emp_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "emp_name", data_type = "text",    is_nullable = "YES" },
  }})
  completion.invalidate(PG_URL)
  -- full_sql contains the alias declaration; before-cursor is the dotted access
  local full_sql = "SELECT e.emp_name FROM employees e WHERE e."
  local aliases  = ea(full_sql)
  local items    = completion.complete("SELECT e.", PG_URL, aliases)
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["emp_id"],   "alias+complete: emp_id via alias e")
  ok(names["emp_name"], "alias+complete: emp_name via alias e")
  restore()
end

-- ── DuckDB federation: dotted cache prefix scan ───────────────────────────────
-- When the schema cache has "supplier.shipments" keys, typing "supplier." or
-- "supplier.sh" should return tables from cache without a live query.
do
  local FED_URL = "duckdb:softrear.duckdb"
  local SHIP_COLS = {
    { column_name = "ship_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "ship_date", data_type = "date",    is_nullable = "NO"  },
  }
  local ORD_COLS = {
    { column_name = "order_id",  data_type = "integer", is_nullable = "NO"  },
    { column_name = "amount",    data_type = "numeric",  is_nullable = "YES" },
  }
  -- Mock the schema cache with federation-prefixed keys
  local restore = mock_db({
    ["supplier.shipments"] = SHIP_COLS,
    ["supplier.orders"]    = ORD_COLS,
    ["main_table"]         = { { column_name = "id", data_type = "integer", is_nullable = "NO" } },
  })
  completion.invalidate(FED_URL)

  -- "supplier." -> should complete tables from cache
  local items = completion.complete("FROM supplier.", FED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"],  "fed dotted: shipments from cache")
  ok(names["orders"],     "fed dotted: orders from cache")
  ok(not names["main_table"], "fed dotted: main_table not included")

  -- "supplier.sh" -> prefix filter applies
  items = completion.complete("FROM supplier.sh", FED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["shipments"],  "fed dotted partial: shipments matches 'sh'")
  ok(not names["orders"], "fed dotted partial: orders doesn't match 'sh'")

  restore()
end

-- ── DuckDB federation: fed_column cache lookup ────────────────────────────────
-- When the schema cache has "supplier.shipments" column data, typing
-- "supplier.shipments." should return columns from cache, not a live query.
do
  local FED_URL = "duckdb:softrear.duckdb"
  local SHIP_COLS = {
    { column_name = "ship_id",   data_type = "integer", is_nullable = "NO"  },
    { column_name = "ship_date", data_type = "date",    is_nullable = "NO"  },
    { column_name = "declared",  data_type = "varchar",  is_nullable = "YES" },
  }
  local restore = mock_db({ ["supplier.shipments"] = SHIP_COLS })
  completion.invalidate(FED_URL)

  -- "supplier.shipments." -> columns from cache
  local items = completion.complete("WHERE supplier.shipments.", FED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["ship_id"],   "fed_column cache: ship_id")
  ok(names["ship_date"], "fed_column cache: ship_date")
  ok(names["declared"],  "fed_column cache: declared")

  -- "supplier.shipments.sh" -> prefix filter
  items = completion.complete("WHERE supplier.shipments.sh", FED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["ship_id"],     "fed_column prefix: ship_id matches 'sh'")
  ok(names["ship_date"],   "fed_column prefix: ship_date matches 'sh'")
  ok(not names["declared"], "fed_column prefix: declared doesn't match 'sh'")

  restore()
end

-- ── Auto-trigger: dotted context guard ───────────────────────────────────────
-- parse_context("supplier.") should return "dotted" so the auto-trigger
-- detects dotted context even when word == "".
do
  local ctx = completion.parse_context_full("FROM supplier.")
  eq(ctx and ctx.type, "dotted", "auto-trigger guard: dotted context detected after '.'")
  eq(ctx and ctx.qualifier, "supplier", "auto-trigger guard: qualifier is 'supplier'")
  eq(ctx and ctx.word, "", "auto-trigger guard: word is empty after '.'")

  -- Ensure before:match("[%w_]+%.[%w_]*$") fires for the guard condition
  local before = "FROM supplier."
  local in_dotted = before:match("[%w_]+%.[%w_]*$") ~= nil
  ok(in_dotted, "auto-trigger guard: dotted pattern matches 'supplier.'")

  local before2 = "FROM "
  local not_dotted = before2:match("[%w_]+%.[%w_]*$") ~= nil
  ok(not not_dotted, "auto-trigger guard: plain FROM does not match dotted pattern")
end

-- ── DuckDB federation: live-query fallback for SQLite attachments ─────────────
-- When the schema cache is empty (e.g. first keystroke after GripAttach before
-- get_schema has populated it), the dotted handler falls to a live query.
-- The OLD fallback used b.information_schema.tables which fails for SQLite.
-- The NEW fallback must use duckdb_tables() WHERE database_name = 'b' instead.
do
  local ATT_URL = "duckdb:" .. vim.fn.tempname() .. "_attach_fallback_test.duckdb"
  local duckdb_adapter = require("dadbod-grip.adapters.duckdb")

  -- Register "b" as a SQLite attachment (no real DuckDB needed for this test)
  duckdb_adapter._attach_unchecked(ATT_URL, "sqlite:/tmp/test_butts.db", "b")

  -- Force cache miss: list_tables returns empty so "b.butts" is NOT in schema cache
  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_query = db.query

  db.list_tables     = function(url) return {}, nil end
  db.get_column_info = function(tn, url) return {}, nil end

  -- Mock db.query to simulate responses:
  -- information_schema → fails (SQLite has no information_schema)
  -- duckdb_tables()    → returns the "butts" table (correct fallback)
  db.query = function(sql, url)
    if sql:find("information_schema") then
      return nil, "Catalog Error: b.information_schema does not exist"
    end
    if sql:find("duckdb_tables") and sql:find("database_name") then
      return { rows = { {"butts"} }, columns = {"table_name"} }, nil
    end
    return nil, "unexpected query in test: " .. tostring(sql)
  end

  completion.invalidate(ATT_URL)
  local items = completion.complete("SELECT b.", ATT_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  -- This assertion drives the fix: "butts" must appear even when
  -- the schema cache is cold and the live fallback must run.
  ok(names["butts"],
     "attached SQLite alias 'b': 'butts' appears in 'SELECT b.' via live fallback")

  -- Cleanup
  duckdb_adapter.detach(ATT_URL, "b")
  db.list_tables     = orig_list
  db.get_column_info = orig_cols
  db.query           = orig_query
end


-- ── DuckDB federation: fed_column fallback for SQLite attachments ─────────────
-- Three-part "b.butts.col" when schema cache is cold should use duckdb_columns(),
-- not b.information_schema.columns (SQLite has no information_schema).
do
  local ATT2_URL = "duckdb:" .. vim.fn.tempname() .. "_fed_col_fallback_test.duckdb"
  local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
  duckdb_adapter._attach_unchecked(ATT2_URL, "sqlite:/tmp/test_butts2.db", "b")

  local orig_list  = db.list_tables
  local orig_cols  = db.get_column_info
  local orig_query = db.query

  db.list_tables     = function(url) return {}, nil end
  db.get_column_info = function(tn, url) return {}, nil end

  db.query = function(sql, url)
    if sql:find("information_schema") then
      return nil, "Catalog Error: b.information_schema does not exist"
    end
    if sql:find("duckdb_columns") and sql:find("database_name") then
      return { rows = { {"id", "INTEGER"}, {"weight", "DOUBLE"} }, columns = {"column_name","data_type"} }, nil
    end
    return nil, "unexpected query: " .. tostring(sql)
  end

  completion.invalidate(ATT2_URL)
  local items = completion.complete("SELECT b.butts.", ATT2_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["id"],     "fed_column SQLite fallback: 'id' column via duckdb_columns()")
  ok(names["weight"], "fed_column SQLite fallback: 'weight' column via duckdb_columns()")

  duckdb_adapter.detach(ATT2_URL, "b")
  db.list_tables     = orig_list
  db.get_column_info = orig_cols
  db.query           = orig_query
end

-- ── table context: bare-name match for federated schema keys ─────────────────
-- Typing "FROM bu" with schema {"grip_test.butts": {}} must suggest "grip_test.butts".
-- The table part "butts" starts with "bu" even though the full key "grip_test.butts" does not.
do
  local FED_TABLE_URL = "duckdb:fed_table_match_test.duckdb"

  local orig_batch = db.get_schema_batch
  -- Schema has a federated table and a plain main-DB table
  db.get_schema_batch = function(url)
    return {
      ["grip_test.butts"] = {},
      ["users"] = {
        { column_name = "id", data_type = "integer", is_nullable = "NO" },
      },
    }
  end

  completion.invalidate(FED_TABLE_URL)

  -- "FROM bu" → bare-name match: "butts" in "grip_test.butts" starts with "bu"
  local items = completion.complete("SELECT * FROM bu", FED_TABLE_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["grip_test.butts"], "table bare-name match: 'FROM bu' finds 'grip_test.butts'")
  ok(not names["users"],       "table bare-name match: 'FROM bu' does not find 'users'")

  -- "FROM us" → direct prefix match: "users" starts with "us"
  items = completion.complete("SELECT * FROM us", FED_TABLE_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["users"],               "table direct match: 'FROM us' finds 'users'")
  ok(not names["grip_test.butts"], "table direct match: 'FROM us' does not find 'grip_test.butts'")

  -- "FROM " (empty word) → all tables, no double-add from bare match
  items = completion.complete("SELECT * FROM ", FED_TABLE_URL, {})
  local counts = {}
  for _, it in ipairs(items) do counts[it.word] = (counts[it.word] or 0) + 1 end
  ok(counts["grip_test.butts"] == 1, "table empty word: 'grip_test.butts' appears exactly once")
  ok(counts["users"] == 1,           "table empty word: 'users' appears exactly once")

  db.get_schema_batch = orig_batch
end

-- ── fed_column: empty cached_cols must fire live fallback ─────────────────────
-- When get_schema_batch returns table-names-only {"b.butts" -> {}}, typing
-- "b.butts." must still return columns via the live duckdb_columns() fallback.
-- Lua's empty-table truthiness makes {} truthy, so "if cached_cols then" is
-- the bug: it enters the cache branch, iterates zero rows, and returns nothing.
-- Fix: "if cached_cols and #cached_cols > 0 then" correctly falls through.
do
  local BATCH_URL = "duckdb:batch_empty_cols_test.duckdb"

  local orig_batch = db.get_schema_batch
  local orig_query = db.query

  -- Simulate table-names-only batch: key exists but column array is empty
  db.get_schema_batch = function(url) return { ["b.butts"] = {} } end

  -- Live fallback must be called and return columns
  db.query = function(sql, url)
    if sql:find("duckdb_columns") then
      return { rows = { {"id", "INTEGER"}, {"weight", "DOUBLE"} }, columns = {"column_name","data_type"} }, nil
    end
    return nil, "unexpected query: " .. tostring(sql)
  end

  completion.invalidate(BATCH_URL)
  local items = completion.complete("SELECT b.butts.", BATCH_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["id"],     "fed_column empty-cache live fallback: 'id' column appears")
  ok(names["weight"], "fed_column empty-cache live fallback: 'weight' column appears")

  db.get_schema_batch = orig_batch
  db.query            = orig_query
end

-- ── dotted: table-names-only batch still surfaces table names for alias. ───────
-- When get_schema_batch returns {"b.butts": {}, "b.orders": {}}, typing "b."
-- must still show "butts" and "orders" via the cache prefix scan. The scan
-- iterates schema keys (not values), so empty column arrays don't matter here.
do
  local BATCH2_URL = "duckdb:batch_dotted_test.duckdb"

  local orig_batch = db.get_schema_batch
  db.get_schema_batch = function(url) return { ["b.butts"] = {}, ["b.orders"] = {} } end

  completion.invalidate(BATCH2_URL)
  local items = completion.complete("SELECT b.", BATCH2_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["butts"],  "dotted names-only batch: 'butts' appears for 'b.'")
  ok(names["orders"], "dotted names-only batch: 'orders' appears for 'b.'")

  db.get_schema_batch = orig_batch
end

-- ── column context: main DB columns must survive when attachments exist ───────
-- Regression guard: when get_schema_batch returns a CORRECT mixed result
-- (main DB table has columns, attached table is names-only), SELECT b must
-- surface main DB column completions. If batch incorrectly returns all-empty,
-- no columns are found and only keywords like BETWEEN appear.
do
  local MIXED_URL = "duckdb:mixed_batch_col_test.duckdb"
  local orig_batch = db.get_schema_batch

  -- Simulate the CORRECT mixed-batch output that the fixed get_schema_batch must return:
  -- main DB table "employees" has full column info;
  -- attached catalog table "grip_test.butts" is names-only (empty array).
  db.get_schema_batch = function(url)
    return {
      ["employees"] = {
        { column_name = "budget",      data_type = "DECIMAL" },
        { column_name = "name",        data_type = "TEXT" },
        { column_name = "bonus_pct",   data_type = "REAL" },
      },
      ["grip_test.butts"] = {},
    }
  end

  completion.invalidate(MIXED_URL)

  -- SELECT b → column context: must find "budget" and "bonus_pct" from employees
  local items = completion.complete("SELECT b", MIXED_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end

  ok(names["budget"],    "mixed batch col ctx: 'budget' column appears for SELECT b")
  ok(names["bonus_pct"], "mixed batch col ctx: 'bonus_pct' column appears for SELECT b")
  -- If the regression were present (all-empty batch), names would be empty here
  -- and only keyword "BETWEEN" would appear via the keyword fallback.

  -- SELECT n → must find "name"
  items = completion.complete("SELECT n", MIXED_URL, {})
  names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["name"], "mixed batch col ctx: 'name' column appears for SELECT n")

  db.get_schema_batch = orig_batch
end

-- ── warm_schema: populates cache so columns are available before first keypress ──
do
  local WARM_URL = "duckdb:warm_schema_test.duckdb"
  local orig_batch_async = db.get_schema_batch_async

  local async_called = false
  db.get_schema_batch_async = function(url, callback)
    async_called = true
    -- Simulate async result arriving synchronously for test purposes
    callback({
      ["warm_table"] = {
        { column_name = "warm_col", data_type = "TEXT" },
      },
    })
  end

  completion.invalidate(WARM_URL)
  completion.warm_schema(WARM_URL)

  ok(async_called, "warm_schema: calls get_schema_batch_async")

  -- After warm_schema, SELECT w must find warm_col (cache is populated)
  local items = completion.complete("SELECT w", WARM_URL, {})
  local names = {}
  for _, it in ipairs(items) do names[it.word] = true end
  ok(names["warm_col"], "warm_schema: column available after pre-warm")

  db.get_schema_batch_async = orig_batch_async
end

-- ── summary ───────────────────────────────────────────────────────────────────
print(string.format("\ncompletion_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
