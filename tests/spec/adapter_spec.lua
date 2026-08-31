-- adapter_spec.lua: unit tests for adapter URL parsing, output parsing, SQL rewriting
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local duckdb = require("dadbod-grip.adapters.duckdb")
local pg = require("dadbod-grip.adapters.postgresql")
local adapters = require("dadbod-grip.adapters")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

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

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

local function has_arg(args, flag, msg)
  for _, a in ipairs(args) do
    if a == flag then return end
  end
  error((msg or "") .. ": expected args to contain '" .. flag .. "'")
end

local function last_arg(args)
  return args._stdin or args[#args]
end

-- ── mock helpers ──────────────────────────────────────────────────────────────

local function with_system_mock(stdout, stderr, code, fn)
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    local r = { stdout = stdout, stderr = stderr or "", code = code or 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
end

local function capture_system_args(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args, opts, cb)
    captured = args
    captured._stdin = opts and opts.stdin
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
end

--- Same as capture_system_args but also returns the opts vim.system was
--- called with, so a test can inspect opts.env (e.g. a password delivered
--- via the environment instead of argv).
local function capture_system_call(stdout, fn)
  local captured_args, captured_opts, call_count = nil, nil, 0
  local orig = vim.system
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    captured_args = args
    captured_opts = opts
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured_args, captured_opts, call_count
end

local function with_executable(fn)
  local orig = vim.fn.executable
  vim.fn.executable = function() return 1 end
  local ok, err = pcall(fn)
  vim.fn.executable = orig
  if not ok then error(err) end
end

-- ── MySQL parse_url ──────────────────────────────────────────────────────────

test("mysql parse_url: full URL parses all fields", function()
  local r = mysql._parse_url("mysql://alice:secret@db.host:3307/mydb")
  eq(r.user, "alice", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "3307", "port")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: URL without port defaults to 3306", function()
  local r = mysql._parse_url("mysql://user:pass@host/db")
  eq(r.port, "3306", "port")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: URL without auth", function()
  local r = mysql._parse_url("mysql://localhost:3306/mydb")
  eq(r.user, nil, "user")
  eq(r.pass, nil, "pass")
  eq(r.host, "localhost", "host")
  eq(r.dbname, "mydb", "dbname")
end)

test("mysql parse_url: @ in password uses last-@ rule", function()
  local r = mysql._parse_url("mysql://user:p@ss@host/db")
  eq(r.user, "user", "user")
  eq(r.pass, "p@ss", "pass")
  eq(r.host, "host", "host")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: URL without dbname", function()
  local r = mysql._parse_url("mysql://user:pass@host:3306")
  eq(r.dbname, nil, "dbname should be nil")
  eq(r.host, "host", "host")
end)

test("mysql parse_url: mariadb scheme", function()
  local r = mysql._parse_url("mariadb://user:pass@host/db")
  eq(r.user, "user", "user")
  eq(r.dbname, "db", "dbname")
end)

test("mysql parse_url: empty string returns nil", function()
  local r = mysql._parse_url("")
  eq(r, nil, "empty")
end)

test("mysql parse_url: malformed returns nil", function()
  local r = mysql._parse_url("just-a-host")
  eq(r, nil, "malformed")
end)

-- ── SQLite extract_path ──────────────────────────────────────────────────────

test("sqlite extract_path: relative path", function()
  eq(sqlite._extract_path("sqlite:relative/path.db"), "relative/path.db")
end)

test("sqlite extract_path: absolute path", function()
  eq(sqlite._extract_path("sqlite:/absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: triple-slash absolute", function()
  eq(sqlite._extract_path("sqlite:///absolute/path.db"), "/absolute/path.db")
end)

test("sqlite extract_path: tilde expansion", function()
  local home = os.getenv("HOME") or ""
  eq(sqlite._extract_path("sqlite:~/test.db"), home .. "/test.db")
end)

test("sqlite extract_path: bare sqlite: returns nil", function()
  eq(sqlite._extract_path("sqlite:"), nil)
end)

test("sqlite extract_path: non-sqlite scheme returns nil", function()
  eq(sqlite._extract_path("postgres://localhost/db"), nil)
end)

-- ── DuckDB extract_path ──────────────────────────────────────────────────────

test("duckdb extract_path: relative path", function()
  eq(duckdb._extract_path("duckdb:path.db"), "path.db")
end)

test("duckdb extract_path: absolute path", function()
  eq(duckdb._extract_path("duckdb:/absolute.db"), "/absolute.db")
end)

test("duckdb extract_path: triple-slash absolute", function()
  eq(duckdb._extract_path("duckdb:///absolute"), "/absolute")
end)

test("duckdb extract_path: memory returns :memory:", function()
  eq(duckdb._extract_path("duckdb::memory:"), ":memory:")
end)

test("duckdb extract_path: bare duckdb: returns :memory:", function()
  eq(duckdb._extract_path("duckdb:"), ":memory:")
end)

-- ── PostgreSQL affected-row parsing ──────────────────────────────────────────

test("pg execute: UPDATE 5 parses affected rows", function()
  with_executable(function()
    with_system_mock("UPDATE 5\n", "", 0, function()
      local result, err = pg.execute("UPDATE users SET x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 5, "affected")
    end)
  end)
end)

test("pg execute: INSERT 0 1 parses affected rows", function()
  with_executable(function()
    with_system_mock("INSERT 0 1\n", "", 0, function()
      local result, err = pg.execute("INSERT INTO t VALUES (1)", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 1, "affected")
    end)
  end)
end)

test("pg execute: DELETE 3 parses affected rows", function()
  with_executable(function()
    with_system_mock("DELETE 3\n", "", 0, function()
      local result, err = pg.execute("DELETE FROM t WHERE x=1", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("pg execute: empty stdout parses as 0 affected", function()
  with_executable(function()
    with_system_mock("", "", 0, function()
      local result, err = pg.execute("DO $$ BEGIN END $$", "postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 0, "affected")
    end)
  end)
end)

-- ── PostgreSQL .psqlrc bypass ────────────────────────────────────────────

test("pg query: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      pg.query("SELECT 1", "postgresql://localhost/db")
    end)
    has_arg(args, "-X", "query should pass -X")
  end)
end)

test("pg query: stdin errors stop psql with a nonzero exit", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.query("SELECT * FROM missing_table", "postgresql://localhost/db")
    end)
    has_arg(args, "--set=ON_ERROR_STOP=1", "stdin errors must preserve -c exit behavior")
  end)
end)

test("pg ping: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.ping("postgresql://localhost/db")
    end)
    has_arg(args, "-X", "ping should pass -X")
  end)
end)

-- ── PostgreSQL routines ─────────────────────────────────────────────────

test("pg list_routines: queries pg_proc and parses functions/procedures", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      "12345,public,user_display_name,user_id integer,function",
      "23456,admin,audit_touch,,procedure",
      "",
    }, "\n")
    local args = capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(#routines, 2, "routine count")
      eq(routines[1].name, "user_display_name", "public routine name is bare")
      eq(routines[1].display, "user_display_name(user_id integer)", "function display")
      eq(routines[1].type, "function", "function type")
      eq(routines[1].source_id, "12345", "function source id")
      eq(routines[2].name, "admin.audit_touch", "non-public routine is schema-qualified")
      eq(routines[2].display, "admin.audit_touch()", "procedure display")
      eq(routines[2].type, "procedure", "procedure type")
    end)
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_proc", "routine list queries pg_proc")
    contains(sql_arg, "pg_namespace", "routine list queries schemas")
  end)
end)

test("pg get_routine_source: can select exact routine by oid source id", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION overloaded(value text)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT value; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("98765", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "overloaded(value text)", "source contains selected overload")
    local sql_arg = last_arg(args)
    contains(sql_arg, "p.oid = 98765::oid", "source query filters by oid")
  end)
end)

test("pg get_routine_source: uses pg_get_functiondef and preserves source text", function()
  with_executable(function()
    local csv = "source\n\"CREATE OR REPLACE FUNCTION user_display_name(user_id integer)\nRETURNS text\nLANGUAGE sql\nAS $$ SELECT 'user'; $$\"\n"
    local source, err
    local args = capture_system_args(csv, function()
      source, err = pg.get_routine_source("user_display_name", "postgresql://localhost/db")
    end)
    assert(not err, "should not error: " .. tostring(err))
    contains(source, "CREATE OR REPLACE FUNCTION", "source contains function DDL")
    contains(source, "RETURNS text", "source preserves multiline body")
    local sql_arg = last_arg(args)
    contains(sql_arg, "pg_get_functiondef", "source query uses pg_get_functiondef")
    contains(sql_arg, "user_display_name", "source query filters by routine")
  end)
end)

