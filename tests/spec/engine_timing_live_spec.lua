-- Local disposable DuckDB only; no account, attachment, or external service.
dofile("tests/minimal_init.lua")
if vim.fn.executable("duckdb") ~= 1 then
  assert(vim.env.GRIP_REQUIRE_DUCKDB ~= "1", "DuckDB required but unavailable")
  print("engine_timing_live_spec: SKIPPED (duckdb not found)"); return
end
local adapter, adapters = require("dadbod-grip.adapters.duckdb"), require("dadbod-grip.adapters")
local grip = require("dadbod-grip")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local dir = vim.fn.tempname() .. "_engine_live"
vim.fn.mkdir(dir, "p")
local path = dir .. "/database quote's ; name.duckdb"
local url, enabled = "duckdb:" .. path, { engine_timing = true }
local seeded, seed_err = adapter.execute("CREATE TABLE counter(id INTEGER PRIMARY KEY); CREATE SEQUENCE exactly_once START 1;", url)
assert(seeded, seed_err)
local timing = require("dadbod-grip.engine_timing")
if timing.options then assert(timing.options(enabled)) end
local real_run, real_temp, real_system, real_delete = adapters.run_cmd, vim.fn.tempname, vim.system, vim.fn.delete
local calls, profiles, children, exited = 0, {}, {}, {}
vim.system = function(...)
  local args, opts, callback = ...
  local pid
  local child = real_system(args, opts, function(result)
    exited[pid] = true
    if callback then callback(result) end
  end)
  pid = child.pid
  children[#children + 1] = child.pid
  return child
end
vim.fn.delete = function(target, flags)
  if target:match("_grip_profile$") then
    assert(exited[children[#children]], "profile removed before its child exit callback")
  end
  return real_delete(target, flags)
end
adapters.run_cmd = function(args, timeout, opts)
  calls = calls + 1
  local raw = opts.stdin:match("SET profiling_output = (.-);\n")
  if raw then
    local profile = raw:sub(2, -2):gsub("''", "'")
    profiles[#profiles + 1] = profile
    assert(vim.fn.getfperm(vim.fn.fnamemodify(profile, ":h")) == "rwx------")
  end
  return real_run(args, timeout, opts)
end
-- Exercise SQL literal escaping for the temporary profiler path itself.
local serial = 0
vim.fn.tempname = function() serial = serial + 1; return dir .. "/profile quote's ; " .. serial end
local function check_cleanup()
  for _, profile in ipairs(profiles) do
    assert(vim.fn.filereadable(profile) == 0, "profile remains")
    assert(vim.fn.isdirectory(vim.fn.fnamemodify(profile, ":h")) == 0, "private profile directory remains")
  end
end
local function timed(method, sql, attempts)
  local before = calls
  local result, err = adapter[method](sql, url, enabled)
  assert(calls == before + (attempts or 1), "unexpected adapter invocation count")
  check_cleanup()
  return result, err
end
local function value(sql)
  local result, err = adapter.query(sql, url); assert(result, err); return result.rows[1][1]
end
test("real SELECT with sequence side effect executes once", function()
  local result, err = timed("query", "SELECT nextval('exactly_once') AS value;")
  assert(result, err); assert(result.rows[1][1] == "1")
  assert(result.engine_timing.status == "available", vim.inspect(result.engine_timing))
  assert(result.engine_timing.elapsed_ms >= 0)
  assert(value("SELECT nextval('exactly_once') AS value") == "2", "SELECT executed more than once")
end)
test("real INSERT executes once with original-run latency", function()
  local result, err = timed("execute", "INSERT INTO counter VALUES (1);")
  assert(result, err); assert(result.engine_timing.status == "available", vim.inspect(result.engine_timing))
  assert(value("SELECT count(*) FROM counter") == "1")
end)
test("real write failure cleans artifacts, preserves error and never retries", function()
  local result, err = timed("execute", "INSERT INTO counter VALUES (1);")
  assert(not result and err:find("Duplicate key", 1, true), err)
  assert(value("SELECT count(*) FROM counter") == "1")
end)
test("real multi-statement writes execute once with no invented batch total", function()
  local result, err = timed("execute", "INSERT INTO counter VALUES (2); INSERT INTO counter VALUES (3);")
  assert(result, err); assert(result.engine_timing.status == "unsupported")
  assert(result.engine_timing.elapsed_ms == nil)
  assert(value("SELECT count(*) FROM counter") == "3")
end)
test("real multi-statement SELECT preserves one original invocation", function()
  local result, err = timed("query", "SELECT 42 AS value; SELECT 43 AS other;", 1)
  assert(result, err); assert(result.engine_timing.status == "unsupported")
  assert(result.engine_timing.elapsed_ms == nil)
end)
test("bare CR ends line comments without dropping later batch statements", function()
  local result, err = timed("query", "SELECT 1 AS value; -- tail\rSELECT 2 AS other;", 1)
  assert(result, err); assert(result.rows[#result.rows][1] == "2", "second statement was dropped")
  assert(result.engine_timing.status == "unsupported")
end)
test("semicolons in literals, dollar quotes and comments stay single statement", function()
  for _, sql in ipairs({ "SELECT ';' AS value;", "SELECT $$;$$ AS value;",
      "/* ; /* ; */ */ SELECT ';' AS value;", "-- leading\rSELECT ';' AS value;" }) do
    local result, err = timed("query", sql)
    assert(result, err); assert(result.rows[1][1] == ";")
    assert(result.engine_timing.status == "available", vim.inspect(result.engine_timing))
  end
end)
test("ineligible syntax and quoted backslashes/dots preserve complete legacy values", function()
  for _, sql in ipairs({ "SELECT ['a\\'] AS value;", "SELECT ['a\n.b'] AS value;",
      "/* example\n.doc\n*/ SELECT ['a'] AS value;", "SELECT ['a'] AS value; -- trailing comment" }) do
    local plain, plain_err = adapter.query(sql, url); assert(plain, plain_err)
    local result, err = adapter.query(sql, url, enabled); assert(result, err)
    result.engine_timing = nil
    assert(vim.deep_equal(result, plain), "profiling eligibility changed values for synthetic literal/comment")
    check_cleanup()
  end
end)
test("real timeout cleans profile artifact without rerunning the query", function()
  grip.setup({ timeout = 20 })
  local result, err = timed("query", "SELECT sum(i) FROM range(100000000000) t(i)")
  grip.setup({ timeout = 10000 })
  assert(not result and err, "long query did not time out")
end)
test("real Ctrl-C wait interruption cleans artifact without rerunning", function()
  grip.setup({ timeout = 2000 })
  vim.defer_fn(function() vim.api.nvim_input("\003") end, 20)
  local result, err = timed("query", "SELECT sum(i) FROM range(100000000000) t(i)")
  assert(not result and err, "query was not interrupted")
  local child = children[#children]
  assert(child and vim.uv.kill(child, 0) == nil, "interrupted profile child is alive at return")
  assert(exited[child], "profile callback did not complete before return/cleanup")
  assert(err:find("interrupted", 1, true), "interruption outcome was lost: " .. err)
  check_cleanup()
  grip.setup({ timeout = 10000 })
end)

test("Ctrl-C during first-client capability probe never starts the requested INSERT", function()
  local bin = dir .. "/capability_bin"
  vim.fn.mkdir(bin, "p")
  local input, marker = dir .. "/capability_input", dir .. "/unexpected_user_sql"
  local client = assert(vim.fn.exepath("duckdb"))
  vim.fn.writefile({ "#!/bin/sh", "cat > " .. vim.fn.shellescape(input),
    "case \"$(cat " .. vim.fn.shellescape(input) .. ")\" in",
    "  *_grip_profile_capability*) exec sleep 2 ;;", "esac",
    "printf unexpected > " .. vim.fn.shellescape(marker),
    "exec " .. vim.fn.shellescape(client) .. " \"$@\" < " .. vim.fn.shellescape(input),
  }, bin .. "/duckdb")
  assert(vim.fn.setfperm(bin .. "/duckdb", "rwx------") == 1)
  local old_path = vim.env.PATH
  vim.env.PATH = bin .. ":" .. old_path
  grip.setup({ timeout = 2000 })
  local ok, err = xpcall(function()
    local before = calls
    vim.defer_fn(function() vim.api.nvim_input("\003") end, 30)
    local result, query_err = adapter.execute("INSERT INTO counter VALUES (99)", url, enabled)
    assert(not result and query_err:find("interrupted", 1, true), query_err)
    assert(calls == before + 1, "user SQL started after capability cancellation")
    assert(vim.fn.filereadable(marker) == 0, "user SQL reached the client")
    local child = children[#children]
    assert(exited[child] and vim.uv.kill(child, 0) == nil, "capability child not reaped")
    check_cleanup()
  end, debug.traceback)
  vim.env.PATH = old_path
  grip.setup({ timeout = 10000 })
  assert(ok, err)
  assert(value("SELECT count(*) FROM counter") == "3", "cancelled preflight changed target table")
end)

adapters.run_cmd, vim.fn.tempname, vim.system, vim.fn.delete = real_run, real_temp, real_system, real_delete
check_cleanup()
vim.fn.delete(dir, "rf")
print(string.format("engine_timing_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
