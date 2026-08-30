-- mysql_integration_spec.lua: end-to-end MySQL adapter tests against a live server.
--
-- Requires a seeded database and the mysql CLI. Skips cleanly when
-- GRIP_TEST_MYSQL_URL is unset. To run:
--
--   docker run -d --name grip-mysql-test -e MYSQL_ROOT_PASSWORD=grip \
--     -e MYSQL_DATABASE=grip_test -p 33306:3306 mysql:8.4
--   mysql -h 127.0.0.1 -P 33306 -u root -pgrip grip_test < tests/seed_mysql.sql
--   GRIP_TEST_MYSQL_URL='mysql://root:grip@127.0.0.1:33306/grip_test' \
--     nvim --headless -u tests/minimal_init.lua -l tests/run_specs.lua
--
-- The mysql client often lives outside PATH (Homebrew keeps it keg-only), so
-- prepend it when needed: PATH="/opt/homebrew/opt/mysql-client/bin:$PATH".

local URL = vim.env.GRIP_TEST_MYSQL_URL
local REQUIRED = vim.env.GRIP_REQUIRE_MYSQL == "1"

local function unavailable(reason)
  if REQUIRED then
    error("mysql_integration_spec: " .. reason .. " while GRIP_REQUIRE_MYSQL=1")
  end
  print("SKIP: mysql_integration_spec (" .. reason .. ")")
  print("\nmysql_integration_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_MYSQL_URL not set")
  return
end

local my = require("dadbod-grip.adapters.mysql")
local sql = require("dadbod-grip.sql")

-- Written by the EXPLAIN test, which must never see it take effect.
local SENTINEL = "zzz_explained"

if vim.fn.executable("mysql") == 0 then
  unavailable("mysql CLI not found")
  return
end

