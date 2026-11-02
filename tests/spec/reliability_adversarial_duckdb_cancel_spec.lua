-- New internal adapter handle control: real native cancellation and exit,
-- not a fabricated SIGTERM/network failure or a pre-start Ctrl-C model.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local db, duck = require('dadbod-grip.db'), require('dadbod-grip.adapters.duckdb')
H.test('D10 post-start cancellation retains lease until actual native child reaping', function(c)
  c.url = 'duckdb:' .. c.root .. '/cancel.duckdb'
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload VARCHAR); INSERT INTO t VALUES(1,'before')")
  local original, child, out, reaped, events, callbacks = vim.system, nil, '', false, {}, 0
  local warm_result, write_result, write_err
  vim.system = function(argv, opts, callback)
    if argv[1] == 'duckdb' and type(opts.stdin) == 'string' then
      events[#events + 1] = 'spawn'
      if not child then
        local stream = vim.tbl_extend('force', {}, opts, { stdin = true,
          stdout = function(_, chunk) if chunk then out = out .. chunk end end })
        child = original(argv, stream, function(result)
          reaped = true; events[#events + 1] = 'reaped'; result.stdout = out; callback(result)
        end)
        child:write(opts.stdin .. ';\n')
        return child
      end
    end
    return original(argv, opts, callback)
  end
  local ok, err = xpcall(function()
    local handle = duck.get_schema_batch_async(c.url, function(schema)
      callbacks = callbacks + 1; warm_result = schema
    end)
    assert(vim.wait(3000, function() return #out > 0 or reaped end, 1), 'native holder never emitted')
    assert(not reaped, 'cancellation must follow actual spawn and precede actual exit')
    assert(handle and type(handle.cancel) == 'function', 'internal adapter cancellation handle required')
    assert(handle.cancel(), 'first post-start cancellation was refused')
    write_result, write_err = db.execute("UPDATE t SET payload='after' WHERE id=1", c.url)
    assert(vim.wait(5000, function() return callbacks > 0 and reaped end, 1), 'cancelled native child did not finish')
  end, debug.traceback)
  if child and not reaped then pcall(child.kill, child, 9) end
  vim.wait(2000, function() return reaped end, 1)
  vim.system = original
  assert(ok, err)
  assert(reaped, 'cancelled child not reaped')
  assert(write_result, write_err)
  H.eq(callbacks, 1); H.eq(warm_result, nil)
  H.eq(events, { 'spawn', 'reaped', 'spawn' }, 'no next process before real cancellation exit')
  H.eq(c.scalar('SELECT payload FROM t WHERE id=1'), 'after')
end)
H.finish('reliability_adversarial_duckdb_cancel_spec')
