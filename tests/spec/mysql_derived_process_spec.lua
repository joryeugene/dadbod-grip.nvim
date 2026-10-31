local read, adapters = require("dadbod-grip.mysql_read"), require("dadbod-grip.adapters")
local pass, fail = 0, 0
local function eq(a, b) assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a)) end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function file(path) return table.concat(vim.fn.readfile(path, "b"), "\n") end
local function run(mode, opts)
  opts = opts or {}
  local root = vim.fn.tempname(); vim.fn.mkdir(root, "p", "0700")
  local calls, fallback, system, legacy = 0, 0, vim.system, adapters.run_cmd
  vim.system = function(...) calls = calls + 1; return system(...) end
  adapters.run_cmd = function() fallback = fallback + 1; error("no legacy fallback after a typed error") end
  local pending = opts.interrupt
  if pending then
    local function cancel()
      if not pending then return end
      if vim.uv.fs_stat(root .. "/ready") then vim.api.nvim_input("\003") else vim.defer_fn(cancel, 5) end
    end
    vim.defer_fn(cancel, 5)
  end
  local config = { args = { "/usr/bin/python3", "tests/fixtures/mysql_derived_client.py", root, mode },
    setup = "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\n", env = { MYSQL_PWD = "synthetic-derived-password" },
    timeout = opts.timeout or 2000 }
  local sql = opts.sql or "SELECT 'DERIVED_ORIGINAL_SECRET' AS value"
  local ok, result, err = pcall(read.derived_query, sql, config)
  pending, vim.system, adapters.run_cmd = false, system, legacy
  assert(ok, result); eq(calls, 1); eq(fallback, 0)
  local input, argv, pid = file(root .. "/stdin"), file(root .. "/argv.json"), file(root .. "/pid")
  eq(vim.uv.fs_stat("/proc/" .. pid), nil)
  assert(not argv:find("DERIVED_ORIGINAL_SECRET", 1, true)); assert(not argv:find("synthetic-derived-password", 1, true))
  eq(file(root .. "/password"), "synthetic-derived-password")
  assert(argv:find("--skip-reconnect", 1, true) and argv:find("--skip-force", 1, true))
  vim.fn.delete(root, "rf")
  return result, err, input
end
test("one private native SELECT decodes chunked unknown bytes without preflight", function()
  local result, err, input = run("normal")
  assert(result, err); eq(result.rows[1][1], "\0\255A"); eq(result.cell_types[1][1], "raw_unknown")
  eq(result.byte_exact, true); eq(result.readonly, true); eq(result.lossless, false)
  assert(not input:find("CREATE", 1, true)); assert(not input:find("SHOW FULL", 1, true))
  assert(not input:find("_BEGIN", 1, true), input)
  local _, count = input:gsub("DERIVED_ORIGINAL_SECRET", ""); eq(count, 1)
end)
test("original-read denial preserves error and never retries", function()
  local result, err, input = run("original-deny")
  eq(result, nil); assert(err:find("1142", 1, true), err)
  local _, count = input:gsub("DERIVED_ORIGINAL_SECRET", ""); eq(count, 1)
end)
test("owned TERM-resistant process is killed/reaped on timeout after original", function()
  local result, err = run("hang", { timeout = 150 })
  eq(result, nil); assert(err:find("outcome unknown", 1, true), err)
end)
test("owned process is killed/reaped after actual Ctrl-C", function()
  local result, err = run("hang", { interrupt = true })
  eq(result, nil); assert(err:find("interrupted", 1, true) and err:find("outcome unknown", 1, true), err)
end)
for _, mode in ipairs({ "warning", "malformed" }) do
  test("unsafe " .. mode .. " result is withheld without retry", function()
    local result, err, input = run(mode)
    eq(result, nil); assert(type(err) == "string" and err ~= "")
    local _, count = input:gsub("DERIVED_ORIGINAL_SECRET", ""); eq(count, 1)
  end)
end
test("legacy read route is chosen before any typed/source attempt and retains native headers", function()
  local run_cmd, system = adapters.run_cmd, vim.system
  local calls, spawned, captured = 0, 0, nil
  local sql = "WITH c AS (SELECT 1 AS id) SELECT COUNT(*),COUNT(*) FROM c; -- literal SQL"
  adapters.run_cmd = function(args, _, opts)
    calls, captured = calls + 1, opts.stdin
    assert(vim.tbl_contains(args, "--xml") and vim.tbl_contains(args, "--skip-reconnect"))
    return '<resultset><row><field name="COUNT(*)">1</field><field name="COUNT(*)">1</field></row></resultset>', "", 0
  end
  vim.system = function() spawned = spawned + 1; error("legacy must not attempt a typed process") end
  local ok, result, err = pcall(read.derived_query, sql, { args = { "mysql" }, setup = "SET existing_setup;\n",
    timeout = 1000, bind_source = function() error("legacy must not bind source metadata") end })
  adapters.run_cmd, vim.system = run_cmd, system
  assert(ok, result); assert(result, err); eq(calls, 1); eq(spawned, 0)
  eq(captured, "SET existing_setup;\n" .. sql)
  eq(result.columns, { "COUNT(*)", "COUNT(*)" }); eq(result.rows, { { "1", "1" } })
  eq(result.cell_types[1], { "raw_unknown", "raw_unknown" })
  eq(result.source_columns, { false, false }); eq(result.readonly, true); eq(result.lossless, false)
  eq(result.byte_exact, false); eq(result.column_info[1].restorable, false)
end)
test("configured RO rejects potentially mutating custom batches before any process", function()
  local system, legacy = vim.system, adapters.run_cmd
  local calls = 0
  vim.system = function() calls = calls + 1; error("RO custom must not spawn") end
  adapters.run_cmd = function() calls = calls + 1; error("RO custom must not spawn") end
  for _, sql in ipairs({ "SET SESSION TRANSACTION READ WRITE; SELECT 1", "CALL task_proc()", "CREATE TABLE t(id INT)", "UPDATE t SET id=1" }) do
    local ok, result, err = pcall(read.derived_query, sql, { args = { "mysql" }, env = {}, setup = "", timeout = 1000, readonly = true })
    assert(ok, result); eq(result, nil); assert(tostring(err):lower():find("read.only"), tostring(err))
  end
  vim.system, adapters.run_cmd = system, legacy
  eq(calls, 0)
end)
print(string.format("mysql_derived_process_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