if not my.ping(URL) then
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
  local r, err = my.query("SELECT id, name, email, age FROM users ORDER BY id", URL)
  assert(r, err)
  eq(#r.columns, 4, "columns")
  eq(#r.rows, 15, "rows")
  eq(r.columns[2], "name", "column header")
  eq(r.rows[1][2], "Alice", "first row name")
end)

test("query: NULL arrives as the literal string NULL (known transport limit)", function()
  -- mysql --batch prints NULL as four bytes "NULL", so a real NULL is
  -- indistinguishable from the string 'NULL'. Pinned so that changing it is a
  -- deliberate decision -- pg's psql --csv renders NULL as "" instead.
  local r, err = my.query("SELECT NULL AS nul, 'NULL' AS lit, '' AS blank FROM users LIMIT 1", URL)
  assert(r, err)
  eq(r.rows[1][1], "NULL", "real NULL")
  eq(r.rows[1][2], "NULL", "string 'NULL' is not distinguishable from it")
  eq(r.rows[1][3], "", "empty string stays empty")

  local u = my.query("SELECT name, email, age FROM users WHERE name IN ('Charlie','Diana') ORDER BY name", URL)
  eq(#u.rows, 2, "NULL-able columns do not drop rows")
  eq(u.rows[1][3], "NULL", "NULL age")
  eq(u.rows[2][2], "NULL", "NULL email")
end)

test("query: empty result set loses column headers (known --batch limit)", function()
  -- With zero rows mysql --batch prints nothing at all, not even the header
  -- line, so columns come back empty. psql --csv keeps them; pinned as the
  -- documented divergence rather than as desirable behaviour.
  local r, err = my.query("SELECT * FROM empty_table", URL)
  assert(r, err)
  eq(#r.rows, 0, "no rows")
  eq(#r.columns, 0, "no columns either")
end)

test("query: multibyte values survive the TSV round-trip", function()
  local r, err = my.query("SELECT label, value FROM unicode_fun ORDER BY id", URL)
  assert(r, err)
  eq(#r.rows, 7, "all unicode rows")
  eq(r.rows[1][2], "🎉🚀💾🔥✨ Party time!", "emoji")
  eq(r.rows[2][2], "日本語テスト 中文测试 한국어", "CJK")
  eq(r.rows[3][2], "مرحبا بالعالم", "RTL")
  eq(r.rows[7][2], "┌──┬──┐ │  │  │ └──┴──┘", "box drawing")
end)

test("query: escaped tabs and newlines inside values are unescaped", function()
  -- --batch escapes control characters on the way out; parse_batch must undo it.
  local r, err = my.query("SELECT CONCAT('l1', CHAR(10), 'l2') AS multi, CONCAT('a', CHAR(9), 'b') AS tabbed", URL)
  assert(r, err)
  eq(#r.columns, 2, "two columns despite the embedded tab")
  eq(r.rows[1][1], "l1\nl2", "real newline byte")
  eq(r.rows[1][2], "a\tb", "real tab byte")

  local m = my.query("SELECT body FROM long_values WHERE label = 'multiline'", URL)
  assert(m.rows[1][1]:find("Line one\nLine two", 1, true), "seeded newlines preserved")
end)

test("query: error surfaces the server message", function()
  local r, err = my.query("SELECT * FROM does_not_exist_xyz", URL)
  assert(r == nil, "should fail")
  assert(err and err:find("does_not_exist_xyz"), "error mentions the table: " .. tostring(err))
end)

-- ── execute ────────────────────────────────────────────────────────────

test("execute: INSERT/UPDATE/DELETE round-trip with affected counts", function()
  -- Regression guard: execute() used to grep for an "N rows affected" line that
  -- mysql --batch never prints, so every count came back 0.
  assert(my.execute("DROP TABLE IF EXISTS grip_exec_probe", URL))
  assert(my.execute("CREATE TABLE grip_exec_probe (id INT PRIMARY KEY, v VARCHAR(10))", URL))

  local ok, err = pcall(function()
    local r = assert(my.execute("INSERT INTO grip_exec_probe VALUES (1,'a'),(2,'b'),(3,'c')", URL))
    eq(r.affected, 3, "multi-row insert")
    eq(r.message, "3 row(s) affected", "message tracks the count")

    r = assert(my.execute("INSERT INTO grip_exec_probe VALUES (4,'d');", URL))
    eq(r.affected, 1, "single insert, trailing semicolon")

    r = assert(my.execute("UPDATE grip_exec_probe SET v = 'z' WHERE id <= 2", URL))
    eq(r.affected, 2, "update")

    r = assert(my.execute("DELETE FROM grip_exec_probe WHERE id = 4", URL))
    eq(r.affected, 1, "delete")

    r = assert(my.execute("UPDATE grip_exec_probe SET v = 'q' WHERE id = 999", URL))
    eq(r.affected, 0, "no matching row")

    r = assert(my.execute("UPDATE grip_exec_probe SET v = 'y' WHERE id = 3 -- trailing comment\n", URL))
    eq(r.affected, 1, "a trailing line comment must not swallow the appended statement")

    local rows = my.query("SELECT id, v FROM grip_exec_probe ORDER BY id", URL).rows
    eq(#rows, 3, "data changed as the counts claimed")
    eq(rows[1][2], "z", "row 1 updated")
    eq(rows[3][2], "y", "row 3 updated")
  end)

  my.execute("DROP TABLE IF EXISTS grip_exec_probe", URL)
  if not ok then error(err) end
end)

test("execute: DEFAULT VALUES is rewritten into something MySQL accepts", function()
  assert(my.execute("DROP TABLE IF EXISTS grip_default_probe", URL))
  assert(my.execute("CREATE TABLE grip_default_probe (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(5) DEFAULT 'dflt')", URL))

  local ok, err = pcall(function()
    local r, e = my.execute("INSERT INTO grip_default_probe DEFAULT VALUES", URL)
    assert(r, e)
    eq(r.affected, 1, "default-values insert")
    eq(my.query("SELECT v FROM grip_default_probe", URL).rows[1][1], "dflt", "default applied")
  end)

  my.execute("DROP TABLE IF EXISTS grip_default_probe", URL)
  if not ok then error(err) end
end)

test("execute: error surfaces the server message and returns nil", function()
  local r, err = my.execute("UPDATE users SET nosuchcol = 1", URL)
  assert(r == nil, "should fail")
  assert(err and err:find("nosuchcol"), "error mentions the column: " .. tostring(err))
end)

-- ── schema introspection ───────────────────────────────────────────────

test("list_tables includes tables and marks views", function()
  local r, err = my.list_tables(URL)
  assert(r, err)
  local by_name = {}
  for _, t in ipairs(r) do by_name[t.name] = t.type end
  eq(by_name["users"], "table", "users")
  eq(by_name["no_pk_view"], "view", "view marked as such")
  eq(by_name["type_zoo"], "table", "type_zoo")
end)

test("get_schema_batch: keyed by table, types spelled as in the DDL", function()
  local batch = my.get_schema_batch(URL)
  assert(batch, "batch must not be nil")
  assert(batch["users"] and #batch["users"] == 5, "users has 5 columns")
  eq(batch["users"][2].column_name, "name", "column order follows ordinal_position")
  eq(batch["users"][2].data_type, "varchar(100)", "declared length")
  eq(batch["users"][2].is_nullable, "NO", "nullability")
  eq(batch["users"][3].is_nullable, "YES", "nullable column")
  assert(batch["no_pk_view"], "views are included")

  -- COLUMN_TYPE, not a type rebuilt from DATA_TYPE + length/precision, which
  -- used to render enum(7) / float(12) / tinytext(255) here.
  local zoo = {}
  for _, c in ipairs(batch["type_zoo"]) do zoo[c.column_name] = c.data_type end
  eq(zoo["feeling"], "enum('happy','sad','neutral')", "enum value list")
  eq(zoo["permissions"], "set('read','write','execute','admin')", "set value list")
  eq(zoo["approx_float"], "float", "float carries no bogus precision")
  eq(zoo["tiny_text"], "tinytext", "tinytext carries no bogus length")
  eq(zoo["big_unsigned"], "bigint unsigned", "unsigned modifier kept")
  eq(zoo["precise_num"], "decimal(10,4)", "decimal precision and scale")
end)

test("get_schema_batch_async: agrees with the blocking path", function()
  local sync = my.get_schema_batch(URL)
  local done, async
  my.get_schema_batch_async(URL, function(t) async = t; done = true end)
  assert(vim.wait(15000, function() return done end), "async callback must fire")
  assert(vim.deep_equal(sync, async), "async batch must match the blocking one")
end)

test("get_column_info / get_primary_keys handle constraints and composites", function()
  local cols, err = my.get_column_info("users", URL)
  assert(cols, err)
  eq(#cols, 5, "users columns")
  eq(cols[1].constraints, "PRIMARY KEY", "PK surfaced from COLUMN_KEY")
  eq(cols[3].constraints, "UNIQUE", "unique email")

  local pks = my.get_primary_keys("composite_pk", URL)
  eq(#pks, 2, "composite pk count")
  eq(pks[1], "tenant_id", "pk order follows ordinal_position")

  -- Schema-qualified and quoted names must resolve to the same table.
  eq(my.get_primary_keys("grip_test.users", URL)[1], "id", "qualified name")
  eq(my.get_primary_keys('"users"', URL)[1], "id", "quoted name")
end)

test("get_foreign_keys / get_referencing_foreign_keys", function()
  local fks, err = my.get_foreign_keys("order_items", URL)
  assert(fks, err)
  eq(#fks, 2, "two FKs on order_items")
  local by_col = {}
  for _, f in ipairs(fks) do by_col[f.column] = f end
  eq(by_col["order_id"].ref_table, "orders", "order_id references orders")
  eq(by_col["product_id"].ref_column, "id", "product_id references id")

  local refs = my.get_referencing_foreign_keys("products", URL)
  eq(#refs, 1, "one child table")
  eq(refs[1].table, "order_items", "child table")
  eq(refs[1].column, "product_id", "child column")

  eq(#my.get_referencing_foreign_keys("empty_table", URL), 0, "no children")
end)

test("get_indexes / get_constraints / get_table_stats", function()
  local idx, err = my.get_indexes("order_items", URL)
  assert(idx, err)
  eq(idx[1].name, "PRIMARY", "primary index first")
  eq(idx[1].type, "PRIMARY", "primary index type")
  eq(idx[1].columns[1], "id", "primary index column")

  local cons = my.get_constraints("users", URL)
  eq(#cons, 1, "one constraint on users")
  eq(cons[1].type, "UNIQUE", "the unique email constraint")
  eq(cons[1].definition, "email", "constrained column")

  local stats = my.get_table_stats("users", URL)
  assert(stats and stats.size_bytes > 0, "size_bytes positive")
  assert(stats.row_estimate > 0, "row_estimate positive (an estimate, not exact)")
end)

-- ── explain ────────────────────────────────────────────────────────────

test("explain: SELECT produces a plan and never runs DML", function()
  -- A primary-key lookup collapses to "Rows fetched before execution" and never
  -- names the table, so probe the plan text with a predicate that forces a scan.
  local r, err = my.explain("SELECT * FROM users WHERE age > 30", URL)
  assert(r, err)
  assert(#r.lines > 0, "plan lines present")
  local plan = table.concat(r.lines, "\n")
  assert(plan:find("users", 1, true), "plan mentions the table: " .. plan)
  -- FORMAT=TREE returns the whole tree as one field; --batch escapes its
  -- newlines and parse_batch must have turned them back into real ones.
  assert(plan:find("\n", 1, true) and not plan:find("\\n", 1, true),
    "plan newlines unescaped: " .. plan)

  assert(my.explain("SELECT * FROM users WHERE id = 1", URL), "pk lookup still plans")

  local before = my.query("SELECT status FROM orders WHERE id = 1", URL).rows[1][1]
  -- If a regression ever lets EXPLAIN run the statement, the sentinel would stay
  -- in the seed and every later run would compare sentinel against sentinel --
  -- green, and blind. So refuse to run against an already-poisoned row, and
  -- restore the original value afterwards whether or not the assertion held.
  assert(before ~= SENTINEL,
    "orders.id=1 already holds the sentinel; reseed with tests/seed_mysql.sql")

  local ok, sentinel_err = pcall(function()
    my.explain("UPDATE orders SET status = '" .. SENTINEL .. "' WHERE id = 1", URL)
    local after = my.query("SELECT status FROM orders WHERE id = 1", URL).rows[1][1]
    eq(after, before, "EXPLAIN must not mutate data")
  end)

  my.execute(string.format("UPDATE orders SET status = '%s' WHERE id = 1",
    sql.escape_literal(before)), URL)
  if not ok then error(sentinel_err) end
end)

print(string.format("\nmysql_integration_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