test("pg list_routines: strips bare IN mode from procedure arguments", function()
  with_executable(function()
    local csv = table.concat({
      "source_id,schema,name,identity_arguments,kind",
      '23456,public,mark_order_status,"IN order_id integer, IN new_status text",procedure',
      '34567,public,swap_vals,"INOUT a integer, INOUT b integer",procedure',
      "",
    }, "\n")
    capture_system_args(csv, function()
      local routines, err = pg.list_routines("postgresql://localhost/db")
      assert(not err, "should not error: " .. tostring(err))
      eq(routines[1].display, "mark_order_status(order_id integer, new_status text)",
        "IN mode stripped for display parity with functions")
      eq(routines[1].arguments, "order_id integer, new_status text", "arguments field cleaned")
      eq(routines[2].display, "swap_vals(INOUT a integer, INOUT b integer)",
        "INOUT mode is meaningful and kept")
    end)
  end)
end)

-- ── PostgreSQL EXPLAIN safety ────────────────────────────────────────────
-- ANALYZE executes the statement; it must only be added for read-only SQL.

test("pg explain: SELECT uses ANALYZE for actual timings", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("SELECT * FROM users", "postgresql://localhost/db")
    end)
    contains(last_arg(args), "EXPLAIN (FORMAT TEXT, ANALYZE) SELECT", "SELECT gets ANALYZE")
  end)
end)

test("pg explain: UPDATE/DELETE/INSERT never use ANALYZE (would execute the DML)", function()
  with_executable(function()
    for _, stmt in ipairs({
      "UPDATE users SET age = 1 WHERE id = 1",
      "DELETE FROM users WHERE id = 1",
      "INSERT INTO users (name) VALUES ('x')",
    }) do
      local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
        pg.explain(stmt, "postgresql://localhost/db")
      end)
      local sql_arg = last_arg(args)
      assert(not sql_arg:find("ANALYZE", 1, true),
        "no ANALYZE for: " .. stmt .. " (got: " .. sql_arg .. ")")
      contains(sql_arg, "EXPLAIN (FORMAT TEXT) ", "plain EXPLAIN used")
    end
  end)
end)

test("pg explain: WITH gets plain EXPLAIN (may contain data-modifying CTEs)", function()
  with_executable(function()
    local args = capture_system_args("QUERY PLAN\nSeq Scan\n", function()
      pg.explain("WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone",
        "postgresql://localhost/db")
    end)
    assert(not last_arg(args):find("ANALYZE", 1, true), "no ANALYZE for WITH")
  end)
end)

-- ── SQLite .sqliterc bypass ─────────────────────────────────────────────

test("sqlite query: uses the null device to skip .sqliterc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      sqlite.query("SELECT 1", "sqlite:test.db")
    end)
    for i, arg in ipairs(args) do
      if arg == "-init" then
        eq(args[i + 1], vim.fn.has("win32") == 1 and "NUL" or "/dev/null", "empty init file")
        return
      end
    end
    error("query should pass -init")
  end)
end)

test("sqlite stops at the first failed statement so transactions roll back", function()
  with_executable(function()
    local args = capture_system_args("", function()
      sqlite.execute("BEGIN; SELECT 1; COMMIT;", "sqlite:test.db")
    end)
    has_arg(args, "-bail", "sqlite should stop before COMMIT after an error")
  end)
end)

-- ── SQL Server adapter ───────────────────────────────────────────────────

test("adapter registry resolves sqlserver and mssql URLs", function()
  local a1, err1 = adapters.resolve("sqlserver://sa:pw@localhost:1433/grip_test")
  assert(a1 == sqlserver, "sqlserver adapter mismatch: " .. tostring(err1))
  local a2, err2 = adapters.resolve("mssql://sa:pw@localhost/grip_test")
  assert(a2 == sqlserver, "mssql adapter mismatch: " .. tostring(err2))
end)

test("sqlserver parse_url: full URL parses all fields", function()
  local r = sqlserver._parse_url("sqlserver://sa:secret@db.host:14330/grip_test")
  eq(r.user, "sa", "user")
  eq(r.pass, "secret", "pass")
  eq(r.host, "db.host", "host")
  eq(r.port, "14330", "port")
  eq(r.dbname, "grip_test", "dbname")
  eq(r.encrypt, "mandatory", "certificate-validating encryption is the default")
end)

test("sqlserver TLS URL options map to sqlcmd for both schemes", function()
  for _, scheme in ipairs({ "sqlserver", "mssql" }) do
    local parsed = assert(sqlserver._parse_url(scheme
      .. "://sa:secret@db.host:1433/grip_test?encrypt=strict&server_certificate=%2Ftmp%2Fdb+cert.pem"))
    eq(parsed.dbname, "grip_test", scheme .. " dbname excludes query")
    eq(parsed.encrypt, "strict", scheme .. " strict parsed")
    eq(parsed.server_certificate, "/tmp/db cert.pem", scheme .. " certificate decoded")
    local args = sqlserver._sqlcmd_args(parsed, "SELECT 1")
    has_arg(args, "-Ns", scheme .. " strict encryption")
    has_arg(args, "-J", scheme .. " certificate pinning")
    has_arg(args, "/tmp/db cert.pem", scheme .. " certificate path")
  end
end)

test("sqlserver TLS defaults to validation and allows explicit local trust", function()
  local secure = assert(sqlserver._parse_url("sqlserver://sa:pw@db/app"))
  has_arg(sqlserver._sqlcmd_args(secure, "SELECT 1"), "-Nm", "secure default")

  local local_dev = assert(sqlserver._parse_url(
    "sqlserver://sa:pw@localhost/app?encrypt=optional&trust_server_certificate=true"))
  local args = sqlserver._sqlcmd_args(local_dev, "SELECT 1")
  has_arg(args, "-No", "optional encryption")
  has_arg(args, "-C", "explicit certificate bypass")
end)

test("sqlserver rejects unsafe or contradictory TLS URL values before spawning", function()
  local parsed, err = sqlserver._parse_url("sqlserver://sa:pw@db/app?encrypt=maybe")
  eq(parsed, nil, "invalid encryption rejected")
  contains(err, "optional, mandatory, or strict", "valid values named")

  parsed, err = sqlserver._parse_url(
    "mssql://sa:pw@db/app?server_certificate=%2Ftmp%2Fdb.pem&trust_server_certificate=true")
  eq(parsed, nil, "pinning and bypass cannot be combined")
  contains(err, "cannot be combined", "conflict explained")
end)

test("sqlserver translates shared LIMIT pagination to OFFSET/FETCH", function()
  eq(sqlserver._normalize_query_sql('SELECT * FROM "orders" LIMIT 25'),
    'SELECT * FROM "orders" ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 25 ROWS ONLY',
    "first page gets a deterministic legal ordering")
  eq(sqlserver._normalize_query_sql(
      'SELECT * FROM "orders" ORDER BY "total" ASC LIMIT 25 OFFSET 50'),
    'SELECT * FROM "orders" ORDER BY "total" ASC OFFSET 50 ROWS FETCH NEXT 25 ROWS ONLY',
    "sort and page offset preserved")
  eq(sqlserver._normalize_query_sql("SELECT TOP 5 * FROM users"),
    "SELECT TOP 5 * FROM users", "native SQL Server query unchanged")
end)

