-- pg_integration_spec.lua: end-to-end PostgreSQL adapter tests against a live server.
--
-- Requires a seeded database and the psql CLI. Skips cleanly when
-- GRIP_TEST_PG_URL is unset. To run:
--
--   docker run -d --name grip-pg-test -e POSTGRES_PASSWORD=grip \
--     -e POSTGRES_DB=grip_test -p 54329:5432 postgres:16-alpine
--   PGPASSWORD=grip psql -h localhost -p 54329 -U postgres -d grip_test -f tests/seed_pg.sql
--   GRIP_TEST_PG_URL='postgresql://postgres:grip@localhost:54329/grip_test' \
--     nvim --headless -u tests/minimal_init.lua -l tests/run_specs.lua

local URL = vim.env.GRIP_TEST_PG_URL
local REQUIRED = vim.env.GRIP_REQUIRE_POSTGRES == "1"

local function unavailable(reason)
  if REQUIRED then
    error("pg_integration_spec: " .. reason .. " while GRIP_REQUIRE_POSTGRES=1")
  end
  print("SKIP: pg_integration_spec (" .. reason .. ")")
  print("\npg_integration_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_PG_URL not set")
  return
end

local pg = require("dadbod-grip.adapters.postgresql")

if vim.fn.executable("psql") == 0 then
  unavailable("psql CLI not found")
  return
end

if not pg.ping(URL) then
  unavailable("database is unreachable")
  return
end

