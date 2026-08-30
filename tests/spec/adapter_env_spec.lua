-- adapter_env_spec.lua -- run_cmd/run_cmd_async accept an opts.env table that
-- is merged into the child process's inherited environment. Later tasks use
-- this to pass PGPASSWORD/MYSQL_PWD/PGOPTIONS without putting secrets on the
-- command line where they would be visible via `ps`.
local adapters = require("dadbod-grip.adapters")

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

test("configured_timeout reads the public setup option", function()
  local grip = require("dadbod-grip")
  grip.setup({ timeout = 4321 })
  eq(adapters.configured_timeout(9999), 4321, "configured timeout")
  grip.setup({})
end)

test("run_cmd passes env to the child process", function()
  local out = adapters.run_cmd({ "sh", "-c", "printf %s \"$GRIP_TEST_VAR\"" }, 5000,
    { env = { GRIP_TEST_VAR = "sentinel-value" } })
  eq(out, "sentinel-value", "child sees the injected variable")
end)

test("run_cmd env merges with the inherited environment", function()
  local out = adapters.run_cmd({ "sh", "-c", "printf %s \"$HOME|$GRIP_TEST_VAR\"" }, 5000,
    { env = { GRIP_TEST_VAR = "x" } })
  assert(out:match("^/"), "HOME survived the injection, got: " .. out)
  assert(out:match("|x$"), "injected var present, got: " .. out)
end)

test("run_cmd without env still works", function()
  local out = adapters.run_cmd({ "sh", "-c", "printf ok" }, 5000)
  eq(out, "ok", "no-opts call unchanged")
end)

test("run_cmd_async passes env to the child process", function()
  local out, done
  adapters.run_cmd_async({ "sh", "-c", "printf %s \"$GRIP_TEST_VAR\"" }, 5000, function(stdout)
    out = stdout
    done = true
  end, { env = { GRIP_TEST_VAR = "async-sentinel" } })
  vim.wait(5000, function() return done end, 1)
  eq(out, "async-sentinel", "async child sees the injected variable")
end)

test("run_cmd_async without opts still works", function()
  local out, done
  adapters.run_cmd_async({ "sh", "-c", "printf ok" }, 5000, function(stdout)
    out = stdout
    done = true
  end)
  vim.wait(5000, function() return done end, 1)
  eq(out, "ok", "no-opts call unchanged")
end)

test("psql argv carries no password", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local args = pg._psql_args("postgresql://u:hunter2@h:5432/db", "select 1")
  for _, a in ipairs(args) do
    assert(not tostring(a):find("hunter2", 1, true),
      "password found in argv element: " .. tostring(a))
  end
end)

test("psql password goes to PGPASSWORD, percent-decoded", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local env = pg._psql_env("postgresql://u:pa%25ss%40word@h:5432/db")
  eq(env.PGPASSWORD, "pa%ss@word", "decoded exactly once")
end)

test("no password means no PGPASSWORD", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local env = pg._psql_env("postgresql://u@h:5432/db")
  eq(env.PGPASSWORD, nil, "absent rather than empty")
end)

test("mysql argv carries no password", function()
  local my = require("dadbod-grip.adapters.mysql")
  local args = my._mysql_args({ host = "h", port = "3306", user = "u",
                                pass = "hunter2", dbname = "db" }, "select 1")
  for _, a in ipairs(args) do
    assert(not tostring(a):find("hunter2", 1, true), "password in argv: " .. tostring(a))
  end
end)

test("mysql password is NOT percent-decoded", function()
  local my = require("dadbod-grip.adapters.mysql")
  local env = my._mysql_env({ pass = "pa%25ss" })
  eq(env.MYSQL_PWD, "pa%25ss", "verbatim, matching sql.lua's no-decode contract")
end)

test("sqlcmd argv carries no password", function()
  local ms = require("dadbod-grip.adapters.sqlserver")
  local args = ms._sqlcmd_args({ host = "h", user = "u", pass = "hunter2", dbname = "db" },
                               "select 1")
  for _, a in ipairs(args) do
    assert(not tostring(a):find("hunter2", 1, true), "password in argv: " .. tostring(a))
  end
end)

print(string.format("\nadapter_env_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
