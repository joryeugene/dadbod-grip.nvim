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
  local orig_list = db.list_tables
  local orig_cols = db.get_column_info

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
    db.list_tables = orig_list
    db.get_column_info = orig_cols
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

-- ── summary ───────────────────────────────────────────────────────────────────
print(string.format("\ncompletion_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