local pass, fail = 0, 0
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
  assert(a == b, (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

-- ── query ──────────────────────────────────────────────────────────────

test("query: basic SELECT returns rows and columns", function()
  local r, err = pg.query("SELECT id, name, email, age FROM users ORDER BY id", URL)
  assert(r, err)
  eq(#r.columns, 4, "columns")
  eq(#r.rows, 15, "rows")
  eq(r.rows[1][2], "Alice", "first row name")
end)

test("query: NULLs come back as empty strings without dropping rows", function()
  local r, err = pg.query("SELECT email FROM users ORDER BY id", URL)
  assert(r, err)
  eq(#r.rows, 15, "single NULL-able column keeps all rows")
  local r2 = pg.query(
    "SELECT name, email, age FROM users WHERE name IN ('Charlie','Diana') ORDER BY name", URL)
  eq(r2.rows[1][3], "", "NULL age -> empty string")
  eq(r2.rows[2][2], "", "NULL email -> empty string")
end)

test("query: multibyte and multiline values survive CSV round-trip", function()
  local r, err = pg.query("SELECT label, value FROM unicode_fun ORDER BY id", URL)
  assert(r, err)
  eq(r.rows[2][2], "日本語テスト 中文测试 한국어", "CJK")
  eq(r.rows[1][2], "🎉🚀💾🔥✨ Party time!", "emoji")
  local m = pg.query("SELECT body FROM long_values WHERE label = 'multiline'", URL)
  eq(#m.rows, 1, "one multiline row")
  assert(m.rows[1][1]:find("Line one\nLine two", 1, true), "embedded newlines preserved")
end)

test("query: JSON/JSONB with commas and quotes", function()
  local r, err = pg.query("SELECT metadata::text FROM json_data WHERE id = 1", URL)
  assert(r, err)
  eq(r.rows[1][1], '{"key": "value", "nested": {"deep": true}}', "json text")
end)

test("query: error surfaces server message", function()
  local r, err = pg.query("SELECT * FROM does_not_exist_xyz", URL)
  assert(r == nil, "should fail")
  assert(err and err:find("does_not_exist_xyz"), "error mentions relation")
end)

-- ── execute ────────────────────────────────────────────────────────────

test("execute: INSERT/UPDATE/DELETE round-trip with affected counts", function()
  local r, err = pg.execute(
    "INSERT INTO users (name, email, age) VALUES ('TempGuy', 'temp@example.com', 99)", URL)
  assert(r, err)
  eq(r.affected, 1, "insert affected")
  r = pg.execute("UPDATE users SET age = 100 WHERE name = 'TempGuy'", URL)
  eq(r.affected, 1, "update affected")
  r = pg.execute("DELETE FROM users WHERE name = 'TempGuy'", URL)
  eq(r.affected, 1, "delete affected")
  eq(pg.query("SELECT count(*) FROM users", URL).rows[1][1], "15", "row count restored")
end)

-- ── schema introspection ───────────────────────────────────────────────

test("list_tables includes tables, views, quoted names", function()
  local r, err = pg.list_tables(URL)
  assert(r, err)
  local by_name = {}
  for _, t in ipairs(r) do by_name[t.name] = t.type end
  eq(by_name["users"], "table", "users")
  eq(by_name["no_pk_view"], "view", "view")
  eq(by_name["Participant"], "table", "PascalCase table listed")
  eq(by_name["admin.audit_log"], "table", "non-public table is schema-qualified")
  assert(by_name["audit_log"] == nil, "a non-public table must not appear under its bare name")
end)

test("get_column_info / get_primary_keys handle quoted and composite", function()
  local cols = pg.get_column_info("users", URL)
  eq(#cols, 5, "users columns")
  assert(cols[1].constraints:find("PRIMARY KEY"), "PK constraint surfaced")

  local qcols = pg.get_column_info('"Participant"', URL)
  eq(qcols[2].column_name, "firstName", "camelCase column")

  local pks = pg.get_primary_keys("composite_pk", URL)
  eq(#pks, 2, "composite pk count")
  eq(pks[1], "tenant_id", "pk order")
end)

test("get_foreign_keys / get_indexes / get_table_stats / get_schema_batch", function()
  local fks = pg.get_foreign_keys("order_items", URL)
  eq(#fks, 2, "two FKs on order_items")

  local idx = pg.get_indexes("users", URL)
  assert(#idx >= 2, "pk + unique index")
  eq(idx[1].type, "PRIMARY", "primary index first")

  local stats = pg.get_table_stats("users", URL)
  assert(stats and stats.size_bytes > 0, "size_bytes positive")

  local batch = pg.get_schema_batch(URL)
  assert(batch and batch["users"] and #batch["users"] == 5, "batch users columns")
  assert(batch["Participant"], "batch includes quoted table")
end)

test("get_schema_batch: non-public schema qualified as schema.table", function()
  local batch = pg.get_schema_batch(URL)
  assert(batch, "batch must not be nil")

  local cols = batch["admin.audit_log"]
  assert(cols, "admin.audit_log present under its qualified name")
  assert(batch["audit_log"] == nil, "and not under its bare name")
  eq(#cols, 3, "column count")
  eq(cols[1].column_name, "id", "column order")
  eq(cols[2].data_type, "character varying(50)", "declared length")
  eq(cols[2].is_nullable, "NO", "NOT NULL column")
  eq(cols[3].is_nullable, "YES", "nullable column")

  -- The same qualified key must work as a table name for per-table lookups.
  eq(pg.get_primary_keys("admin.audit_log", URL)[1], "id", "pk via qualified name")
  eq(#pg.get_column_info("admin.audit_log", URL), 3, "column info via qualified name")
end)

-- ── routines (PR #17) ──────────────────────────────────────────────────

test("list_routines: functions, procedures, non-public schemas", function()
  local r, err = pg.list_routines(URL)
  assert(r, err)
  local by_display = {}
  for _, rt in ipairs(r) do by_display[rt.display] = rt end

  local f = by_display["user_display_name(user_id integer)"]
  assert(f, "function listed")
  eq(f.type, "function", "kind")
  assert(f.source_id:match("^%d+$"), "source_id is an oid")

  local p = by_display["mark_order_status(order_id integer, new_status text)"]
  assert(p, "procedure listed without IN prefixes")
  eq(p.type, "procedure", "procedure kind")

  local a = by_display["admin.audit_touch()"]
  assert(a, "non-public routine listed")
  eq(a.name, "admin.audit_touch", "schema-qualified name")
end)

test("get_routine_source: by name, schema.name, oid, args suffix", function()
  local src = pg.get_routine_source("user_display_name", URL)
  assert(src and src:find("CREATE OR REPLACE FUNCTION public.user_display_name", 1, true),
    "source by bare name")

  src = pg.get_routine_source("admin.audit_touch", URL)
  assert(src and src:find("admin.audit_touch", 1, true), "source by schema.name")

  src = pg.get_routine_source("mark_order_status", URL)
  assert(src and src:find("PROCEDURE", 1, true), "procedure source")

  src = pg.get_routine_source("recent_orders(limit_count integer)", URL)
  assert(src and src:find("recent_orders", 1, true), "name with args suffix")

  local routines = pg.list_routines(URL)
  local target
  for _, rt in ipairs(routines) do
    if rt.name == "recent_orders" then target = rt end
  end
  src = pg.get_routine_source(target.source_id, URL)
  assert(src and src:find("recent_orders", 1, true), "source by oid")

  local missing, merr = pg.get_routine_source("no_such_fn_xyz", URL)
  assert(missing == nil and merr and merr:find("no_such_fn_xyz"), "missing routine errors")
end)

test("routines: overloads resolve by oid; quoted identifiers work", function()
  assert(pg.execute([[
    CREATE OR REPLACE FUNCTION grip_overload_me(x integer) RETURNS integer LANGUAGE sql AS 'SELECT x';
    CREATE OR REPLACE FUNCTION grip_overload_me(x text) RETURNS text LANGUAGE sql AS 'SELECT x';
    CREATE OR REPLACE FUNCTION "Grip Weird Fn"() RETURNS integer LANGUAGE sql AS 'SELECT 42';
  ]], URL), "overload setup failed")

  local ok, err = pcall(function()
    local seen = {}
    for _, rt in ipairs(pg.list_routines(URL)) do
      if rt.name == "grip_overload_me" then seen[rt.display] = rt end
      if rt.name == "Grip Weird Fn" then seen.weird = rt end
    end
    assert(seen["grip_overload_me(x integer)"], "int overload listed")
    assert(seen["grip_overload_me(x text)"], "text overload listed")
    assert(seen.weird, "quoted-name function listed")

    local s1 = pg.get_routine_source(seen["grip_overload_me(x integer)"].source_id, URL)
    local s2 = pg.get_routine_source(seen["grip_overload_me(x text)"].source_id, URL)
    assert(s1:find("x integer", 1, true), "oid selects int overload")
    assert(s2:find("x text", 1, true), "oid selects text overload")

    local sw = pg.get_routine_source('"Grip Weird Fn"', URL)
    assert(sw and sw:find("Grip Weird Fn", 1, true), "quoted identifier lookup")
  end)

  pg.execute([[
    DROP FUNCTION IF EXISTS grip_overload_me(integer);
    DROP FUNCTION IF EXISTS grip_overload_me(text);
    DROP FUNCTION IF EXISTS "Grip Weird Fn"();
  ]], URL)

  if not ok then error(err) end
end)

-- ── explain ────────────────────────────────────────────────────────────

test("explain: SELECT produces a plan", function()
  local r, err = pg.explain("SELECT * FROM users WHERE id = 1", URL)
  assert(r, err)
  assert(#r.lines > 0, "plan lines present")
  assert(table.concat(r.lines, "\n"):find("users", 1, true), "plan mentions table")
end)

test("explain: never executes DML (regression: ANALYZE ran the statement)", function()
  local before = pg.query("SELECT status FROM orders WHERE id = 1", URL).rows[1][1]
  local r, err = pg.explain("UPDATE orders SET status = 'zzz_explained' WHERE id = 1", URL)
  assert(r, err)
  local after = pg.query("SELECT status FROM orders WHERE id = 1", URL).rows[1][1]
  eq(after, before, "EXPLAIN must not mutate data")
end)

print(string.format("\npg_integration_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
