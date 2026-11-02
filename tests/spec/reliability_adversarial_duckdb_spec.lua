-- Actual native DuckDB children. A test seam leaves one real CLI's stdin open
-- after its query emits data, so its file lock remains held until signalled.
-- No database error/exit is fabricated; every child is reaped before cleanup.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local db, connections = require('dadbod-grip.db'), require('dadbod-grip.connections')
local function held_schema(c, body)
  c.url = 'duckdb:' .. c.root .. '/case.duckdb'
  local seed = vim.system({ 'duckdb', c.root .. '/case.duckdb', '-c',
    "CREATE TABLE t(id INTEGER PRIMARY KEY,payload VARCHAR); INSERT INTO t VALUES(1,'before')" }, { text = true }):wait()
  assert(seed.code == 0, seed.stderr)
  local original, child, out, reaped = vim.system, nil, '', false
  local calls, schema_calls, schema_result, events = 0, 0, nil, {}
  vim.system = function(argv, opts, callback)
    if argv[1] == 'duckdb' and type(opts.stdin) == 'string' then
      calls = calls + 1
      events[#events + 1] = 'spawn-' .. calls
      if not child then
        local stream = vim.tbl_extend('force', {}, opts, { stdin = true,
          stdout = function(_, chunk) if chunk then out = out .. chunk end end })
        child = original(argv, stream, function(result)
          reaped = true; events[#events + 1] = 'held-reaped'
          result.stdout = out; callback(result)
        end)
        child:write(opts.stdin .. ";\n")
        return child
      end
    end
    return original(argv, opts, callback)
  end
  db.get_schema_batch_async(c.url, function(schema)
    schema_calls = schema_calls + 1; schema_result = schema
  end)
  local ok, err = xpcall(function()
    assert(vim.wait(5000, function() return #out > 0 or reaped end, 1), 'held native schema did not emit')
    assert(not reaped and child, 'native schema must still own its file lock')
    body({ release = function() if child and not reaped then child:write(nil) end end,
      reaped = function() return reaped end, events = events })
  end, debug.traceback)
  if child and not reaped then pcall(child.write, child, nil) end
  if not vim.wait(5000, function() return reaped and schema_calls > 0 end, 1) then
    if child then pcall(child.kill, child, 9) end
    vim.wait(2000, function() return reaped end, 1)
  end
  vim.system = original
  assert(ok, err)
  assert(reaped, 'held native child was not reaped')
  H.eq(schema_calls, 1, 'schema callback exactly once')
  assert(schema_result and schema_result.t, 'held schema query must actually complete successfully')
  return events, calls
end
H.test('D01 same-file foreground write waits for real schema child reaping, executes once', function(c)
  local result, failure
  local events, calls = held_schema(c, function(h)
    vim.defer_fn(h.release, 100)
    result, failure = db.execute("UPDATE t SET payload='after' WHERE id=1", c.url)
  end)
  assert(result, failure)
  H.eq(c.scalar('SELECT payload FROM t WHERE id=1'), 'after')
  H.eq(calls, 2, 'one schema process and one original write, no retry')
  H.eq(events, { 'spawn-1', 'held-reaped', 'spawn-2' }, 'next process cannot spawn before actual exit')
end)
H.test('D02 canonical alias to the same file shares coordination', function(c)
  local result, failure
  local events = held_schema(c, function(h)
    vim.defer_fn(h.release, 100)
    result, failure = db.execute("UPDATE t SET payload='alias' WHERE id=1", 'duckdb:' .. c.root .. '/./case.duckdb')
  end)
  assert(result, failure)
  H.eq(c.scalar('SELECT payload FROM t WHERE id=1'), 'alias')
  H.eq(events, { 'spawn-1', 'held-reaped', 'spawn-2' })
end)
H.test('D03 a different physical database progresses while first file remains locked', function(c)
  local result, failure, first_still_owned
  local second = c.root .. '/other.duckdb'
  local seeded = vim.system({ 'duckdb', second, '-c', 'CREATE TABLE other(id INTEGER)' }, { text = true }):wait()
  assert(seeded.code == 0, seeded.stderr)
  held_schema(c, function(h)
    vim.defer_fn(h.release, 1500) -- bounded cleanup if an incorrect global queue blocks
    result, failure = db.execute('INSERT INTO other VALUES(7)', 'duckdb:' .. second)
    first_still_owned = not h.reaped()
    h.release()
  end)
  assert(result, failure)
  assert(first_still_owned, 'unrelated file was unnecessarily blocked until the first file exited')
end)
H.test('D04 queued metadata retains readonly mode captured at submission', function(c)
  local second_result, second_calls, seen_ro = nil, 0, false
  local events = held_schema(c, function(h)
    local original_mode, original_system = connections.current_mode, vim.system
    connections.current_mode = function(url)
      if url == c.url then return 'ro' end
      return original_mode(url)
    end
    vim.system = function(argv, opts, callback)
      if argv[1] == 'duckdb' then
        seen_ro = vim.tbl_contains(argv, '-readonly')
      end
      return original_system(argv, opts, callback)
    end
    db.get_schema_batch_async(c.url, function(schema) second_calls = second_calls + 1; second_result = schema end)
    connections.current_mode = original_mode
    h.release()
    assert(vim.wait(5000, function() return second_calls > 0 end, 1), 'queued metadata callback missing')
    vim.system = original_system
  end)
  H.eq(second_calls, 1)
  H.eq(events, { 'spawn-1', 'held-reaped', 'spawn-2' }, 'queued RO metadata cannot overlap its predecessor')
  assert(second_result and second_result.t, 'queued read-only schema did not succeed')
  assert(seen_ro, 'deferred spawn lost the submitted connection read-only flag')
end)
H.test('D05 completed async callback may synchronously query the same database', function(c)
  c.url = 'duckdb:' .. c.root .. '/callback.duckdb'
  c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES(1)')
  local done, got, failure, callbacks = false, nil, nil, 0
  db.get_schema_batch_async(c.url, function(schema)
    callbacks = callbacks + 1
    if schema then got, failure = db.query('SELECT id FROM t', c.url) end
    done = true
  end)
  assert(vim.wait(5000, function() return done end, 1), 'callback reentrancy deadlock')
  H.eq(callbacks, 1)
  assert(got, failure)
  H.eq(got.rows, { { '1' } })
end)
H.finish('reliability_adversarial_duckdb_spec')
