-- duckdb_argv_spec.lua: SQL and attachment secrets must never enter argv.
dofile("tests/minimal_init.lua")

local duckdb = require("dadbod-grip.adapters.duckdb")

local dir = vim.fn.tempname() .. "_duckdb_argv"
local executable = dir .. "/duckdb"
local pid_file = dir .. "/pid"
local stdin_file = dir .. "/stdin"
local ready_file = dir .. "/ready"
local release_file = dir .. "/release"
local url = "duckdb::memory:"
local password = "argv_secret_hunter2_7f3c"
local dsn = "postgres:dbname=analytics host=db.internal user=reporter password=" .. password

vim.fn.mkdir(dir, "p")
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s' \"$$\" > \"$GRIP_DUCKDB_PID_FILE\"",
  "cat > \"$GRIP_DUCKDB_STDIN_FILE\"",
  ": > \"$GRIP_DUCKDB_READY_FILE\"",
  "while [ ! -f \"$GRIP_DUCKDB_RELEASE_FILE\" ]; do sleep 0.02; done",
  "printf 'rtype,database_name,schema_name,table_name,column_name,data_type,is_nullable,column_index\\n'",
}, executable)
assert(vim.fn.setfperm(executable, "rwx------") == 1, "could not create fake DuckDB")

local old = {
  path = vim.env.PATH,
  pid = vim.env.GRIP_DUCKDB_PID_FILE,
  stdin = vim.env.GRIP_DUCKDB_STDIN_FILE,
  ready = vim.env.GRIP_DUCKDB_READY_FILE,
  release = vim.env.GRIP_DUCKDB_RELEASE_FILE,
}
vim.env.PATH = dir .. ":" .. (old.path or "")
vim.env.GRIP_DUCKDB_PID_FILE = pid_file
vim.env.GRIP_DUCKDB_STDIN_FILE = stdin_file
vim.env.GRIP_DUCKDB_READY_FILE = ready_file
vim.env.GRIP_DUCKDB_RELEASE_FILE = release_file

local done = false
local ok, err = xpcall(function()
  duckdb._attach_unchecked(url, dsn, "reporting")
  duckdb.get_schema_batch_async(url, function() done = true end)

  assert(vim.wait(3000, function() return vim.fn.filereadable(ready_file) == 1 end, 1),
    "fake DuckDB did not reach its process-inspection barrier")
  local pid = assert(vim.fn.readfile(pid_file)[1], "fake DuckDB did not record its pid")
  local cmdline_file = assert(io.open("/proc/" .. pid .. "/cmdline", "rb"))
  local cmdline = cmdline_file:read("*a")
  cmdline_file:close()

  for _, forbidden in ipairs({
    "SELECT", "ATTACH", "CREATE SECRET", "postgres:", "db.internal",
    "analytics", password, dsn,
  }) do
    assert(not cmdline:find(forbidden, 1, true),
      string.format("DuckDB argv exposed %q: %s", forbidden, cmdline:gsub("%z", " ")))
  end

  local stdin = table.concat(vim.fn.readfile(stdin_file), "\n")
  assert(stdin:find("CREATE SECRET", 1, true), "credential secret was not sent on stdin")
  assert(stdin:find(password, 1, true), "stdin did not receive the credential")
  assert(stdin:find("ATTACH IF NOT EXISTS", 1, true), "attachment was not sent on stdin")
  assert(stdin:find("duckdb_columns", 1, true), "schema query was not sent on stdin")

  vim.fn.writefile({ "release" }, release_file)
  assert(vim.wait(3000, function() return done end, 1), "async DuckDB callback never fired")
end, debug.traceback)

-- Always release and reap the fake process before restoring PATH/removing files.
if vim.fn.filereadable(release_file) == 0 then vim.fn.writefile({ "release" }, release_file) end
vim.wait(3000, function() return done end, 1)
duckdb.detach(url, "reporting")
vim.env.PATH = old.path
vim.env.GRIP_DUCKDB_PID_FILE = old.pid
vim.env.GRIP_DUCKDB_STDIN_FILE = old.stdin
vim.env.GRIP_DUCKDB_READY_FILE = old.ready
vim.env.GRIP_DUCKDB_RELEASE_FILE = old.release
vim.fn.delete(dir, "rf")

if not ok then error(err, 0) end
print("duckdb_argv_spec: 1 passed, 0 failed")
