-- Same-run DuckDB profiler collection; every SQL string here is synthetic.
dofile("tests/minimal_init.lua")
local db = require("dadbod-grip.db")
local adapter = require("dadbod-grip.adapters.duckdb")
local adapters = require("dadbod-grip.adapters")
local grip = require("dadbod-grip")
local timing = require("dadbod-grip.engine_timing")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a)) end
local function mock_run(fn, check, probe_capability)
  local original, options, executable = adapters.run_cmd, timing.options, vim.fn.executable
  local calls, paths = 0, {}
  -- Collection cases supply their capability explicitly; only capability cases
  -- exercise the metadata probe. Neither boundary may spawn an installed CLI.
  if not probe_capability then
    timing.options = function(opts)
      if type(opts) == "table" and opts.engine_timing == true then return opts end
    end
  end
  vim.fn.executable = function(name) return name == "duckdb" and 1 or executable(name) end
  adapters.run_cmd = function(args, timeout, opts)
    calls = calls + 1
    local raw = opts.stdin:match("SET profiling_output = (.-);\n")
    local path = raw and raw:sub(2, -2):gsub("''", "'")
    if path then
      paths[#paths + 1] = path
      eq(vim.fn.getfperm(vim.fn.fnamemodify(path, ":h")), "rwx------")
    end
    local sql = opts.stdin:match("SET profiling_coverage = 'ALL';\n(.*)")
    return fn(path, sql, opts.stdin, args, timeout)
  end
  local ok, err = xpcall(function() check(function() return calls end) end, debug.traceback)
  adapters.run_cmd, timing.options, vim.fn.executable = original, options, executable
  for _, path in ipairs(paths) do
    eq(vim.fn.filereadable(path), 0)
    eq(vim.fn.isdirectory(vim.fn.fnamemodify(path, ":h")), 0)
  end
  if not ok then error(err, 0) end
end
local function csv() return "value\nV42\n", "", 0 end

test("collection fixtures restore process and capability boundaries after failure", function()
  local run, options, executable = adapters.run_cmd, timing.options, vim.fn.executable
  local ok, err = pcall(function()
    mock_run(function() error("synthetic fixture failure") end, function()
      adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
    end)
  end)
  eq(ok, false); assert(tostring(err):find("synthetic fixture failure", 1, true))
  eq(adapters.run_cmd, run); eq(timing.options, options)
  eq(vim.fn.executable, executable)
end)

test("collection defaults off, validates boolean and preserves explicit value", function()
  eq(grip.get_opts().engine_timing, false)
  grip.setup({ engine_timing = true })
  eq(grip.get_opts().engine_timing, true)
  grip.setup({})
  eq(grip.get_opts().engine_timing, true)
  eq(pcall(grip.setup, { engine_timing = "true" }), false)
  grip.setup({ engine_timing = false })
end)

test("default adapter calls do not enable or return profiling", function()
  mock_run(function(path, _, stdin)
    eq(path, nil); assert(not stdin:find("enable_profiling", 1, true)); return csv()
  end, function(calls)
    local result, err = adapter.query("SELECT 42 AS value", "duckdb::memory:")
    eq(err, nil); eq(result.rows[1][1], "42"); eq(result.engine_timing, nil); eq(calls(), 1)
  end)
end)
test("non-table additive options preserve existing facade and adapter calls", function()
  mock_run(function(path, _, _, args)
    eq(path, nil)
    if args[1] == "sqlite3" then return "value\nI3432\n", "", 0 end
    return csv()
  end, function()
    for _, opts in ipairs({ true, false, 42, "invalid", function() end }) do
      for _, fn in ipairs({ adapter.query, db.query }) do
        local result, err = fn("SELECT 42 AS value", "duckdb::memory:", opts)
        eq(err, nil); eq(result.rows[1][1], "42"); eq(result.engine_timing, nil)
      end
      local result, err = db.query("SELECT 42 AS value", "sqlite::memory:", opts)
      eq(err, nil); eq(result.rows[1][1], "42"); eq(result.engine_timing, nil)
    end
  end)
end)

test("valid profile matches wrapped payload, uses seconds and runs once", function()
  mock_run(function(path, sql)
    assert(path, "profiling was not enabled")
    assert(sql:find("_grip_json", 1, true), "nested-value conversion must remain")
    vim.fn.writefile({ vim.json.encode({ query_name = sql, latency = 0.012345 }) }, path)
    return csv()
  end, function(calls)
    local result, err = db.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
    eq(err, nil); eq(calls(), 1); eq(result.rows[1][1], "42")
    eq(result.engine_timing.status, "available"); eq(result.engine_timing.elapsed_ms, 12.345)
    eq(result.engine_timing.source, "duckdb_profile"); eq(result.engine_timing.scope, "statement")
  end)
end)

for name, content in pairs({
  malformed = "{broken", empty = "", missing_duration = '{"query_name":"MATCH"}',
  negative = '{"query_name":"MATCH","latency":-1}',
  string_duration = '{"query_name":"MATCH","latency":"0.1"}',
  nonfinite = '{"query_name":"MATCH","latency":1e999}', nan = '{"query_name":"MATCH","latency":NaN}',
  mismatch = '{"query_name":"SELECT 999","latency":0.1}', array = "[]",
}) do
  test(name .. " profile never fabricates a duration", function()
    mock_run(function(path, sql)
      assert(path, "profiling was not enabled")
      vim.fn.writefile({ (content:gsub('"MATCH"', function() return vim.json.encode(sql) end)) }, path)
      return csv()
    end, function(calls)
      local result, err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(err, nil); eq(calls(), 1); eq(result.engine_timing.status, "unavailable")
      eq(result.engine_timing.elapsed_ms, nil); assert(result.engine_timing.reason)
    end)
  end)
end

test("real zero is accepted only from a valid matching profile", function()
  mock_run(function(path, sql)
    vim.fn.writefile({ vim.json.encode({ query_name = sql, latency = 0 }) }, assert(path)); return csv()
  end, function(calls)
    local result, err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
    eq(err, nil); eq(calls(), 1); eq(result.engine_timing.status, "available")
    eq(result.engine_timing.elapsed_ms, 0)
  end)
end)

test("private directory failure keeps one successful execution and unavailable status", function()
  local temp = vim.fn.tempname
  vim.fn.tempname = function() return temp() .. "/nonexistent_parent/profile" end
  local ok, err = xpcall(function()
    mock_run(function(path) eq(path, nil); return csv() end, function(calls)
      local result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(query_err, nil); eq(calls(), 1); eq(result.engine_timing.status, "unavailable")
      eq(result.engine_timing.reason, "profile_setup_failed"); eq(result.engine_timing.elapsed_ms, nil)
    end)
  end, debug.traceback)
  vim.fn.tempname = temp
  assert(ok, err)
end)

test("wrapper incompatibility never retries the user statement after profile setup failure", function()
  local temp = vim.fn.tempname
  vim.fn.tempname = function() return temp() .. "/nonexistent_parent/profile" end
  local ok, err = xpcall(function()
    mock_run(function(path, _, stdin)
      eq(path, nil)
      if stdin:find("_grip_json", 1, true) then return "", "synthetic wrapper incompatibility", 1 end
      return "value\n42\n", "", 0
    end, function(calls)
      local result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(result, nil); eq(calls(), 1); eq(query_err, "synthetic wrapper incompatibility")
    end)
  end, debug.traceback)
  vim.fn.tempname = temp
  assert(ok, err)
end)

test("missing profile does not rerun successful SQL", function()
  mock_run(function(path) assert(path); return csv() end, function(calls)
    local result, err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
    eq(err, nil); eq(calls(), 1); eq(result.engine_timing.status, "unavailable")
    eq(result.engine_timing.reason, "profile_missing"); eq(result.engine_timing.elapsed_ms, nil)
  end)
end)

for _, code in ipairs({ 1, 124 }) do
  test("failed profiled query cleans up and never retries (exit " .. code .. ")", function()
    mock_run(function(path, sql)
      assert(path); vim.fn.writefile({ vim.json.encode({ query_name = sql, latency = 1 }) }, path)
      return "", "synthetic query failure", code
    end, function(calls)
      local result, err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(result, nil); assert(err:find("synthetic query failure", 1, true)); eq(calls(), 1)
    end)
  end)
end

test("Lua interruption cleans private profile artifact", function()
  mock_run(function(path) assert(path); vim.fn.writefile({ "synthetic" }, path); error("Keyboard interrupt") end,
    function(calls)
      local ok = pcall(adapter.query, "SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(ok, false); eq(calls(), 1)
    end)
end)

test("multiple statements preserve normal one-call execution with unsupported timing", function()
  mock_run(function(path, _, stdin)
    eq(path, nil); assert(stdin:find("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);", 1, true))
    return "2", "", 0
  end, function(calls)
    local result, err = adapter.execute("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);", "duckdb::memory:",
      { engine_timing = true })
    eq(err, nil); eq(calls(), 1); eq(result.engine_timing.status, "unsupported")
    eq(result.engine_timing.reason, "multiple_statements"); eq(result.engine_timing.elapsed_ms, nil)
  end)
end)

test("SQLite returns explicit unsupported timing without changing its result", function()
  local result, err = db.query("SELECT 42 AS value", "sqlite::memory:", { engine_timing = true })
  eq(err, nil); eq(result.rows[1][1], "42"); eq(result.engine_timing.status, "unsupported")
  eq(result.engine_timing.adapter, "sqlite"); eq(result.engine_timing.elapsed_ms, nil)
end)

for _, example in ipairs({ { "postgresql", "postgresql://synthetic" }, { "mysql", "mysql://synthetic" },
    { "mysql", "mariadb://synthetic" }, { "sqlserver", "sqlserver://synthetic" } }) do
  test(example[2] .. " reports unsupported without additional adapter calls", function()
    local other = assert(adapters.resolve(example[2]))
    for _, method in ipairs({ "query", "execute" }) do
      local original, calls = other[method], 0
      other[method] = function() calls = calls + 1; return { rows = { { "42" } }, affected = 1 } end
      local ok, err = xpcall(function()
        local result, query_err = db[method]("SELECT 42", example[2], { engine_timing = true })
        eq(query_err, nil); eq(calls, 1); eq(result.engine_timing.status, "unsupported")
        eq(result.engine_timing.adapter, example[1]); eq(result.engine_timing.elapsed_ms, nil)
      end, debug.traceback)
      other[method] = original
      assert(ok, err)
    end
  end)
end

test("missing DuckDB keeps the install diagnostic and never invokes a process", function()
  local executable, run = vim.fn.executable, adapters.run_cmd
  vim.fn.executable = function(name) return name == "duckdb" and 0 or executable(name) end
  adapters.run_cmd = function() error("missing executable must not be invoked") end
  local ok, err = xpcall(function()
    for _, method in ipairs({ "query", "execute" }) do
      local result, query_err = adapter[method]("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(result, nil); eq(query_err, "duckdb not found. Install duckdb.")
    end
  end, debug.traceback)
  vim.fn.executable, adapters.run_cmd = executable, run
  assert(ok, err)
end)

test("unresolvable profiling executable stays unavailable and preserves the ordinary query path", function()
  local exepath = vim.fn.exepath
  vim.fn.exepath = function(name) return name == "duckdb" and "" or exepath(name) end
  local ok, err = xpcall(function()
    mock_run(function(path, sql, _, args)
      if sql and sql:find("_grip_profile_capability", 1, true) then
        eq(args[1], ""); assert(path); return "", "synthetic executable not found", 127
      end
      eq(path, nil); eq(args[1], "duckdb"); return csv()
    end, function(calls)
      local result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(query_err, nil); eq(calls(), 2); eq(result.rows[1][1], "42")
      eq(result.engine_timing.status, "unavailable"); eq(result.engine_timing.elapsed_ms, nil)
      eq(result.engine_timing.reason, "profiling_capability_unavailable")
      result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(query_err, nil); eq(calls(), 3); eq(result.engine_timing.status, "unavailable")
    end, true)
  end, debug.traceback)
  vim.fn.exepath = exepath
  assert(ok, err)
end)

test("one cached metadata capability probe degrades unsupported clients before user SQL", function()
  local exepath = vim.fn.exepath
  vim.fn.exepath = function() return "synthetic-unsupported-client" end
  local ok, err = xpcall(function()
    mock_run(function(path, sql)
      if sql and sql:find("_grip_profile_capability", 1, true) then
        assert(path); return "", "unrecognized configuration parameter profiling_coverage", 1
      end
      eq(path, nil); return csv()
    end, function(calls)
      local result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(query_err, nil); eq(calls(), 2); eq(result.rows[1][1], "42")
      eq(result.engine_timing.status, "unsupported"); eq(result.engine_timing.elapsed_ms, nil)
      result, query_err = adapter.query("SELECT 42 AS value", "duckdb::memory:", { engine_timing = true })
      eq(query_err, nil); eq(calls(), 3); eq(result.engine_timing.status, "unsupported")
    end, true)
  end, debug.traceback)
  vim.fn.exepath = exepath
  assert(ok, err)
end)

print(string.format("engine_timing_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