test("sqlserver query: parses sqlcmd tab output", function()
  with_executable(function()
    local out = table.concat({
      "id\tname",
      "--\t----",
      "1\tAlice",
      "2\tNULL",
      "",
      "(2 rows affected)",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.query("SELECT id, name FROM users", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.columns[1], "id", "first column")
      eq(result.columns[2], "name", "second column")
      eq(result.rows[1][2], "Alice", "first row value")
      eq(result.rows[2][2], "", "NULL becomes empty string")
    end)
  end)
end)

test("sqlserver query: builds sqlcmd args for non-interactive use", function()
  with_executable(function()
    local args, opts = capture_system_call("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    has_arg(args, "sqlcmd", "uses sqlcmd")
    has_arg(args, "-S", "sets server")
    has_arg(args, "-d", "sets database")
    has_arg(args, "-U", "sets user")
    assert(not vim.tbl_contains(args, "-Q"), "query must not use -Q")
    for _, a in ipairs(args) do
      assert(not tostring(a):find("pw", 1, true), "password in argv: " .. tostring(a))
    end
    eq(opts.env.SQLCMDPASSWORD, "pw", "password delivered via env instead")
    contains(opts.stdin, "SELECT 1", "query delivered via stdin")
  end)
end)

test("sqlserver query: sends one complete multi-batch block in one invocation", function()
  with_executable(function()
    local block = table.concat({
      "CREATE TABLE #grip_scope (id INT NOT NULL);",
      "GO",
      "INSERT INTO #grip_scope VALUES (7);",
      "GO",
      "SELECT id FROM #grip_scope;",
    }, "\n")
    local _, opts, calls = capture_system_call("id\n--\n7\n", function()
      local result, err = sqlserver.query(block, "sqlserver://sa:pw@localhost/grip_test")
      assert(result, err)
    end)
    eq(calls, 1, "one sqlcmd process")
    contains(opts.stdin, block, "complete block delivered through one stdin")
  end)
end)

test("sqlserver list_tables: parses table and view rows", function()
  with_executable(function()
    local out = table.concat({
      "table_name\ttable_type",
      "----------\t----------",
      "users\ttable",
      "no_pk_view\tview",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.list_tables("sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two objects")
      eq(result[1].name, "users", "table name")
      eq(result[1].type, "table", "table type")
      eq(result[2].type, "view", "view type")
    end)
  end)
end)

test("sqlserver execute: parses affected rows from (N rows affected)", function()
  with_executable(function()
    with_system_mock("\n(3 rows affected)\n", "", 0, function()
      local result, err = sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("sqlserver execute: does not send SET NOCOUNT ON (would suppress the row count)", function()
  with_executable(function()
    local args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute("UPDATE users SET x=1", "sqlserver://sa:pw@localhost/grip_test")
    end)
    local sql_arg = last_arg(args)
    assert(not sql_arg:find("NOCOUNT", 1, true), "execute must not set NOCOUNT: " .. sql_arg)
  end)
end)

test("sqlserver query: still sends SET NOCOUNT ON (keeps row count out of the grid)", function()
  with_executable(function()
    local args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost:1433/grip_test")
    end)
    contains(last_arg(args), "SET NOCOUNT ON", "query must still set NOCOUNT")
  end)
end)

test("sqlserver enables double-quoted identifiers for every command", function()
  with_executable(function()
    local query_args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query('SELECT * FROM "orders"', "sqlserver://sa:pw@localhost/grip_test")
    end)
    contains(last_arg(query_args), "SET QUOTED_IDENTIFIER ON", "query session")

    local exec_args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute('UPDATE "orders" SET "status" = \'done\' WHERE "id" = 1',
        "sqlserver://sa:pw@localhost/grip_test")
    end)
    contains(last_arg(exec_args), "SET QUOTED_IDENTIFIER ON", "execute session")
  end)
end)

test("sqlserver leaves ordinary user transaction semantics unchanged", function()
  with_executable(function()
    local query_args = capture_system_args("id\n--\n1\n", function()
      sqlserver.query("SELECT 1", "sqlserver://sa:pw@localhost/grip_test")
    end)
    assert(not last_arg(query_args):find("SET XACT_ABORT ON", 1, true),
      "query session must not force XACT_ABORT")

    local exec_args = capture_system_args("\n(1 rows affected)\n", function()
      sqlserver.execute("UPDATE users SET id = id", "sqlserver://sa:pw@localhost/grip_test")
    end)
    assert(not last_arg(exec_args):find("SET XACT_ABORT ON", 1, true),
      "execute session must not force XACT_ABORT")
  end)
end)

test("sqlserver get_primary_keys: parses key columns", function()
  with_executable(function()
    local out = table.concat({
      "column_name",
      "-----------",
      "tenant_id",
      "user_id",
      "",
    }, "\n")
    with_system_mock(out, "", 0, function()
      local result, err = sqlserver.get_primary_keys("composite_pk", "sqlserver://sa:pw@localhost/grip_test")
      assert(not err, "should not error: " .. tostring(err))
      eq(#result, 2, "two primary key columns")
      eq(result[1], "tenant_id", "first pk")
      eq(result[2], "user_id", "second pk")
    end)
  end)
end)

-- ── MySQL DEFAULT VALUES rewriting ───────────────────────────────────────────

test("mysql execute: DEFAULT VALUES is rewritten", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t DEFAULT VALUES", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, "() VALUES ()", "DEFAULT VALUES rewrite")
    assert(not sql_arg:find("DEFAULT VALUES", 1, true), "DEFAULT VALUES should be gone")
  end)
end)

test("mysql execute: non-DEFAULT-VALUES SQL unchanged", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t (name) VALUES ('x')", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, "VALUES ('x')", "SQL unchanged")
  end)
end)

test("mysql execute: appends SELECT ROW_COUNT() after stripping trailing semicolons", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "ROW_COUNT()\n1\n", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1;\n", "mysql://root@localhost/test")
    vim.system = orig
    contains(last_arg(captured_args), "UPDATE t SET x=1\n; SELECT ROW_COUNT();",
      "one statement separator, comment-safe newline")
  end)
end)

test("mysql execute: affected row parsing from ROW_COUNT() output", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n3\n", "", 0, function()
      local result, err = mysql.execute("UPDATE t SET x=1", "mysql://root@localhost/test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
      eq(result.message, "3 row(s) affected", "message")
    end)
  end)
end)

test("mysql execute: 0 rows affected", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n0\n", "", 0, function()
      local result = mysql.execute("UPDATE t SET x=1 WHERE 1=0", "mysql://root@localhost/test")
      eq(result.affected, 0, "affected")
    end)
  end)
end)

test("mysql execute: an earlier result set is not mistaken for the count", function()
  with_executable(function()
    -- A leading SELECT prints its own rows; only the trailing ROW_COUNT() counts.
    with_system_mock("id\n7\n8\nROW_COUNT()\n2\n", "", 0, function()
      local result = mysql.execute("SELECT id FROM t; UPDATE t SET x=1", "mysql://root@localhost/test")
      eq(result.affected, 2, "affected")
    end)
  end)
end)

test("mysql execute: ROW_COUNT() of -1 (no DML) is reported as 0", function()
  with_executable(function()
    with_system_mock("ROW_COUNT()\n-1\n", "", 0, function()
      local result = mysql.execute("SELECT 1", "mysql://root@localhost/test")
      eq(result.affected, 0, "negative count clamped")
    end)
  end)
end)

-- ── SQLite PRAGMA quoting ────────────────────────────────────────────────────

test("sqlite get_primary_keys: table name is quoted in PRAGMA", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys("users", "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    contains(sql_arg, '"users"', "table name should be quoted")
  end)
end)

test("sqlite get_primary_keys: embedded quote is escaped", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_args._stdin = o and o.stdin
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    sqlite.get_primary_keys('my"table', "sqlite:test.db")
    vim.system = orig
    local sql_arg = last_arg(captured_args)
    -- Double-quote escaping: my"table becomes my""table inside quotes
    contains(sql_arg, 'my""table', "embedded quote should be doubled")
  end)
end)

-- ── DuckDB httpfs extension loading ─────────────────────────────────────────

test("duckdb query: SQL with HTTP URL prepends INSTALL/LOAD httpfs", function()
  with_executable(function()
    local args, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    end)
    assert(not vim.tbl_contains(args, "-c"), "DuckDB SQL must not be in argv")
    contains(opts.stdin, "INSTALL httpfs", "should prepend INSTALL httpfs")
    contains(opts.stdin, "LOAD httpfs", "should prepend LOAD httpfs")
    contains(opts.stdin, "https://example.com/data.csv", "original SQL preserved")
  end)
end)

test("duckdb query: SQL without HTTP URL does not prepend httpfs", function()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM users", "duckdb::memory:")
    end)
    assert(not opts.stdin:find("httpfs", 1, true), "should not contain httpfs: " .. opts.stdin)
  end)
end)

test("duckdb query: attachment setup rows cannot replace query results", function()
  local output = table.concat({
    "Success",
    "true",
    "_grip_boundary",
    "__dadbod_grip_result_boundary__",
    "count_star()",
    "15",
  }, "\n") .. "\n"
  eq(duckdb._strip_csv_setup(output), "count_star()\n15\n", "setup output stripped")
end)

test("duckdb query: httpfs timeout is at least 30 seconds", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(a, opts, cb)
      captured_opts = opts
      local r = { stdout = "col\nval\n", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    vim.system = orig
    assert(captured_opts.timeout >= 30000, "timeout should be >= 30000, got " .. tostring(captured_opts.timeout))
  end)
end)

