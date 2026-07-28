-- tests/spec/duckdb_federated_schema_spec.lua
-- Regression: hardcoded schema_name='main' in get_column_info's catalog branch breaks
-- attached databases whose tables live in a non-main schema (PostgreSQL='public',
-- attached DuckDB with CREATE SCHEMA, etc.).
-- list_tables drops schema_name from attached catalogs, so get_column_info must
-- search by (database_name, table_name) only, not schema_name, for catalog tables.
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
  if v then pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected truthy, got: %s", msg, tostring(v)))
  end
end

local function falsy(v, msg)
  if not v then pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected falsy/nil, got: %s", msg, tostring(v)))
  end
end

-- CI sets GRIP_REQUIRE_DUCKDB so a missing binary fails instead of skipping:
-- the runner prints ALL TESTS PASSED either way.
if vim.fn.executable("duckdb") ~= 1 then
  if vim.env.GRIP_REQUIRE_DUCKDB == "1" then
    error("duckdb_federated_schema_spec: duckdb missing while GRIP_REQUIRE_DUCKDB=1")
  end
  print("duckdb_federated_schema_spec: SKIPPED (duckdb not found)")
  return
end

-- Setup: secondary DuckDB with a non-main schema (simulates PostgreSQL 'public', etc.)
local tmp        = vim.fn.tempname()
local main_path  = tmp .. "_main.duckdb"
local sec_path   = tmp .. "_secondary.duckdb"
local main_url   = "duckdb:" .. main_path

vim.fn.system(
  "duckdb " .. vim.fn.shellescape(sec_path) ..
  [[ "CREATE SCHEMA analytics; ]] ..
  [[  CREATE TABLE analytics.events (id INTEGER, name TEXT, score FLOAT);"]])

vim.fn.system(
  "duckdb " .. vim.fn.shellescape(main_path) ..
  [[ "CREATE TABLE local_table (x INTEGER);"]])

local att_err = adapter.attach(main_url, sec_path, "secondary")
eq(att_err, nil, "attach secondary with non-main schema succeeds")

-- list_tables: federated table appears under 'secondary' schema group
local tables, list_err = adapter.list_tables(main_url)
truthy(tables,   "list_tables returns results")
falsy(list_err,  "list_tables no error")

local found_events = false
local events_schema = nil
for _, t in ipairs(tables or {}) do
  if t.name == "secondary.events" then
    found_events = true
    events_schema = t.schema
  end
end
truthy(found_events, "list_tables includes 'secondary.events'")
eq(events_schema, "secondary", "'secondary.events' has schema='secondary'")

-- get_column_info: attached catalog with non-main schema
-- This was the failing case: hardcoded schema_name='main' returned 0 rows when the
-- attached DB's table lives in schema 'analytics'. Fix: remove schema_name from
-- the catalog-branch WHERE clause; filter by database_name + table_name only.
local cols, col_err = adapter.get_column_info("secondary.events", main_url)
truthy(cols,     "get_column_info returns results for non-main-schema federated table")
falsy(col_err,   "no error for non-main-schema federated table")
eq(#(cols or {}), 3, "secondary.events has 3 columns (id, name, score)")

local col_map = {}
for _, c in ipairs(cols or {}) do col_map[c.column_name] = c.data_type end
eq(col_map["id"],    "INTEGER", "id column is INTEGER")
eq(col_map["name"],  "VARCHAR", "name column is VARCHAR (DuckDB normalizes TEXT->VARCHAR)")
eq(col_map["score"], "FLOAT",   "score column is FLOAT")

-- main DB table still works (non-catalog path unaffected)
local main_cols, main_err = adapter.get_column_info("local_table", main_url)
truthy(main_cols,  "get_column_info works for main DB table")
falsy(main_err,    "no error for main DB table")
eq(#(main_cols or {}), 1, "local_table has 1 column")

-- Cleanup
adapter.detach(main_url, "secondary")
os.remove(main_path)
os.remove(sec_path)

print(string.format("\nduckdb_federated_schema_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
