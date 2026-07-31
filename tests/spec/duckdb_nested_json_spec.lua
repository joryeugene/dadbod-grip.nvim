-- tests/spec/duckdb_nested_json_spec.lua: DuckDB nested types come back as JSON.
--
-- In CSV mode DuckDB serialises STRUCT/LIST/MAP/UNION with its own literal
-- syntax -- single-quoted keys, *unquoted* string values: {'k': v}. That is not
-- JSON, and it cannot be recovered by parsing (an unquoted string may itself
-- contain , { } '), so gK's tree ("Not a JSON cell") and gB's pretty-printer
-- both failed on exactly the cells they exist for. The adapter now asks DuckDB
-- for to_json() on nested columns instead of reconstructing anything.
--
-- Pure part: the statement rewriter (no binary needed).
-- Integration part: real duckdb CLI, file-as-table and a real STRUCT column.
-- Requires: duckdb CLI
dofile("tests/minimal_init.lua")

local adapter     = require("dadbod-grip.adapters.duckdb")
local json_tree   = require("dadbod-grip.json_tree")
local cell_buffer = require("dadbod-grip.cell_buffer")

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

local function nil_eq(v, msg)
  if v == nil then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected nil, got: %s", msg, tostring(v)))
  end
end

-- ── pure: the statement rewriter ─────────────────────────────────────────────

local rewrite = adapter._nested_json_sql

truthy(rewrite("SELECT * FROM t"), "rewrites a plain SELECT")
truthy(rewrite("  \n WITH x AS (SELECT 1) SELECT * FROM x"), "rewrites a CTE after whitespace")
truthy(rewrite("FROM range(3)"), "rewrites DuckDB FROM-first syntax")
truthy(rewrite("VALUES (1), (2)"), "rewrites VALUES")
truthy(rewrite("-- lead comment\nSELECT 1"), "rewrites past a leading line comment")
truthy(rewrite("/* lead */ SELECT 1"), "rewrites past a leading block comment")

-- Statements a subquery cannot hold must pass through untouched: db.describe_file
-- and schema.lua's file-column probe both send DESCRIBE through adapter.query.
nil_eq(rewrite("DESCRIBE SELECT * FROM 'f.parquet' LIMIT 0"), "DESCRIBE is not rewritten")
nil_eq(rewrite("SET threads = 2"), "SET is not rewritten")
nil_eq(rewrite("PRAGMA database_list"), "PRAGMA is not rewritten")
nil_eq(rewrite("INSTALL httpfs"), "INSTALL is not rewritten")
nil_eq(rewrite(""), "empty string is not rewritten")

-- A trailing semicolon would land inside the subquery parens and break parsing.
local semi = rewrite("SELECT 1;")
truthy(semi, "rewrites a SELECT with a trailing semicolon")
nil_eq((semi or ";"):find(";", 1, true), "trailing semicolon is stripped before the subquery closes")
-- ...but a semicolon inside a string literal is data, not a terminator.
truthy((rewrite("SELECT 'a;b'") or ""):find("'a;b'", 1, true), "semicolon inside a literal is preserved")

-- A trailing line comment must not swallow the closing paren.
truthy(rewrite("SELECT 1 -- tail"):find("\n%)"), "closing paren starts a new line after a tail comment")

-- ── integration: real duckdb CLI ─────────────────────────────────────────────

if vim.fn.executable("duckdb") ~= 1 then
  if vim.env.GRIP_REQUIRE_DUCKDB == "1" then
    error("duckdb_nested_json_spec: duckdb missing while GRIP_REQUIRE_DUCKDB=1")
  end
  print("duckdb_nested_json_spec: SKIPPED (duckdb not found)")
  print(string.format("\nduckdb_nested_json_spec: %d passed, %d failed", pass, fail))
  if fail > 0 then os.exit(1) end
  return
end

local mem = "duckdb::memory:"

--- Single-cell helper: run sql, return the value of row 1 / column 1.
local function cell(sql)
  local res, err = adapter.query(sql, mem)
  if not res then return nil, err end
  return res.rows[1] and res.rows[1][1], nil, res
end

-- The reproduction from the report: a JSON file read as a table, with a string
-- value containing every character a literal-syntax parser would choke on.
local json_path = vim.fn.tempname() .. ".json"
local nasty = [[hello, wor{ld's }end]]
-- Written as literal text, not vim.json.encode: the key order in the file fixes
-- the column order DuckDB reports, and encode() does not promise one.
vim.fn.writefile({ '{"a":[{"x":1,"y":' .. vim.json.encode(nasty) .. '}],"plain":"text"}' }, json_path)

local res_file, file_err = adapter.query(
  string.format("SELECT * FROM '%s'", json_path), mem)
truthy(res_file, "file-as-table query succeeds: " .. tostring(file_err))

if res_file then
  local by_name = {}
  for i, name in ipairs(res_file.columns) do by_name[name] = res_file.rows[1][i] end

  -- gK: the whole point. Nested column parses as JSON.
  local decoded = json_tree.parse(by_name.a)
  truthy(decoded, "gK: json_tree.parse decodes the nested column (got: " .. tostring(by_name.a) .. ")")
  -- And it round-trips the nasty string byte-for-byte -- proof the value came
  -- from DuckDB's own serialiser rather than being reconstructed.
  eq(decoded and decoded[1] and decoded[1].y, nasty, "gK: string with , ' { } survives intact")
  eq(decoded and decoded[1] and decoded[1].x, 1, "gK: number inside the struct decodes")

  -- gB: same cell must pretty-print as json, not fall through to raw text.
  local _, ft = cell_buffer.render_value(by_name.a, "a")
  eq(ft, "json", "gB: nested cell renders with ft=json")

  -- Non-nested columns must be untouched: no added quotes, no re-encoding.
  eq(by_name.plain, "text", "plain VARCHAR column is unchanged")
  eq(table.concat(res_file.columns, ","), "a,plain", "column names and order preserved")
end

-- Every nested kind DuckDB has, plus the scalars whose CSV rendering must not move.
local nested_cases = {
  { sql = "SELECT {'k': 'v'} AS c",                  want = '{"k":"v"}',   what = "STRUCT" },
  { sql = "SELECT [1, 2] AS c",                      want = "[1,2]",       what = "LIST" },
  { sql = "SELECT MAP{'a': 1} AS c",                 want = '{"a":1}',     what = "MAP" },
  { sql = "SELECT ['a', 'b']::VARCHAR[2] AS c",      want = '["a","b"]',   what = "fixed-size ARRAY" },
  { sql = "SELECT union_value(k := 1) AS c",         want = '{"k":1}',     what = "UNION" },
  { sql = "SELECT [{'n': [1]}] AS c",                want = '[{"n":[1]}]', what = "nested LIST of STRUCT" },
}
for _, c in ipairs(nested_cases) do
  local got, err = cell(c.sql)
  eq(got, c.want, c.what .. " serialises as JSON" .. (err and (" (" .. err .. ")") or ""))
end

local scalar_cases = {
  { sql = "SELECT 'plain' AS c",                                want = "plain",     what = "VARCHAR" },
  { sql = "SELECT 42 AS c",                                     want = "42",        what = "INTEGER" },
  { sql = "SELECT 1.5::DOUBLE AS c",                            want = "1.5",       what = "DOUBLE" },
  { sql = "SELECT 123.456::DECIMAL(10,3) AS c",                 want = "123.456",   what = "DECIMAL" },
  { sql = "SELECT '2024-01-02 03:04:05'::TIMESTAMP AS c",       want = "2024-01-02 03:04:05", what = "TIMESTAMP" },
  { sql = "SELECT INTERVAL 1 MONTH AS c",                       want = "1 month",   what = "INTERVAL" },
  { sql = "SELECT 'abc'::BLOB AS c",                            want = "abc",       what = "BLOB" },
  { sql = "SELECT 12345678901234567890::HUGEINT AS c",          want = "12345678901234567890", what = "HUGEINT" },
  { sql = "SELECT 'inf'::DOUBLE AS c",                          want = "inf",       what = "DOUBLE inf" },
  { sql = [[SELECT '{"already": "json"}' AS c]],                want = '{"already": "json"}',
    what = "VARCHAR already holding JSON text (not re-encoded)" },
  -- The JSON type keeps its source text verbatim (spacing included), wrapped or not.
  { sql = [[SELECT '{"t": 1}'::JSON AS c]],                     want = '{"t": 1}',  what = "native JSON type" },
}
for _, c in ipairs(scalar_cases) do
  local got, err = cell(c.sql)
  eq(got, c.want, c.what .. " rendering is unchanged" .. (err and (" (" .. err .. ")") or ""))
end

-- A NULL struct must stay NULL, not become the string "null".
local null_struct = cell("SELECT NULL::STRUCT(x INT) AS c")
truthy(null_struct == nil or null_struct == "" or null_struct == "NULL",
  "NULL nested value stays NULL (got: " .. tostring(null_struct) .. ")")

-- A string containing a comma and a quote must survive CSV round-tripping.
eq(cell([[SELECT 'a,b"c' AS c]]), 'a,b"c', "CSV quoting of scalars still round-trips")

-- Error reporting goes through the unwrapped statement, so a broken user query
-- still describes the user's mistake and never mentions the wrapper. This is also
-- the path a DuckDB too old for the rewrite would take on every query.
local bad_res, bad_err = adapter.query("SELECT * FROM definitely_no_such_table_xyz", mem)
nil_eq(bad_res, "invalid query still returns no result")
truthy(bad_err and bad_err:find("definitely_no_such_table_xyz", 1, true),
  "error names the user's own table: " .. tostring(bad_err))
nil_eq(bad_err and bad_err:find("_grip_json", 1, true), "error never leaks the wrapper subquery")

-- ── a real table (not just file-as-table), through the full grid path ────────

local duck_path = vim.fn.tempname() .. ".duckdb"
vim.fn.system("duckdb " .. vim.fn.shellescape(duck_path) .. " " .. vim.fn.shellescape(
  "CREATE TABLE t (id INTEGER, cfg STRUCT(name VARCHAR, tags VARCHAR[]), note VARCHAR);"
  .. "INSERT INTO t VALUES (1, {'name': 'it''s, {here}', 'tags': ['a', 'b']}, 'plain');"))
local duck_url = "duckdb:" .. duck_path

local query = require("dadbod-grip.query")
local spec  = query.new_table("t", 100)
local res_tbl, tbl_err = adapter.query(query.build_sql(spec), duck_url)
truthy(res_tbl, "table query through query.build_sql succeeds: " .. tostring(tbl_err))

if res_tbl then
  local row = res_tbl.rows[1] or {}
  eq(table.concat(res_tbl.columns, ","), "id,cfg,note", "table column names and order preserved")
  eq(row[1], "1", "scalar id column unchanged")
  eq(row[3], "plain", "scalar note column unchanged")
  local cfg = json_tree.parse(row[2])
  truthy(cfg, "STRUCT column in a real table parses as JSON (got: " .. tostring(row[2]) .. ")")
  eq(cfg and cfg.name, "it's, {here}", "quote/comma/brace inside a STRUCT field survive")
  eq(cfg and cfg.tags and cfg.tags[2], "b", "VARCHAR[] inside a STRUCT decodes")
end

-- Primary-key / column introspection must not be disturbed by the rewrite.
local cols = adapter.get_column_info("t", duck_url)
truthy(cols and #cols == 3, "get_column_info still returns 3 columns")
eq(cols and cols[2] and cols[2].column_name, "cfg", "get_column_info names unchanged")

-- DESCRIBE-based file schema probe still works (it must not be rewritten).
local dbmod = require("dadbod-grip.db")
local fcols, fcols_err = dbmod.describe_file(json_path, mem)
truthy(fcols and #fcols > 0, "describe_file still works: " .. tostring(fcols_err))

-- COUNT(*) pagination query still yields a number.
local cnt_res = adapter.query(query.build_count_sql(spec), duck_url)
eq(cnt_res and cnt_res.rows[1] and cnt_res.rows[1][1], "1", "count query still returns a plain number")

-- Cleanup
vim.fn.delete(json_path)
vim.fn.delete(duck_path)

print(string.format("\nduckdb_nested_json_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
