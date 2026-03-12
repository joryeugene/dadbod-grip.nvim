-- adapter_spec.lua: unit tests for adapter URL parsing, output parsing, SQL rewriting
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local duckdb = require("dadbod-grip.adapters.duckdb")
local pg = require("dadbod-grip.adapters.postgresql")

-- Pre-seed MariaDB cache to prevent vim.fn.system calls during tests.
-- Individual MariaDB-specific tests override this explicitly.
mysql._set_mariadb(false)

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
  return args[#args]
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
  vim.system = function(args, _opts, cb)
    captured = args
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
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

test("pg ping: passes -X to skip .psqlrc", function()
  with_executable(function()
    local args = capture_system_args("", function()
      pg.ping("postgresql://localhost/db")
    end)
    has_arg(args, "-X", "ping should pass -X")
  end)
end)

-- ── SQLite .sqliterc bypass ─────────────────────────────────────────────

test("sqlite query: passes -init '' to skip .sqliterc", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      sqlite.query("SELECT 1", "sqlite:test.db")
    end)
    has_arg(args, "-init", "query should pass -init")
  end)
end)

-- ── MySQL DEFAULT VALUES rewriting ───────────────────────────────────────────

test("mysql execute: DEFAULT VALUES is rewritten", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t DEFAULT VALUES", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "() VALUES ()", "DEFAULT VALUES rewrite")
    assert(not sql_arg:find("DEFAULT VALUES", 1, true), "DEFAULT VALUES should be gone")
  end)
end)

test("mysql execute: non-DEFAULT-VALUES SQL unchanged", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("INSERT INTO t (name) VALUES ('x')", "mysql://root@localhost/test")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "VALUES ('x')", "SQL unchanged")
  end)
end)

test("mysql execute: affected row parsing from stderr", function()
  with_executable(function()
    with_system_mock("", "3 rows affected", 0, function()
      local result, err = mysql.execute("UPDATE t SET x=1", "mysql://root@localhost/test")
      assert(not err, "should not error: " .. tostring(err))
      eq(result.affected, 3, "affected")
    end)
  end)
end)

test("mysql execute: 0 rows affected", function()
  with_executable(function()
    with_system_mock("", "0 rows affected", 0, function()
      local result = mysql.execute("UPDATE t SET x=1 WHERE 1=0", "mysql://root@localhost/test")
      eq(result.affected, 0, "affected")
    end)
  end)
end)

-- ── SQLite PRAGMA quoting ────────────────────────────────────────────────────

test("sqlite get_primary_keys: table name is quoted in PRAGMA", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
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
    vim.system = function(a, _o, cb)
      captured_args = a
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
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM 'https://example.com/data.csv'", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    contains(sql_arg, "INSTALL httpfs", "should prepend INSTALL httpfs")
    contains(sql_arg, "LOAD httpfs", "should prepend LOAD httpfs")
    contains(sql_arg, "https://example.com/data.csv", "original SQL preserved")
  end)
end)

test("duckdb query: SQL without HTTP URL does not prepend httpfs", function()
  with_executable(function()
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM users", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    assert(not sql_arg:find("httpfs", 1, true), "should not contain httpfs: " .. sql_arg)
  end)
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
    local args = capture_system_args("col\nval\n", function()
      duckdb.query("SELECT * FROM 'http://example.com/data.csv'", "duckdb::memory:")
    end)
    local sql_arg = args[#args]
    contains(sql_arg, "httpfs", "http should also trigger httpfs")
  end)
end)

-- ── SQLite get_constraints ───────────────────────────────────────────────────

test("sqlite get_constraints: queries sqlite_master with table name", function()
  local captured_args
  local orig = vim.system
  vim.system = function(a, _o, cb)
    captured_args = a
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
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("users", "duckdb::memory:")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "duckdb_constraints", "queries duckdb_constraints()")
    contains(sql_arg, "users", "filters by table name")
  end)
end)

test("duckdb get_constraints: filters by schema name", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    duckdb.get_constraints("myschema.users", "duckdb:test.db")
    vim.system = orig
    local sql_arg = captured_args[#captured_args]
    contains(sql_arg, "myschema", "includes schema filter")
    contains(sql_arg, "users", "includes table filter")
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
      -- error is returned (or nil: either is acceptable since duckdb silences errors)
    end)
  end)
