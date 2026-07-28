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

-- ── get_column_info for attached catalog tables ──────────────────────────────
-- supplier.orders is an attached table; adapter must use supplier.information_schema

local cols, col_err = adapter.get_column_info("supplier.orders", duck_url)
truthy(cols, "get_column_info: returns columns for supplier.orders")
eq(col_err, nil, "get_column_info: no error for supplier.orders")

local found_order_id = false
for _, c in ipairs(cols or {}) do
  if c.column_name == "id" then found_order_id = true; break end
end
eq(found_order_id, true, "get_column_info: found 'id' column in supplier.orders")

-- Main DB table still works
local main_cols, main_err = adapter.get_column_info("users", duck_url)
truthy(main_cols, "get_column_info: main DB table 'users' still works")
eq(main_err, nil, "get_column_info: no error for main DB users")

-- ── get_indexes for attached catalog tables ────────────────────────────────
-- SQLite PRIMARY KEY on orders.id → duckdb_indexes() should find it when
-- correctly filtered by database_name = 'supplier' AND schema_name = 'main'

local idxs, idx_err = adapter.get_indexes("supplier.orders", duck_url)
-- No error expected; empty list is acceptable if SQLite scanner doesn't expose indexes
truthy(idxs ~= nil, "get_indexes: no nil return for supplier.orders")
eq(idx_err, nil, "get_indexes: no error for supplier.orders")

-- ── get_constraints for attached catalog tables ────────────────────────────
local constrs, cstr_err = adapter.get_constraints("supplier.orders", duck_url)
truthy(constrs ~= nil, "get_constraints: no nil return for supplier.orders")
eq(cstr_err, nil, "get_constraints: no error for supplier.orders")

-- ── get_schema_batch with attachments: main-DB columns preserved ────────────
-- When has_attachments=true, main DB tables must have full column info.
-- Attached-catalog tables must be names-only (empty column array).
-- The previous regression stored {} for ALL tables, causing SELECT col → only keywords.

local batch = adapter.get_schema_batch(duck_url)
truthy(batch, "get_schema_batch with attachments: returns non-nil")

local users_batch_cols = batch and batch["users"]
truthy(users_batch_cols, "get_schema_batch: 'users' table present in batch")
truthy(users_batch_cols and #users_batch_cols > 0,
  "get_schema_batch: 'users' has column info when attachments exist (not empty array)")

local found_id_col = false
for _, c in ipairs(users_batch_cols or {}) do
  if c.column_name == "id" then found_id_col = true; break end
end
eq(found_id_col, true, "get_schema_batch: 'users.id' column present in batch result")

local orders_batch_cols = batch and batch["supplier.orders"]
truthy(orders_batch_cols ~= nil, "get_schema_batch: 'supplier.orders' present in batch")
truthy(orders_batch_cols and #orders_batch_cols > 0,
  "get_schema_batch: 'supplier.orders' has column info (federated columns from attached catalog)")

-- ── list_tables with native schema (no attachments) ────────────────────────
-- Create a native DuckDB schema on a fresh DB, verify schema-prefixed names appear.
local native_duck_path = tmp .. "_native.duckdb"
local native_url = "duckdb:" .. native_duck_path
vim.fn.system("duckdb " .. vim.fn.shellescape(native_duck_path)
  .. [[ "CREATE SCHEMA analytics; CREATE TABLE analytics.events (id INTEGER, ts TIMESTAMP);"]])

local native_tables, native_err = adapter.list_tables(native_url)
truthy(native_tables, "native schema: list_tables returns results")
eq(native_err, nil, "native schema: no error")

local found_analytics_events = false
for _, t in ipairs(native_tables or {}) do
  if t.name == "analytics.events" then found_analytics_events = true; break end
end
eq(found_analytics_events, true, "native schema: analytics.events in results with prefix")

local native_cols = adapter.get_column_info("analytics.events", native_url)
truthy(native_cols, "native schema: get_column_info works for analytics.events")

vim.fn.delete(native_duck_path)

-- ── After detach: back to flat results ──

adapter.detach(duck_url, "supplier")
tables, err = adapter.list_tables(duck_url)
truthy(tables, "list_tables returns results after detach")
eq(err, nil, "no error after detach")

has_schema_field = false
for _, t in ipairs(tables or {}) do
  if t.schema then has_schema_field = true; break end
end
eq(has_schema_field, false, "no .schema field after detach")

-- ── M.attach() validation must use in-memory mode (no write lock on main db) ──
-- When validation opens the actual db_path, it acquires a DuckDB write lock.
-- If warm_schema's async process also holds the lock, list_tables fails with
-- "unable to open database: Failed to lock file" (the real production bug).
-- Proof: attach with a URL whose path cannot be created (nonexistent dir).
-- Memory-mode validation succeeds regardless; db_path-mode validation fails.

local fake_url = "duckdb:/tmp/grip_nonexistent_dir_" .. tostring(math.random(1e9)) .. "/test.duckdb"
local mem_sqlite = tmp .. "_mem_test.db"
vim.fn.system("sqlite3 " .. vim.fn.shellescape(mem_sqlite) .. [[ "CREATE TABLE mt (id INTEGER);"]])
local mem_err = adapter.attach(fake_url, "sqlite:" .. mem_sqlite, "mem_test")
eq(mem_err, nil, "attach validation: must use memory mode (not open main db path)")
vim.fn.delete(mem_sqlite)

-- Cleanup
vim.fn.delete(duck_path)
vim.fn.delete(sqlite_path)

print(string.format("\nduckdb_federation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
