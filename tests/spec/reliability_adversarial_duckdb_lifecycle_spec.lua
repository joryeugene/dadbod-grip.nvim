-- Additive actual-child lifecycle tests. Watchdog/interrupt seams are MODELLED;
-- native DuckDB lock ownership, original SQL execution and reaping are real.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local db, grip, adapters = require('dadbod-grip.db'), require('dadbod-grip'), require('dadbod-grip.adapters')
local function run_held(c, watchdog, body)
  c.url = 'duckdb:' .. c.root .. '/held.duckdb'
  local result = vim.system({ 'duckdb', c.root .. '/held.duckdb', '-c',
    "CREATE TABLE t(id INTEGER PRIMARY KEY,payload VARCHAR); INSERT INTO t VALUES(1,'before')" }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  local real_system, old_grace, real_wait = vim.system, adapters._exit_grace_ms, vim.wait
  local child, out, reaped, delivered, events = nil, '', false, 0, {}
  if watchdog then
    grip.setup({ discovery = false, open_sidebar = false, timeout = 30 })
    adapters._exit_grace_ms = 20
  end
  vim.system = function(argv, opts, callback)
    if argv[1] ~= 'duckdb' or type(opts.stdin) ~= 'string' then return real_system(argv, opts, callback) end
    events[#events + 1] = 'spawn'
    if child then return real_system(argv, opts, callback) end
    local stream = vim.tbl_extend('force', {}, opts, { stdin = true,
      stdout = function(_, chunk) if chunk then out = out .. chunk end end })
    -- Deliberately keep the real holder alive past the adapter watchdog. This
    -- models late completion without claiming a native DuckDB timeout failure.
    if watchdog then stream.timeout = 10000 end
    child = real_system(argv, stream, function(r)
      reaped = true; events[#events + 1] = 'reaped'; r.stdout = out; callback(r)
    end)
    child:write(opts.stdin .. ';\n')
    return child
  end
  db.get_schema_batch_async(c.url, function() delivered = delivered + 1 end)
  local ok, err = xpcall(function()
    assert(real_wait(3000, function() return #out > 0 or reaped end, 1), 'native holder never emitted')
    assert(not reaped, 'holder must own its lock')
    body({ release = function() if not reaped then child:write(nil) end end,
      reaped = function() return reaped end, delivered = function() return delivered end,
      real_wait = real_wait })
  end, debug.traceback)
  vim.wait = real_wait
  if child and not reaped then pcall(child.write, child, nil) end
  if not real_wait(5000, function() return reaped and delivered > 0 end, 1) then
    if child then pcall(child.kill, child, 9) end
    real_wait(1000, function() return reaped end, 1)
  end
  real_wait(50, function() return false end, 1)
  vim.system, adapters._exit_grace_ms = real_system, old_grace
  assert(ok, err)
  assert(reaped, 'actual holder child was not reaped')
  H.eq(delivered, 1, 'watchdog and exit must not double-deliver')
  return events
end
H.test('D06 early watchdog delivery cannot release a still-live native database holder', function(c)
  local result, err
  local events = run_held(c, true, function(h)
    assert(h.real_wait(1000, function() return h.delivered() > 0 end, 1), 'watchdog did not deliver')
    assert(not h.reaped(), 'test requires a genuinely live child after watchdog delivery')
    grip.setup({ discovery = false, open_sidebar = false, timeout = 5000 })
    vim.defer_fn(h.release, 100)
    result, err = db.execute("UPDATE t SET payload='after' WHERE id=1", c.url)
  end)
  assert(result, err)
  H.eq(events, { 'spawn', 'reaped', 'spawn' }, 'lease lasts until actual exit, not early delivery')
  H.eq(c.scalar('SELECT payload FROM t WHERE id=1'), 'after')
end)
H.test('D07 interrupted queued foreground operation never spawns later or writes', function(c)
  local result, err, interrupted = nil, nil, false
  local events = run_held(c, false, function(h)
    vim.wait = function()
      interrupted = true
      return false, -2 -- controlled Neovim Ctrl-C result before queued admission
    end
    result, err = db.execute("UPDATE t SET payload='cancelled' WHERE id=1", c.url)
    vim.wait = h.real_wait
    h.release()
  end)
  assert(interrupted, 'queued synchronous operation never waited for ownership')
  assert(not result and type(err) == 'string', 'interrupted operation must report refusal')
  H.eq(events, { 'spawn', 'reaped' }, 'cancelled queued original must never spawn')
  H.eq(c.scalar('SELECT payload FROM t WHERE id=1'), 'before')
end)
H.finish('reliability_adversarial_duckdb_lifecycle_spec')
