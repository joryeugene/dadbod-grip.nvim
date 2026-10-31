-- Real generated libpq service files and real native completion callbacks.
-- Four subprocess controls use a reviewer-owned substitute CLI, not a server.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local pg, grip = require("dadbod-grip.adapters.postgresql"), require("dadbod-grip")
local function completion_case(c, mode, url)
  local system, tempname = vim.system, vim.fn.tempname
  local path, exited, fast, calls = nil, false, false, 0
  vim.fn.tempname = function() return c.root .. "/connection-service" end
  if mode == "timeout" then grip.setup({ discovery = false, open_sidebar = false, timeout = 20 }) end
  vim.system = function(argv, opts, callback)
    if argv[1] ~= "psql" then return system(argv, opts, callback) end
    calls = calls + 1
    path = assert(opts.env.PGSERVICEFILE)
    H.eq(vim.fn.getfperm(path), "rw-------")
    if mode == "spawn-failure" then error("synthetic psql spawn failure") end
    local child_argv = argv
    if mode ~= "native" then
      local program = mode == "timeout" and "import time; time.sleep(10)"
        or mode == "server-error" and "import sys; sys.stderr.write('synthetic SQL rejection'); sys.exit(1)"
        or "print('value'); print('1')"
      child_argv = { "python3", "-c", program }
    end
    return system(child_argv, opts, function(result)
      exited, fast = true, vim.in_fast_event()
      callback(result)
    end)
  end
  local ok, result, err = pcall(pg.query, "SELECT 1 AS value", url or "postgresql://fixture:public-fixture@127.0.0.1/review")
  vim.system, vim.fn.tempname = system, tempname
  assert(ok, result)
  H.eq(calls, 1, "do not reconnect or retry for cleanup")
  assert(path, "no private service file captured")
  if mode == "success" or mode == "native" then assert(result, err) else assert(not result and err) end
  if mode ~= "spawn-failure" then assert(exited and fast, "fixture did not execute real fast-event completion") end
  assert(vim.wait(200, function() return not vim.uv.fs_stat(path) end, 1),
    "completed/spawn-failed connection service file remained")
end
for _, mode in ipairs({ "success", "server-error", "timeout", "spawn-failure" }) do
  H.test("P01 service cleanup after " .. mode, function(c) completion_case(c, mode) end)
end
if vim.env.GRIP_SAFETY_PG_URL then
  local parsed = assert(require("dadbod-grip.sql").parse_dadbod_url(vim.env.GRIP_SAFETY_PG_URL))
  assert(parsed.dbname == "grip_safety_review", "refuse unassigned native PostgreSQL fixture")
  H.test("P02 real psql service cleanup after assigned native read", function(c)
    completion_case(c, "native", vim.env.GRIP_SAFETY_PG_URL)
  end)
else
  print("P02 native PostgreSQL cleanup SKIP (assigned fixture unavailable)")
end
H.finish("safety_adversarial_service_cleanup_spec")
