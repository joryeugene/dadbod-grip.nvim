-- adapter_spec.lua — unit tests for adapter URL parsing, output parsing, SQL rewriting
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local duckdb = require("dadbod-grip.adapters.duckdb")
local pg = require("dadbod-grip.adapters.postgresql")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. " — " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

-- ── mock helpers ──────────────────────────────────────────────────────────────

local function with_system_mock(stdout, stderr, code, fn)
  local orig = vim.system
  vim.system = function()
    return { wait = function()
      return { stdout = stdout, stderr = stderr or "", code = code or 0 }
    end }
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
end

local function capture_system_args(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args)
    captured = args
    return { wait = function() return { stdout = stdout or "", stderr = "", code = 0 } end }
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

-- ── MySQL DEFAULT VALUES rewriting ───────────────────────────────────────────

test("mysql execute: DEFAULT VALUES is rewritten", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a)
      captured_args = a
      return { wait = function() return { stdout = "", stderr = "1 row affected", code = 0 } end }
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
    vim.system = function(a)
      captured_args = a
      return { wait = function() return { stdout = "", stderr = "1 row affected", code = 0 } end }
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
    vim.system = function(a)
      captured_args = a
      return { wait = function() return { stdout = "", stderr = "", code = 0 } end }
    end
    sqlite.get_primary_keys("users", "sqlite:test.db")
    vim.system = orig
    -- sqlite3 args: { "sqlite3", "-csv", "-header", db_path, sql_str }
    local sql_arg = captured_args[5]
    contains(sql_arg, '"users"', "table name should be quoted")
  end)
end)

test("sqlite get_primary_keys: embedded quote is escaped", function()
  with_executable(function()
    local captured_args
    local orig = vim.system
    vim.system = function(a)
      captured_args = a
      return { wait = function() return { stdout = "", stderr = "", code = 0 } end }
    end
    sqlite.get_primary_keys('my"table', "sqlite:test.db")
    vim.system = orig
    -- sqlite3 args: { "sqlite3", "-csv", "-header", db_path, sql_str }
    local sql_arg = captured_args[5]
    -- Double-quote escaping: my"table becomes my""table inside quotes
    contains(sql_arg, 'my""table', "embedded quote should be doubled")
  end)
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nadapter_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