end)

-- ── MySQL sql_mode: NO_BACKSLASH_ESCAPES ─────────────────────────────────────

test("mysql query: --init-command includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local args = capture_system_args("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    local init_cmd = nil
    for _, v in ipairs(args) do
      if type(v) == "string" and v:find("--init-command", 1, true) then
        init_cmd = v; break
      end
    end
    assert(init_cmd ~= nil, "must have --init-command arg")
    contains(init_cmd, "NO_BACKSLASH_ESCAPES", "query sql_mode must include NO_BACKSLASH_ESCAPES")
  end)
end)

test("mysql execute: --init-command includes NO_BACKSLASH_ESCAPES", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a, _o, cb)
      captured_args = a
      local r = { stdout = "", stderr = "1 row affected", code = 0 }
      if cb then cb(r) else return { wait = function() return r end } end
    end
    mysql.execute("UPDATE t SET x=1 WHERE id=1", "mysql://root@localhost/test")
    vim.system = orig
    local init_cmd = nil
    for _, v in ipairs(captured_args) do
      if type(v) == "string" and v:find("--init-command", 1, true) then
        init_cmd = v; break
      end
    end
    assert(init_cmd ~= nil, "must have --init-command arg")
    contains(init_cmd, "NO_BACKSLASH_ESCAPES", "execute sql_mode must include NO_BACKSLASH_ESCAPES")
  end)
end)

-- ── MariaDB detection ────────────────────────────────────────────────────────

test("detect_mariadb: MariaDB version string returns true", function()
  mysql._reset_mariadb_cache()
  local orig_exe = vim.fn.executable
  local orig_sys = vim.fn.system
  vim.fn.executable = function() return 1 end
  vim.fn.system = function() return "mysql  Ver 15.1 Distrib 10.11.6-MariaDB, for debian-linux-gnu (x86_64)" end
  local result = mysql._detect_mariadb()
  vim.fn.executable = orig_exe
  vim.fn.system = orig_sys
  mysql._set_mariadb(false)
  eq(result, true, "should detect MariaDB")
end)

test("detect_mariadb: MySQL version string returns false", function()
  mysql._reset_mariadb_cache()
  local orig_exe = vim.fn.executable
  local orig_sys = vim.fn.system
  vim.fn.executable = function() return 1 end
  vim.fn.system = function() return "mysql  Ver 8.0.33 for Linux on x86_64 (MySQL Community Server)" end
  local result = mysql._detect_mariadb()
  vim.fn.executable = orig_exe
  vim.fn.system = orig_sys
  mysql._set_mariadb(false)
  eq(result, false, "should not detect MariaDB")
end)

test("detect_mariadb: mysql not installed returns false", function()
  mysql._reset_mariadb_cache()
  local orig_exe = vim.fn.executable
  vim.fn.executable = function() return 0 end
  local result = mysql._detect_mariadb()
  vim.fn.executable = orig_exe
  mysql._set_mariadb(false)
  eq(result, false, "no mysql binary")
end)

test("detect_mariadb: caches result after first call", function()
  mysql._reset_mariadb_cache()
  local call_count = 0
  local orig_exe = vim.fn.executable
  local orig_sys = vim.fn.system
  vim.fn.executable = function() return 1 end
  vim.fn.system = function() call_count = call_count + 1; return "MariaDB" end
  mysql._detect_mariadb()
  mysql._detect_mariadb()
  mysql._detect_mariadb()
  vim.fn.executable = orig_exe
  vim.fn.system = orig_sys
  mysql._set_mariadb(false)
  eq(call_count, 1, "system called once")
end)

-- ── MariaDB query routing ────────────────────────────────────────────────────

test("mysql query: MariaDB uses --batch flag", function()
  mysql._set_mariadb(true)
  with_executable(function()
    local args = capture_system_args("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    has_arg(args, "--batch", "MariaDB should use --batch")
  end)
  mysql._set_mariadb(false)
end)

test("mysql query: MySQL uses --csv flag", function()
  mysql._set_mariadb(false)
  with_executable(function()
    local args = capture_system_args("id\n1\n", function()
      mysql.query("SELECT 1", "mysql://root@localhost/test")
    end)
    has_arg(args, "--csv", "MySQL should use --csv")
  end)
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nadapter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
