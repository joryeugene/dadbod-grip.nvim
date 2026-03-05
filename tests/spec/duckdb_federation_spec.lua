-- tests/spec/duckdb_federation_spec.lua: integration: list_tables with attachments
-- Requires: duckdb CLI, sqlite3 CLI
dofile("tests/minimal_init.lua")

local adapter = require("dadbod-grip.adapters.duckdb")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg, tostring(b), tostring(a)))
  end
end

local function truthy(v, msg)
  if v then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected truthy, got: %s", msg, tostring(v)))
  end
end

-- Skip if duckdb or sqlite3 not available
if vim.fn.executable("duckdb") ~= 1 or vim.fn.executable("sqlite3") ~= 1 then
  print("duckdb_federation_spec: SKIPPED (duckdb or sqlite3 not found)")
  return
end

-- Setup: create temp DuckDB + SQLite databases
local tmp = vim.fn.tempname()
local duck_path = tmp .. "_main.duckdb"
local sqlite_path = tmp .. "_attach.db"
local duck_url = "duckdb:" .. duck_path

-- Seed DuckDB with one table
vim.fn.system("duckdb " .. vim.fn.shellescape(duck_path)
  .. [[ "CREATE TABLE users (id INTEGER, name TEXT);"]])

-- Seed SQLite with two tables
vim.fn.system("sqlite3 " .. vim.fn.shellescape(sqlite_path)
  .. [[ "CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL); CREATE TABLE items (id INTEGER, order_id INTEGER);"]])

-- ── list_tables WITHOUT attachments: flat results, no .schema field ──

local tables, err = adapter.list_tables(duck_url)
truthy(tables, "list_tables returns results without attachments")
eq(err, nil, "no error without attachments")

local has_schema_field = false
for _, t in ipairs(tables or {}) do
  if t.schema then has_schema_field = true; break end
end
eq(has_schema_field, false, "no .schema field without attachments")

-- Find our 'users' table in flat results
local found_users = false
for _, t in ipairs(tables or {}) do
  if t.name == "users" then found_users = true; break end
end
eq(found_users, true, "flat list contains 'users'")

-- ── list_tables WITH attachments: schema-grouped results ──

adapter.attach(duck_url, "sqlite:" .. sqlite_path, "supplier")
tables, err = adapter.list_tables(duck_url)
truthy(tables, "list_tables returns results with attachments")
eq(err, nil, "no error with attachments")

-- Should have schema-grouped items
has_schema_field = false
for _, t in ipairs(tables or {}) do
  if t.schema then has_schema_field = true; break end
end
eq(has_schema_field, true, "items have .schema field when attachments exist")

-- Collect schemas present
local schemas = {}
for _, t in ipairs(tables or {}) do
  if t.schema then schemas[t.schema] = (schemas[t.schema] or 0) + 1 end
end

-- Must have both the main db and the supplier db
local main_schema = nil
for s, _ in pairs(schemas) do
  -- The main database schema name may vary (could be filename-based)
  -- but 'supplier' must be exactly 'supplier'
  if s ~= "supplier" then main_schema = s end
end
truthy(main_schema, "found main database schema")
truthy(schemas["supplier"], "found supplier schema")
eq(schemas["supplier"], 2, "supplier schema has 2 tables (orders + items)")

-- Each item should have name = "schema.table" format
local found_supplier_orders = false
local found_supplier_items = false
for _, t in ipairs(tables or {}) do
  if t.name == "supplier.orders" then found_supplier_orders = true end
  if t.name == "supplier.items" then found_supplier_items = true end
end
eq(found_supplier_orders, true, "supplier.orders in schema-grouped results")
eq(found_supplier_items, true, "supplier.items in schema-grouped results")

-- Main db users table keeps plain name (no schema prefix) for PK/column query compat
local found_main_users = false
for _, t in ipairs(tables or {}) do
  if t.schema and t.schema == main_schema and t.name == "users" then
    found_main_users = true
  end
end
eq(found_main_users, true, "main db users table present with plain name")

-- ── After detach: back to flat results ──

adapter.detach(duck_url, "supplier")
tables, err = adapter.list_tables(duck_url)
truthy(tables, "list_tables returns results after detach")

has_schema_field = false
for _, t in ipairs(tables or {}) do
  if t.schema then has_schema_field = true; break end
end
eq(has_schema_field, false, "no .schema field after detach")

-- Cleanup
vim.fn.delete(duck_path)
vim.fn.delete(sqlite_path)

print(string.format("\nduckdb_federation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