test("duckdb query: http URL also triggers httpfs", function()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM 'http://example.com/data.csv'", "duckdb::memory:")
    end)
    contains(opts.stdin, "httpfs", "http should also trigger httpfs")
  end)
end)

-- ── DuckDB scanner extension install timeout ────────────────────────────────
-- The ATTACH prefix carries "INSTALL <scanner>" into every query on an attached
-- connection, and the first one has to fetch that extension from
-- extensions.duckdb.org -- the same cost the httpfs block above already buys
-- headroom for. Without it the fetch has to fit inside the 10s query timeout,
-- which is what took CI's test (stable) down on the run for 010d91d: duckdb
-- killed at 124, and 13 assertions failing about catalogs that were never
-- attached. The headroom is deliberately not unconditional -- a warm INSTALL is
-- a local no-op, and an unreachable database should still fail in 10s, not 60.

test("duckdb query: a cold scanner INSTALL gets the network timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:cold_scanner.db"
  duckdb._attach_unchecked(url, "sqlite:legacy.db", "legacy")
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT * FROM legacy.orders", url)
    end)
    assert(opts.timeout >= 60000,
      "a cold scanner fetch needs >= 60000, got " .. tostring(opts.timeout))
  end)
  duckdb.detach(url, "legacy")
end)

test("duckdb query: a scanner installed earlier this session keeps the default timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:warm_scanner.db"
  duckdb._attach_unchecked(url, "sqlite:legacy.db", "legacy")
  with_executable(function()
    -- Arrange: one clean exit, which is what marks the scanner installed.
    capture_system_call("col\nval\n", function() duckdb.query("SELECT 1", url) end)
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", url)
    end)
    eq(opts.timeout, 10000, "a warm scanner must not buy network headroom")
  end)
  duckdb.detach(url, "legacy")
end)

test("duckdb query: a query with no attachments keeps the default timeout", function()
  duckdb._forget_installed_extensions()
  with_executable(function()
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", "duckdb::memory:")
    end)
    eq(opts.timeout, 10000, "an unattached query has no INSTALL to wait for")
  end)
end)

test("duckdb query: a scanner whose query failed keeps the network timeout next time", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:failed_scanner.db"
  duckdb._attach_unchecked(url, "postgres:dbname=sales", "pg")
  with_executable(function()
    -- A non-zero exit says nothing about whether the fetch got through, so it
    -- must not be remembered as an install that succeeded.
    with_system_mock("", 'Extension "postgres_scanner" not found', 1, function()
      duckdb.query("SELECT 1", url)
    end)
    local _, opts = capture_system_call("col\nval\n", function()
      duckdb.query("SELECT 1", url)
    end)
    assert(opts.timeout >= 60000,
      "a failed install must not count as installed, got " .. tostring(opts.timeout))
  end)
  duckdb.detach(url, "pg")
end)

test("duckdb attach: validating a scanner-backed DSN gets the network timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:attach_scanner.db"
  local _, opts = capture_system_call("42\n", function()
    duckdb.attach(url, "md:cloud_db", "cloud")
  end)
  assert(opts.timeout >= 60000,
    "attach validation runs the very first INSTALL, got " .. tostring(opts.timeout))
  duckdb.detach(url, "cloud")
end)

test("duckdb attach: a DSN with no scanner keeps the default validation timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:attach_plain.db"
  local _, opts = capture_system_call("42\n", function()
    duckdb.attach(url, "/tmp/plain.duckdb", "plain")
  end)
  eq(opts.timeout, 10000, "no scanner means no fetch to wait for")
  duckdb.detach(url, "plain")
end)

test("duckdb attach: plain validation honors the configured timeout", function()
  local grip = require("dadbod-grip")
  grip.setup({ timeout = 4321 })
  local ok, err = pcall(function()
    local url = "duckdb:attach_configured_timeout.db"
    local _, opts = capture_system_call("42\n", function()
      duckdb.attach(url, "/tmp/plain.duckdb", "plain")
    end)
    eq(opts.timeout, 4321, "configured timeout")
    duckdb.detach(url, "plain")
  end)
  grip.setup({})
  if not ok then error(err) end
end)

-- ── SQLite get_constraints ───────────────────────────────────────────────────

test("sqlite get_constraints: queries sqlite_master with table name", function()
  local captured_args
  local orig = vim.system
  vim.system = function(a, o, cb)
    captured_args = a
    captured_args._stdin = o and o.stdin
    local r = { stdout = "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  sqlite.get_constraints("users", "sqlite:test.db")
  vim.system = orig
  local sql_arg = last_arg(captured_args)
  contains(sql_arg, "sqlite_master", "queries sqlite_master")
  contains(sql_arg, "users", "filters by table name")
end)

test("sqlite get_constraints: parses UNIQUE constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  email TEXT,\n  UNIQUE (email)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_unique = false
    for _, c in ipairs(result) do
      if c.type == "UNIQUE" then found_unique = true end
    end
    assert(found_unique, "should detect UNIQUE constraint in DDL")
  end)
end)

test("sqlite get_constraints: parses CHECK constraint from DDL", function()
  local ddl = "sql\nCREATE TABLE users (\n  id INTEGER,\n  age INTEGER,\n  CHECK (age > 0)\n)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("users", "sqlite:test.db")
    local found_check = false
    for _, c in ipairs(result) do
      if c.type == "CHECK" then found_check = true end
    end
    assert(found_check, "should detect CHECK constraint in DDL")
  end)
end)

