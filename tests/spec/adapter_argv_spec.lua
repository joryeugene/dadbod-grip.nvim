-- adapter_argv_spec.lua: database SQL and credentials must not enter argv.
local pg = require("dadbod-grip.adapters.postgresql")
local mysql = require("dadbod-grip.adapters.mysql")
local sqlite = require("dadbod-grip.adapters.sqlite")
local sqlserver = require("dadbod-grip.adapters.sqlserver")

if vim.uv.os_uname().sysname ~= "Linux" then
  print("SKIP: adapter_argv_spec (/proc cmdline inspection requires Linux)")
  return
end

local dir = vim.fn.tempname() .. "_adapter_argv"
vim.fn.mkdir(dir, "p")
local script = {
  "#!/bin/sh",
  "tr '\\000' '\\n' < /proc/$$/cmdline > \"$GRIP_DB_CMDLINE_FILE\"",
  "cat > \"$GRIP_DB_STDIN_FILE\"",
  "case \"${0##*/}\" in",
  "  psql)",
  "    printf 'PGSERVICE=%s\\nPGPASSWORD=%s\\nPGOPTIONS=%s\\n' \"$PGSERVICE\" \"$PGPASSWORD\" \"$PGOPTIONS\" > \"$GRIP_DB_ENV_FILE\"",
  "    cat \"$PGSERVICEFILE\" >> \"$GRIP_DB_ENV_FILE\"",
  "    printf 'value\\n1\\n'",
  "    ;;",
  "  mysql)",
  "    printf 'MYSQL_PWD=%s\\n' \"$MYSQL_PWD\" > \"$GRIP_DB_ENV_FILE\"",
  "    printf 'ROW_COUNT()\\n1\\n'",
  "    ;;",
  "  sqlite3)",
  "    : > \"$GRIP_DB_ENV_FILE\"",
  "    printf 'changes()\\n1\\n'",
  "    ;;",
  "  sqlcmd)",
  "    printf 'SQLCMDPASSWORD=%s\\n' \"$SQLCMDPASSWORD\" > \"$GRIP_DB_ENV_FILE\"",
  "    printf '(1 row affected)\\n'",
  "    ;;",
  "esac",
}
for _, bin in ipairs({ "psql", "mysql", "sqlite3", "sqlcmd" }) do
  local path = dir .. "/" .. bin
  vim.fn.writefile(script, path)
  assert(vim.fn.setfperm(path, "rwx------") == 1, "could not create fake " .. bin)
end

local old = {
  path = vim.env.PATH,
  cmdline = vim.env.GRIP_DB_CMDLINE_FILE,
  stdin = vim.env.GRIP_DB_STDIN_FILE,
  env = vim.env.GRIP_DB_ENV_FILE,
}
vim.env.PATH = dir .. ":" .. (old.path or "")

local cases = {
  {
    name = "postgresql", mod = pg,
    url = "postgresql://argv_user:pg_password_secret@db.internal:55432/analytics?sslmode=require",
    password = "pg_password_secret", schema_token = "information_schema",
    env_token = "host=db.internal",
  },
  {
    name = "mysql", mod = mysql,
    url = "mysql://argv_user:mysql_password_secret@db.internal:33306/analytics",
    password = "mysql_password_secret", schema_token = "information_schema",
    env_token = "MYSQL_PWD=mysql_password_secret",
  },
  {
    name = "sqlite", mod = sqlite,
    url = "sqlite:" .. dir .. "/argv-fixture.sqlite",
    password = nil, schema_token = "sqlite_master", env_token = nil,
  },
  {
    name = "sqlserver", mod = sqlserver,
    url = "sqlserver://argv_user:sqlserver_password_secret@db.internal:14330/analytics?encrypt=optional",
    password = "sqlserver_password_secret", schema_token = "INFORMATION_SCHEMA",
    env_token = "SQLCMDPASSWORD=sqlserver_password_secret",
  },
}

local function inspect(case, label, call, expected_stdin)
  local prefix = dir .. "/" .. case.name .. "-" .. label
  local cmdline_file = prefix .. ".cmdline"
  local stdin_file = prefix .. ".stdin"
  local env_file = prefix .. ".env"
  vim.env.GRIP_DB_CMDLINE_FILE = cmdline_file
  vim.env.GRIP_DB_STDIN_FILE = stdin_file
  vim.env.GRIP_DB_ENV_FILE = env_file

  call()
  local cmdline = table.concat(vim.fn.readfile(cmdline_file), " ")
  local stdin = table.concat(vim.fn.readfile(stdin_file), "\n")
  local env = table.concat(vim.fn.readfile(env_file), "\n")

  for _, forbidden in ipairs({ case.url, case.password, expected_stdin, "SELECT", "UPDATE", case.schema_token }) do
    if forbidden and forbidden ~= "" then
      assert(not cmdline:find(forbidden, 1, true),
        string.format("%s %s argv exposed %q: %s", case.name, label, forbidden, cmdline))
    end
  end
  assert(stdin:find(expected_stdin, 1, true),
    string.format("%s %s stdin missing %q: %s", case.name, label, expected_stdin, stdin))
  if case.env_token then
    assert(env:find(case.env_token, 1, true), case.name .. " environment missing credential channel: " .. env)
  end
  if case.name == "postgresql" then
    assert(env:find("port=55432", 1, true) and env:find("dbname=analytics", 1, true)
      and env:find("user=argv_user", 1, true) and env:find("sslmode=require", 1, true),
      "PostgreSQL service file did not preserve the URI: " .. env)
  end
  return stdin
end

local ok, err = xpcall(function()
  for _, case in ipairs(cases) do
    local query_secret = "query_value_secret_" .. case.name
    inspect(case, "query", function()
      case.mod.query("SELECT '" .. query_secret .. "'", case.url)
    end, query_secret)

    inspect(case, "schema", function()
      case.mod.get_schema_batch(case.url)
    end, case.schema_token)

    local mutation_secret = "mutation_value_secret_" .. case.name
    local stdin = inspect(case, "execute", function()
      case.mod.execute("UPDATE private_table SET value='" .. mutation_secret .. "'", case.url)
    end, mutation_secret)
    if case.name == "mysql" then
      assert(stdin:find("ANSI_QUOTES", 1, true), "MySQL sql_mode missing from stdin")
    elseif case.name == "sqlserver" then
      assert(stdin:find("SET QUOTED_IDENTIFIER ON", 1, true), "SQL Server session setup missing from stdin")
      assert(not stdin:find("SET NOCOUNT ON", 1, true), "SQL Server execute must preserve row-count output")
    end
  end
end, debug.traceback)

vim.env.PATH = old.path
vim.env.GRIP_DB_CMDLINE_FILE = old.cmdline
vim.env.GRIP_DB_STDIN_FILE = old.stdin
vim.env.GRIP_DB_ENV_FILE = old.env
vim.fn.delete(dir, "rf")

if not ok then error(err, 0) end
print("adapter_argv_spec: 12 passed, 0 failed")
