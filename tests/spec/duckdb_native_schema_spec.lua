-- tests/spec/duckdb_native_schema_spec.lua
-- Regression: get_catalog_set scoping bug caused get_column_info to throw for ANY
-- schema-prefixed table name when the prefix was not in _attachments.
-- With old code: get_catalog_set referenced `duckdb` as a global (nil), so the
-- catalog-fallback path errored instead of falling through to the native-schema path.
-- This spec tests native DuckDB non-main schemas with NO registered attachments.
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

if vim.fn.executable("duckdb") ~= 1 then
  print("duckdb_native_schema_spec: SKIPPED (duckdb not found)")
  return
end

-- ── Setup: DuckDB with a native non-main schema ────────────────────────────────
local tmp      = vim.fn.tempname()
local db_path  = tmp .. "_native.duckdb"
local url      = "duckdb:" .. db_path

-- Seed: native schema "analytics" + a plain main-schema table
vim.fn.system(
  "duckdb " .. vim.fn.shellescape(db_path) ..
  [[ "CREATE SCHEMA analytics; ]] ..
  [[  CREATE TABLE analytics.events (id INTEGER, name VARCHAR, ts TIMESTAMP); ]] ..
  [[  CREATE TABLE main_table (x FLOAT);"]])

-- ── list_tables: native schemas appear with .schema field ──────────────────────
local tables, err = adapter.list_tables(url)
truthy(tables, "list_tables returns results")
eq(err, nil, "list_tables no error")

local found_events    = false
local found_main      = false
local events_has_schema = false
local main_has_schema   = false

for _, t in ipairs(tables or {}) do
  if t.name == "analytics.events" then
    found_events = true
    events_has_schema = t.schema == "analytics"
  end
  if t.name == "main_table" then
    found_main = true
    main_has_schema = t.schema ~= nil
  end
end

truthy(found_events,      "list_tables includes 'analytics.events'")
truthy(events_has_schema, "'analytics.events' has schema='analytics'")
truthy(found_main,        "list_tables includes 'main_table'")
eq(main_has_schema, false, "'main_table' has no .schema (main schema is flat)")

-- ── get_column_info: native-schema table (the regression path) ─────────────────
-- Before the scoping fix, get_catalog_set would call `duckdb` as a global nil,
-- throwing an error here. After the fix it falls through correctly to the
-- native-schema SQL branch.
local cols, col_err = adapter.get_column_info("analytics.events", url)
truthy(cols, "get_column_info returns results for native-schema table")
falsy(col_err, "get_column_info no error for native-schema table")
eq(#(cols or {}), 3, "analytics.events has 3 columns")

-- Verify column names and types
local col_map = {}
for _, c in ipairs(cols or {}) do col_map[c.column_name] = c.data_type end

eq(col_map["id"],   "INTEGER",   "id column is INTEGER")
eq(col_map["name"], "VARCHAR",   "name column is VARCHAR")
eq(col_map["ts"],   "TIMESTAMP", "ts column is TIMESTAMP")

-- ── get_column_info: main-schema table still works ─────────────────────────────
local main_cols, main_err = adapter.get_column_info("main_table", url)
truthy(main_cols, "get_column_info works for plain main-schema table")
falsy(main_err,   "no error for plain main-schema table")
eq(#(main_cols or {}), 1, "main_table has 1 column")
local main_col_map = {}
for _, c in ipairs(main_cols or {}) do main_col_map[c.column_name] = c.data_type end
eq(main_col_map["x"], "FLOAT", "x column is FLOAT")

-- ── Cleanup ────────────────────────────────────────────────────────────────────
os.remove(db_path)
os.remove(db_path .. ".wal")

print(string.format("\nduckdb_native_schema_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