test("sqlite get_constraints: falls back to DDL entry when no named constraints", function()
  local ddl = "sql\nCREATE TABLE simple (id INTEGER, name TEXT)"
  with_system_mock(ddl, "", 0, function()
    local result = sqlite.get_constraints("simple", "sqlite:test.db")
    eq(#result, 1, "one fallback entry")
    eq(result[1].type, "DDL", "fallback type is DDL")
    contains(result[1].definition, "CREATE TABLE", "definition contains DDL")
  end)
end)

test("sqlite get_constraints: returns empty for empty DDL output", function()
  with_system_mock("", "", 0, function()
    local result = sqlite.get_constraints("empty", "sqlite:test.db")
    eq(#result, 0, "empty list for empty output")
  end)
end)

-- ── DuckDB get_constraints ───────────────────────────────────────────────────

test("duckdb get_constraints: queries duckdb_constraints() for table", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(_a, opts, cb)
      captured_opts = opts
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("users", "duckdb::memory:")
    vim.system = orig
    contains(captured_opts.stdin, "duckdb_constraints", "queries duckdb_constraints()")
    contains(captured_opts.stdin, "users", "filters by table name")
  end)
end)

test("duckdb get_constraints: filters by schema name", function()
  with_executable(function()
    local captured_opts
    local orig = vim.system
    vim.system = function(_a, opts, cb)
      captured_opts = opts
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("myschema.users", "duckdb:test.db")
    vim.system = orig
    contains(captured_opts.stdin, "myschema", "includes schema filter")
    contains(captured_opts.stdin, "users", "includes table filter")
  end)
end)

test("duckdb get_constraints: parses CSV output into constraint rows", function()
  with_executable(function()
    local csv = "constraint_name,constraint_type,definition\nemail_unique,UNIQUE,email\nage_check,CHECK,age > 0\n"
    with_system_mock(csv, "", 0, function()
      local result = duckdb.get_constraints("users", "duckdb::memory:")
      eq(#result, 2, "two constraints parsed")
      eq(result[1].name, "email_unique", "first constraint name")
      eq(result[1].type, "UNIQUE", "first constraint type")
      eq(result[2].name, "age_check", "second constraint name")
      eq(result[2].type, "CHECK", "second constraint type")
    end)
  end)
end)

test("duckdb get_constraints: returns empty list on query failure", function()
  with_executable(function()
    with_system_mock("", "Error: table not found", 1, function()
      local result, err = duckdb.get_constraints("missing", "duckdb::memory:")
      eq(#result, 0, "empty list on error")
      -- The error is swallowed on purpose: a non-zero exit here usually means the
      -- server predates duckdb_constraints(), which must degrade to "no
      -- constraints", not surface as a failure. Pinned so a later "let's
      -- propagate the error" change has to face that trade-off deliberately.
      eq(err, nil, "query failure reports no error")
    end)
  end)
end)

-- ── MySQL sql_mode: NO_BACKSLASH_ESCAPES ─────────────────────────────────────

test("mysql query: stdin session setup includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local args, opts = capture_system_call("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    assert(not table.concat(args, " "):find("--init-command", 1, true), "no init command in argv")
    contains(opts.stdin, "NO_BACKSLASH_ESCAPES", "query sql_mode setup")
    contains(opts.stdin, "SELECT 1", "query delivered via stdin")
  end)
end)

test("mysql execute: stdin session setup includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local captured_args, captured_opts
    local orig = vim.system
    vim.system = function(a, o, cb)
      captured_args = a
      captured_opts = o
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1 WHERE id=1", "mysql://root@localhost/test")
    vim.system = orig
    assert(not table.concat(captured_args, " "):find("--init-command", 1, true), "no init command in argv")
    contains(captured_opts.stdin, "NO_BACKSLASH_ESCAPES", "execute sql_mode setup")
    contains(captured_opts.stdin, "UPDATE t SET x=1", "statement delivered via stdin")
  end)
end)

-- ── MySQL query flags ────────────────────────────────────────────────────────
-- MySQL and MariaDB are driven identically: --batch for both.

test("mysql query: uses --batch flag", function()
  with_executable(function()
    local args = capture_system_args("id\t1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    has_arg(args, "--batch", "MySQL should use --batch")
  end)
end)

-- ── PostgreSQL get_schema_batch ──────────────────────────────────────────────
-- get_schema_batch returns all table columns in a single query instead of N+1.
-- Contract: { [table_name] = [{column_name, data_type, is_nullable}] } or nil.

test("pg get_schema_batch: returns columns keyed by table name", function()
  -- CSV output: psql --csv returns header + rows for all tables in one query
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "public,users,id,integer,NO",
    "public,users,email,text,NO",
    "public,users,name,text,YES",
    "public,orders,id,integer,NO",
    "public,orders,user_id,integer,NO",
    "public,orders,total,numeric,YES",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  assert(result["orders"] ~= nil, "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 3, "orders has 3 columns")
  eq(result["users"][1].column_name, "id", "users first col is id")
  eq(result["users"][2].column_name, "email", "users second col is email")
  eq(result["orders"][3].data_type, "numeric", "orders third col type is numeric")
end)

test("pg get_schema_batch: non-public schema uses schema.table key", function()
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "analytics,events,id,bigint,NO",
    "analytics,events,ts,timestamp,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["analytics.events"] ~= nil, "must have analytics.events key")
  eq(#result["analytics.events"], 2, "analytics.events has 2 columns")
end)

test("pg get_schema_batch: mixed schemas", function()
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "public,users,id,integer,NO",
    "analytics,events,id,bigint,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "public.users -> users")
  assert(result["analytics.events"] ~= nil, "analytics.events keeps prefix")
end)

test("pg get_schema_batch: psql failure returns nil", function()
  local result
  with_system_mock("", "connection refused", 1, function()
    result = pg.get_schema_batch("postgresql://localhost/test")
  end)
  eq(result, nil, "should return nil on failure")
end)

test("pg get_schema_batch: single subprocess call", function()
  local call_count = 0
  local orig = vim.system
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    local csv = "table_schema,table_name,column_name,data_type,is_nullable\npublic,t1,c1,int,NO\n"
    local r = { stdout = csv, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  pg.get_schema_batch("postgresql://localhost/test")
  vim.system = orig
  eq(call_count, 1, "exactly one subprocess call for batch")
end)

-- ── MySQL get_schema_batch ──────────────────────────────────────────────────

test("mysql get_schema_batch: returns columns keyed by table name", function()
  -- MySQL --batch output format (tab-separated)
  local tsv_stdout = table.concat({
    "table_name\tcolumn_name\tdata_type\tis_nullable",
    "customers\tcust_id\tint\tNO",
    "customers\tregion\tvarchar(255)\tYES",
    "products\tsku\tvarchar(50)\tNO",
    "products\tprice\tdecimal(10,2)\tYES",
  }, "\n") .. "\n"

  local result
  with_executable(function()
    with_system_mock(tsv_stdout, "", 0, function()
      result = mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
    end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["customers"] ~= nil, "must have customers key")
  assert(result["products"] ~= nil, "must have products key")
  eq(#result["customers"], 2, "customers has 2 columns")
  eq(#result["products"], 2, "products has 2 columns")
  eq(result["customers"][1].column_name, "cust_id", "first col name")
  eq(result["products"][2].data_type, "decimal(10,2)", "price data type")
end)

test("mysql get_schema_batch: mysql failure returns nil", function()
  local result
  with_executable(function()
    with_system_mock("", "access denied", 1, function()
      result = mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
    end)
  end)
  eq(result, nil, "should return nil on failure")
end)

test("mysql get_schema_batch: single subprocess call", function()
  local call_count = 0
  local orig = vim.system
  local orig_exe = vim.fn.executable
  vim.fn.executable = function() return 1 end
  vim.system = function(args, opts, cb)
    call_count = call_count + 1
    local csv = "table_name\tcolumn_name\tdata_type\tis_nullable\nt1\tc1\tint\tNO\n"
    local r = { stdout = csv, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
  vim.system = orig
  vim.fn.executable = orig_exe
  eq(call_count, 1, "exactly one subprocess call for batch")
end)

-- ── MySQL column types come from COLUMN_TYPE ─────────────────────────────────
-- Rebuilding the type from DATA_TYPE + CHARACTER_MAXIMUM_LENGTH/NUMERIC_PRECISION
-- renders enum(7), float(12) and longtext(4294967295) -- shaped like DDL, wrong.

local function assert_uses_column_type(sql, label)
  contains(sql, "c.COLUMN_TYPE AS data_type", label .. " selects COLUMN_TYPE")
  assert(not sql:find("NUMERIC_PRECISION", 1, true),
    label .. " must not rebuild the type from NUMERIC_PRECISION")
  assert(not sql:find("CHARACTER_MAXIMUM_LENGTH", 1, true),
    label .. " must not rebuild the type from CHARACTER_MAXIMUM_LENGTH")
end

test("mysql get_schema_batch: type comes from COLUMN_TYPE with MariaDB widths normalized", function()
  local tsv = table.concat({
    "table_name\tcolumn_name\tdata_type\tis_nullable",
    "type_zoo\tfeeling\tenum('happy','sad','neutral')\tYES",
    "type_zoo\tbig_unsigned\tbigint(20) unsigned\tYES",
  }, "\n") .. "\n"

  local args, result
  with_executable(function()
    args = capture_system_args(tsv, function()
      result = mysql.get_schema_batch("mysql://root:pass@localhost/testdb")
    end)
  end)

  assert_uses_column_type(last_arg(args), "SCHEMA_BATCH_SQL")
  eq(result["type_zoo"][1].data_type, "enum('happy','sad','neutral')",
    "enum value list survives the TSV round-trip, commas and quotes included")
  eq(result["type_zoo"][2].data_type, "bigint unsigned", "display width removed; unsigned kept")
end)

test("mysql get_column_info: type comes from COLUMN_TYPE verbatim", function()
  local tsv = table.concat({
    "column_name\tdata_type\tis_nullable\tcolumn_default\tconstraints",
    "feeling\tenum('happy','sad','neutral')\tYES\t\t",
    "approx_float\tfloat\tYES\t\t",
    "maria_id\tint(11) unsigned\tNO\t\t",
    "unit_price\tdecimal(10,2)\tNO\t\tPRI",
  }, "\n") .. "\n"

  local args, cols
  with_executable(function()
    args = capture_system_args(tsv, function()
      cols = mysql.get_column_info("type_zoo", "mysql://root:pass@localhost/testdb")
    end)
  end)

  assert_uses_column_type(last_arg(args), "get_column_info SQL")
  eq(cols[1].data_type, "enum('happy','sad','neutral')", "enum list")
  eq(cols[2].data_type, "float", "float without a bogus precision")
  eq(cols[3].data_type, "int unsigned", "MariaDB integer width removed; modifier kept")
  eq(cols[4].data_type, "decimal(10,2)", "decimal keeps precision and scale")
  eq(cols[4].constraints, "PRIMARY KEY", "COLUMN_KEY still maps to a constraint label")
end)

-- ── SQLite get_schema_batch ──────────────────────────────────────────────────

test("sqlite get_schema_batch: returns columns keyed by table name", function()
  local csv_stdout = table.concat({
    "table_name,column_name,data_type,is_nullable",
    "orders,id,INTEGER,YES",
    "orders,total,REAL,YES",
    "users,id,INTEGER,YES",
    "users,name,TEXT,NO",
    "users,email,TEXT,YES",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_schema_batch("sqlite:test.db")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  assert(result["orders"] ~= nil, "must have orders key")
  eq(#result["users"], 3, "users has 3 columns")
  eq(#result["orders"], 2, "orders has 2 columns")
  eq(result["users"][2].column_name, "name", "users second col is name")
  eq(result["users"][2].is_nullable, "NO", "name is NOT NULL")
end)

test("sqlite get_schema_batch: failure returns nil", function()
  local result
  with_system_mock("", "unable to open database", 1, function()
    result = sqlite.get_schema_batch("sqlite:nonexistent.db")
  end)
  eq(result, nil, "should return nil on failure")
end)

-- ── get_schema_batch_async ───────────────────────────────────────────────────
-- warm_schema pre-fills the completion cache off the keystroke path, so every
-- adapter that can batch-fetch synchronously must also do it asynchronously.
-- The contract mirrors the DuckDB implementation: callback(tables) on success,
-- callback(nil) on any failure, delivered from the main loop via vim.schedule.

--- Drive an async batch call to completion and return what it passed back.
--- run_cmd_async hands the callback to vim.schedule, so the loop must be pumped
--- before asserting; a callback that never fires is a failure, not a nil result.
local function await_batch(call)
  local done, got = false, nil
  call(function(tables) got = tables; done = true end)
  vim.wait(2000, function() return done end, 1)
  assert(done, "async callback never fired")
  return got
end

local function eq_argv(a, b, msg)
  eq(#a, #b, (msg or "") .. ": argv length")
  for i = 1, #a do
    eq(a[i], b[i], string.format("%s: argv[%d]", msg or "", i))
  end
end

-- The whole point of the shared SQL/parser helpers: if the async path ever
-- builds a different command line than the blocking one, the two can return
-- different schemas for the same database. Comparing argv catches both a
-- diverging statement and diverging CLI flags in one assertion.
local BATCH_ARGV_CASES = {
  { name = "pg",        mod = pg,        url = "postgresql://localhost/test" },
  { name = "mysql",     mod = mysql,     url = "mysql://root:pass@localhost/testdb" },
  { name = "sqlite",    mod = sqlite,    url = "sqlite:test.db" },
  { name = "sqlserver", mod = sqlserver, url = "sqlserver://sa:pw@localhost:1433/testdb" },
}

for _, case in ipairs(BATCH_ARGV_CASES) do
  test(case.name .. " get_schema_batch_async: identical process input to the blocking path", function()
    local sync_argv, sync_opts, async_argv, async_opts
    with_executable(function()
      sync_argv, sync_opts = capture_system_call("", function()
        case.mod.get_schema_batch(case.url)
      end)
      async_argv, async_opts = capture_system_call("", function()
        await_batch(function(cb) case.mod.get_schema_batch_async(case.url, cb) end)
      end)
    end)
    assert(sync_argv ~= nil, case.name .. ": blocking path must spawn a process")
    assert(async_argv ~= nil, case.name .. ": async path must spawn a process")
    eq_argv(async_argv, sync_argv, case.name .. " async argv must match sync argv")
    eq(async_opts.stdin, sync_opts.stdin, case.name .. " async stdin must match sync stdin")
    local sync_env = vim.deepcopy(sync_opts.env or {})
    local async_env = vim.deepcopy(async_opts.env or {})
    if case.name == "pg" then
      assert(sync_env.PGSERVICEFILE and async_env.PGSERVICEFILE, "pg service files missing")
      sync_env.PGSERVICEFILE, async_env.PGSERVICEFILE = nil, nil
    end
    assert(vim.deep_equal(async_env, sync_env), case.name .. " async env must match sync env")
  end)
end

-- Lives here rather than beside the other scanner-timeout tests because it needs
-- await_batch. The pre-warm path prepends the same ATTACH prefix, so it pays the
-- same one-off extension fetch and needs the same cold-install headroom as a
-- foreground query.
test("duckdb get_schema_batch_async: a cold scanner INSTALL gets the network timeout", function()
  duckdb._forget_installed_extensions()
  local url = "duckdb:async_scanner.db"
  duckdb._attach_unchecked(url, "sqlite:legacy.db", "legacy")
  local _, opts = capture_system_call("", function()
    await_batch(function(cb) duckdb.get_schema_batch_async(url, cb) end)
  end)
  assert(opts.timeout >= 60000,
    "the pre-warm path pays the same fetch, got " .. tostring(opts.timeout))
  duckdb.detach(url, "legacy")
end)

test("SQLite and DuckDB async schema pre-warm honor the configured timeout", function()
  local grip = require("dadbod-grip")
  grip.setup({ timeout = 4321 })
  local ok, err = pcall(function()
    for _, case in ipairs({
      { name = "SQLite", run = function(cb) sqlite.get_schema_batch_async("sqlite:test.db", cb) end },
      { name = "DuckDB", run = function(cb) duckdb.get_schema_batch_async("duckdb::memory:", cb) end },
    }) do
      local _, opts = capture_system_call("", function()
        await_batch(function(cb) case.run(cb) end)
      end)
      eq(opts.timeout, 4321, case.name .. " configured async timeout")
    end
  end)
  grip.setup({})
  if not ok then error(err) end
end)

-- Adapters must not silently lose the async variant: warm_schema is a no-op
-- without it, which is exactly the regression this section exists to prevent.
test("every adapter with get_schema_batch also has get_schema_batch_async", function()
  local mods = {
    postgresql = pg, mysql = mysql, sqlite = sqlite,
    sqlserver = sqlserver, duckdb = duckdb,
  }
  for name, mod in pairs(mods) do
    assert(type(mod.get_schema_batch) == "function", name .. " must have get_schema_batch")
    assert(type(mod.get_schema_batch_async) == "function",
      name .. " must have get_schema_batch_async (warm_schema is a no-op without it)")
  end
end)

test("pg get_schema_batch_async: delivers columns keyed by table name", function()
  local csv_stdout = table.concat({
    "table_schema,table_name,column_name,data_type,is_nullable",
    "public,users,id,integer,NO",
    "public,users,email,text,NO",
    "analytics,events,ts,timestamp,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = await_batch(function(cb) pg.get_schema_batch_async("postgresql://localhost/test", cb) end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  eq(#result["users"], 2, "users has 2 columns")
  eq(result["users"][1].column_name, "id", "column order follows ordinal_position")
  eq(result["users"][2].data_type, "text", "email data type")
  assert(result["analytics.events"] ~= nil, "non-public schema keeps its prefix")
end)

test("pg get_schema_batch_async: psql failure delivers nil", function()
  local result = "unset"
  with_system_mock("", "connection refused", 1, function()
    result = await_batch(function(cb) pg.get_schema_batch_async("postgresql://localhost/test", cb) end)
  end)
  eq(result, nil, "should deliver nil on failure")
end)

test("mysql get_schema_batch_async: delivers columns keyed by table name", function()
  local tsv_stdout = table.concat({
    "table_name\tcolumn_name\tdata_type\tis_nullable",
    "customers\tcust_id\tint\tNO",
    "customers\tregion\tvarchar(255)\tYES",
    "products\tsku\tvarchar(50)\tNO",
  }, "\n") .. "\n"

  local result
  with_executable(function()
    with_system_mock(tsv_stdout, "", 0, function()
      result = await_batch(function(cb)
        mysql.get_schema_batch_async("mysql://root:pass@localhost/testdb", cb)
      end)
    end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["customers"] ~= nil, "must have customers key")
  assert(result["products"] ~= nil, "must have products key")
  eq(#result["customers"], 2, "customers has 2 columns")
  eq(result["customers"][2].data_type, "varchar(255)", "region data type")
  eq(#result["products"], 1, "products has 1 column")
end)

test("mysql get_schema_batch_async: mysql failure delivers nil", function()
  local result = "unset"
  with_executable(function()
    with_system_mock("", "access denied", 1, function()
      result = await_batch(function(cb)
        mysql.get_schema_batch_async("mysql://root:pass@localhost/testdb", cb)
      end)
    end)
  end)
  eq(result, nil, "should deliver nil on failure")
end)

test("mysql get_schema_batch_async: unparseable URL delivers nil without spawning", function()
  local spawned = false
  local orig = vim.system
  vim.system = function(...) spawned = true; return orig(...) end
  local result = await_batch(function(cb) mysql.get_schema_batch_async("mysql://", cb) end)
  vim.system = orig
  eq(result, nil, "should deliver nil for an unparseable URL")
  assert(not spawned, "must not spawn mysql for an unparseable URL")
end)

test("mysql get_schema_batch_async: guard path delivers asynchronously", function()
  local fired = false
  mysql.get_schema_batch_async("mysql://", function() fired = true end)
  eq(fired, false, "callback must not fire on the calling tick")
  vim.wait(200, function() return fired end, 1)
  assert(fired, "callback must fire once the loop is pumped")
end)

test("sqlite get_schema_batch_async: delivers columns keyed by table name", function()
  local csv_stdout = table.concat({
    "table_name,column_name,data_type,is_nullable",
    "orders,id,INTEGER,YES",
    "users,id,INTEGER,YES",
    "users,name,TEXT,NO",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = await_batch(function(cb) sqlite.get_schema_batch_async("sqlite:test.db", cb) end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  assert(result["orders"] ~= nil, "must have orders key")
  eq(#result["users"], 2, "users has 2 columns")
  eq(result["users"][2].column_name, "name", "column order follows cid")
  eq(result["users"][2].is_nullable, "NO", "name is NOT NULL")
  eq(#result["orders"], 1, "orders has 1 column")
end)

test("sqlite get_schema_batch_async: failure delivers nil", function()
  local result = "unset"
  with_system_mock("", "unable to open database", 1, function()
    result = await_batch(function(cb) sqlite.get_schema_batch_async("sqlite:nope.db", cb) end)
  end)
  eq(result, nil, "should deliver nil on failure")
end)

test("sqlite get_schema_batch_async: pathless URL delivers nil without spawning", function()
  local spawned = false
  local orig = vim.system
  vim.system = function(...) spawned = true; return orig(...) end
  local result = await_batch(function(cb) sqlite.get_schema_batch_async("sqlite:", cb) end)
  vim.system = orig
  eq(result, nil, "should deliver nil when no path can be extracted")
  assert(not spawned, "must not spawn sqlite3 without a db path")
end)

test("sqlite get_schema_batch_async: guard path delivers asynchronously", function()
  local fired = false
  sqlite.get_schema_batch_async("sqlite:", function() fired = true end)
  eq(fired, false, "callback must not fire on the calling tick")
  vim.wait(200, function() return fired end, 1)
  assert(fired, "callback must fire once the loop is pumped")
end)

test("sqlserver get_schema_batch_async: delivers columns keyed by table name", function()
  local tsv_stdout = table.concat({
    "table_name\tCOLUMN_NAME\tdata_type\tIS_NULLABLE",
    "invoices\tid\tint\tNO",
    "invoices\tamount\tdecimal(10,2)\tYES",
    "sales.leads\tid\tint\tNO",
  }, "\n") .. "\n"

  local result
  with_executable(function()
    with_system_mock(tsv_stdout, "", 0, function()
      result = await_batch(function(cb)
        sqlserver.get_schema_batch_async("sqlserver://sa:pw@localhost:1433/testdb", cb)
      end)
    end)
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["invoices"] ~= nil, "must have invoices key")
  eq(#result["invoices"], 2, "invoices has 2 columns")
  eq(result["invoices"][2].data_type, "decimal(10,2)", "amount data type")
  assert(result["sales.leads"] ~= nil, "non-dbo schema keeps its prefix")
end)

test("sqlserver get_schema_batch_async: sqlcmd failure delivers nil", function()
  local result = "unset"
  with_executable(function()
    with_system_mock("", "login failed", 1, function()
      result = await_batch(function(cb)
        sqlserver.get_schema_batch_async("sqlserver://sa:pw@localhost:1433/testdb", cb)
      end)
    end)
  end)
  eq(result, nil, "should deliver nil on failure")
end)

test("sqlserver get_schema_batch_async: missing sqlcmd delivers nil without spawning", function()
  local spawned = false
  local orig_sys, orig_exe = vim.system, vim.fn.executable
  vim.system = function(...) spawned = true; return orig_sys(...) end
  vim.fn.executable = function() return 0 end
  local result = await_batch(function(cb)
    sqlserver.get_schema_batch_async("sqlserver://sa:pw@localhost:1433/testdb", cb)
  end)
  vim.system, vim.fn.executable = orig_sys, orig_exe
  eq(result, nil, "should deliver nil when sqlcmd is absent")
  assert(not spawned, "must not spawn a missing sqlcmd")
end)

test("sqlserver get_schema_batch_async: guard path delivers asynchronously", function()
  local orig_exe = vim.fn.executable
  vim.fn.executable = function() return 0 end
  local fired = false
  sqlserver.get_schema_batch_async("sqlserver://sa:pw@localhost:1433/testdb", function() fired = true end)
  vim.fn.executable = orig_exe
  eq(fired, false, "callback must not fire on the calling tick")
  vim.wait(200, function() return fired end, 1)
  assert(fired, "callback must fire once the loop is pumped")
end)

-- adapters.resolve() matches schemes case-insensitively, but duckdb's own
-- extract_path patterns are literal lowercase "duckdb:" -- so an uppercase
-- "DUCKDB:..." URL reaches duckdb.lua (the resolver routed it there) and then
-- fails extract_path, a real (if obscure) way to hit this guard, not a
-- contrived one.
test("duckdb get_schema_batch_async: unparseable URL delivers nil without spawning", function()
  local spawned = false
  local orig = vim.system
  vim.system = function(...) spawned = true; return orig(...) end
  local result = await_batch(function(cb) duckdb.get_schema_batch_async("DUCKDB:/tmp/x.db", cb) end)
  vim.system = orig
  eq(result, nil, "should deliver nil for an unparseable URL")
  assert(not spawned, "must not spawn duckdb for an unparseable URL")
end)

test("duckdb get_schema_batch_async: guard path delivers asynchronously", function()
  local fired = false
  duckdb.get_schema_batch_async("DUCKDB:/tmp/x.db", function() fired = true end)
  eq(fired, false, "callback must not fire on the calling tick")
  vim.wait(200, function() return fired end, 1)
  assert(fired, "callback must fire once the loop is pumped")
end)

-- ── SQLite get_indexes ───────────────────────────────────────────────────────
-- Single pragma_index_list/pragma_index_info join (one spawn) replaces the old
-- index_list-then-loop-over-index_info (one spawn per index).

test("sqlite get_indexes: groups columns per index preserving seqno order", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "idx_desc,0,c,0,d",
    "idx_desc,0,c,1,a",
    "idx_ab,1,c,0,a",
    "idx_ab,1,c,1,b",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)

  eq(#result, 2, "two indexes")
  eq(result[1].name, "idx_desc", "first index in seq order")
  eq(result[1].type, "INDEX", "plain index")
  eq(#result[1].columns, 2, "idx_desc has 2 columns")
  eq(result[1].columns[1], "d", "idx_desc column order follows seqno")
  eq(result[1].columns[2], "a", "idx_desc column order follows seqno")
  eq(result[2].name, "idx_ab", "second index in seq order")
  eq(result[2].type, "UNIQUE", "unique index")
  eq(result[2].columns[1], "a", "idx_ab column order follows seqno")
  eq(result[2].columns[2], "b", "idx_ab column order follows seqno")
end)

test("sqlite get_indexes: origin=pk maps to PRIMARY", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "sqlite_autoindex_t_1,1,pk,0,tenant_id",
    "sqlite_autoindex_t_1,1,pk,1,user_id",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)

  eq(#result, 1, "one index")
  eq(result[1].type, "PRIMARY", "pk origin maps to PRIMARY")
  eq(#result[1].columns, 2, "composite pk has 2 columns")
end)

test("sqlite get_indexes: single spawn regardless of index count", function()
  local csv_stdout = table.concat({
    "idx_name,unique,origin,seqno,col_name",
    "idx_a,0,c,0,x",
    "idx_b,0,c,0,y",
    "idx_c,1,c,0,z",
  }, "\n") .. "\n"

  local calls = 0
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    calls = calls + 1
    local r = { stdout = csv_stdout, stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local result = sqlite.get_indexes("t", "sqlite:test.db")
  vim.system = orig

  eq(#result, 3, "three indexes")
  eq(calls, 1, "exactly one process spawned for any number of indexes")
end)

test("sqlite get_indexes: table name is escaped as a string literal, not an identifier", function()
  local args = capture_system_args("idx_name,unique,origin,seqno,col_name\n", function()
    sqlite.get_indexes("o'brien", "sqlite:test.db")
  end)
  local sql_arg = last_arg(args)
  contains(sql_arg, "pragma_index_list('o''brien')", "single quote doubled via escape_literal")
end)

test("sqlite get_indexes: empty result for table with no indexes", function()
  local result
  with_system_mock("idx_name,unique,origin,seqno,col_name\n", "", 0, function()
    result = sqlite.get_indexes("t", "sqlite:test.db")
  end)
  eq(#result, 0, "no indexes")
end)

-- ── DuckDB get_schema_batch ───────────────────────────────────────────────────
-- Unlike pg/mysql/sqlite, DuckDB's batch query is always the same 8-column shape
-- (rtype, database_name, schema_name, table_name, column_name, data_type,
-- is_nullable, column_index), sourced from duckdb_columns()/duckdb_views() in both
-- attachment modes -- so is_nullable/column-order is tested in both modes, plus the
-- generated SQL text itself is checked directly (execution correctness can't be
-- verified here -- no duckdb binary in this sandbox).

test("duckdb get_schema_batch: no attachments, is_nullable comes from duckdb_columns()", function()
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,plain,main,users,id,INTEGER,NO,0",
    "col,plain,main,users,name,VARCHAR,YES,1",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch("duckdb:plain.db")
  end)

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "must have users key")
  eq(result["users"][1].column_name, "id", "column order preserved (id first)")
  eq(result["users"][1].is_nullable, "NO", "id is NOT NULL")
  eq(result["users"][2].column_name, "name", "column order preserved (name second)")
  eq(result["users"][2].is_nullable, "YES", "name is nullable")
end)

test("duckdb get_schema_batch: with attachments, is_nullable kept for main catalog, blanked for attached", function()
  local url = "duckdb:test_attach.db"

  -- Fake a successful ATTACH so _attachments[url] is populated (drives has_attachments=true).
  with_system_mock("", "", 0, function()
    duckdb.load_attachments(url, { { dsn = "sqlite:other.db", alias = "sup" } })
  end)

  -- database_name "test_attach" matches _extract_path("test_attach.db") -> main_catalog "test_attach".
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,test_attach,main,users,id,INTEGER,NO,0",
    "col,test_attach,main,users,name,VARCHAR,YES,1",
    "col,sup,main,orders,id,INTEGER,YES,0",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch(url)
  end)

  duckdb.load_attachments(url, {})  -- reset attachment state for later tests

  assert(result ~= nil, "result must not be nil")
  assert(result["users"] ~= nil, "main-catalog table present")
  eq(result["users"][1].is_nullable, "NO", "main catalog is_nullable preserved")
  eq(result["users"][2].is_nullable, "YES", "main catalog is_nullable preserved (2nd col)")
  assert(result["sup.orders"] ~= nil, "attached-catalog table present")
  eq(result["sup.orders"][1].is_nullable, "",
    "attached catalog is_nullable blanked -- matches get_column_info's attached-catalog branch")
end)

test("duckdb get_schema_batch: parser preserves whatever row order the query returns", function()
  -- Regression guard: the Lua parser must not silently reorder rows -- column
  -- order in the prompt depends entirely on _make_schema_batch_sql's ORDER BY
  -- (checked directly below), not on any re-sorting here.
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "col,plain,main,users,name,VARCHAR,YES,1",
    "col,plain,main,users,id,INTEGER,NO,0",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch("duckdb:plain.db")
  end)

  eq(result["users"][1].column_name, "name", "parser preserves row order as received")
  eq(result["users"][2].column_name, "id", "parser preserves row order as received")
end)

test("duckdb _make_schema_batch_sql: orders by table_name + column_index so column order is stable", function()
  -- Was previously "ORDER BY 1, 2, 3" (rtype, database_name, schema_name only) --
  -- no guarantee at all for column order within a table, or even that a table's
  -- rows stay grouped together.
  local sql_no_att = duckdb._make_schema_batch_sql(false, "plain")
  contains(sql_no_att, "column_index", "SELECT list includes column_index")
  contains(sql_no_att, "ORDER BY 2, 3, 4, 8", "ORDER BY includes table_name + column_index")

  local sql_att = duckdb._make_schema_batch_sql(true, "plain")
  contains(sql_att, "column_index", "SELECT list includes column_index (attachments)")
  contains(sql_att, "ORDER BY 2, 3, 4, 8", "ORDER BY includes table_name + column_index (attachments)")
end)

test("duckdb _make_schema_batch_sql: is_nullable sourced from duckdb_columns(), not information_schema", function()
  -- get_column_info never reads information_schema for DuckDB (both its branches use
  -- duckdb_columns()); the batch query previously did for the no-attachments case,
  -- which meant its is_nullable format was an unverified guess rather than proven-correct.
  local sql_no_att = duckdb._make_schema_batch_sql(false, "plain")
  assert(not sql_no_att:find("information_schema", 1, true),
    "no-attachments batch query must not depend on information_schema's is_nullable convention")
  contains(sql_no_att, "duckdb_columns()", "sourced from duckdb_columns()")
  contains(sql_no_att, "duckdb_views()", "views still registered name-only via duckdb_views()")
end)

-- ── duckdb: main catalog name ───────────────────────────────────────────────
-- DuckDB names the main catalog after the file's basename without extension,
-- and calls the in-memory one "memory". The batch/column/PK/table queries all
-- filter on that name as a string literal, so getting ":memory:" wrong there
-- makes every one of them match nothing.

test("duckdb _main_catalog_name: :memory: maps to DuckDB's 'memory' catalog", function()
  eq(duckdb._main_catalog_name(":memory:"), "memory", "in-memory catalog is named 'memory'")
end)

test("duckdb _main_catalog_name: file paths keep the basename without extension", function()
  eq(duckdb._main_catalog_name("/data/softrear.duckdb"), "softrear", "absolute path")
  eq(duckdb._main_catalog_name("softrear.db"), "softrear", "relative path")
  eq(duckdb._main_catalog_name("/data/noext"), "noext", "no extension")
end)

test("duckdb _make_schema_batch_sql: :memory: filters on 'memory', never ':memory:'", function()
  -- The old inline expression produced "database_name = ':memory:'", which matches
  -- no row at all -- get_schema_batch then returned {} and completion cached an
  -- empty schema with nothing to fall back to.
  local sql_mem = duckdb._make_schema_batch_sql(false, duckdb._main_catalog_name(":memory:"))
  contains(sql_mem, "database_name = 'memory'", "filters on the real catalog name")
  assert(not sql_mem:find(":memory:", 1, true), "the raw path must never reach the filter")
end)

test("duckdb get_schema_batch: view columns survive the name-only view row", function()
  -- duckdb_columns() does cover views in DuckDB catalogs, and its rows arrive
  -- after the duckdb_views() row (column_index 0 sorts first). The 'tbl' branch
  -- must register the name without clearing what 'col' rows added.
  local csv_stdout = table.concat({
    "rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index",
    "tbl,plain,main,v,,,,0",
    "col,plain,main,v,id,INTEGER,YES,1",
    "col,plain,main,v,doubled,INTEGER,YES,2",
    "tbl,sup,main,sv,,,,0",
  }, "\n") .. "\n"

  local result
  with_system_mock(csv_stdout, "", 0, function()
    result = duckdb.get_schema_batch("duckdb:plain.db")
  end)

  assert(result ~= nil, "result must not be nil")
  eq(#result["v"], 2, "view keeps the columns duckdb_columns() reported")
  eq(result["v"][1].column_name, "id", "first view column")
  eq(result["v"][2].column_name, "doubled", "second view column")
  assert(result["sup.sv"] ~= nil, "attached-catalog view still registered name-only")
  eq(#result["sup.sv"], 0, "no column source exists for views in attached non-DuckDB catalogs")
end)

-- ── Completion: get_schema prefers batch over per-table ─────────────────────
-- When get_schema_batch returns data, list_tables + get_column_info must NOT be called.

test("completion get_schema: uses batch when available, skips per-table", function()
  local compl = require("dadbod-grip.completion")
  local db_mod = require("dadbod-grip.db")

  local batch_called = false
  local list_called = false
  local col_called = false

  local orig_batch = db_mod.get_schema_batch
  local orig_list = db_mod.list_tables
  local orig_cols = db_mod.get_column_info

  db_mod.get_schema_batch = function(url)
    batch_called = true
    return {
      ["users"] = {
        { column_name = "id", data_type = "integer", is_nullable = "NO" },
      },
    }
  end
  db_mod.list_tables = function(url)
    list_called = true
    return { { name = "users" } }, nil
  end
  db_mod.get_column_info = function(tn, url)
    col_called = true
    return {}, nil
  end

  compl.invalidate("postgresql://localhost/batch_pref_test")
  compl.get_schema("postgresql://localhost/batch_pref_test")

  db_mod.get_schema_batch = orig_batch
  db_mod.list_tables = orig_list
  db_mod.get_column_info = orig_cols

  assert(batch_called, "get_schema_batch must be called")
  assert(not list_called, "list_tables must NOT be called when batch succeeds")
  assert(not col_called, "get_column_info must NOT be called when batch succeeds")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nadapter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
