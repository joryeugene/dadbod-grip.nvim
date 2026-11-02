-- Independent frozen cache-generation controls plus disposable SQLite DDL.
-- Async delivery is a controlled ordering seam, not a native network fault.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local completion, db = require('dadbod-grip.completion'), require('dadbod-grip.db')
local function schema(name) return { [name] = { { column_name = 'id', data_type = 'integer' } } } end
local function controlled(fn)
  local old_async, old_sync = db.get_schema_batch_async, db.get_schema_batch
  local ok, err = xpcall(fn, debug.traceback)
  db.get_schema_batch_async, db.get_schema_batch = old_async, old_sync
  assert(ok, err)
end
H.test('S01 invalidation bars an older async warm from repopulating completion', function(c)
  controlled(function()
    local pending
    db.get_schema_batch_async = function(_, callback) pending = callback end
    db.get_schema_batch = function() return schema('fresh_table') end
    completion.warm_schema(c.url)
    completion.invalidate(c.url)
    pending(schema('dropped_table'))
    H.eq(completion.get_schema(c.url), schema('fresh_table'))
  end)
end)
H.test('S02 latest started warm owns cache even if older result arrives last', function(c)
  controlled(function()
    local pending = {}
    db.get_schema_batch_async = function(_, callback) pending[#pending + 1] = callback end
    completion.warm_schema(c.url); completion.warm_schema(c.url)
    pending[2](schema('newest_table')); pending[1](schema('oldest_table'))
    H.eq(completion.get_schema(c.url), schema('newest_table'))
  end)
end)
H.test('S03 invalidation while a synchronous fetch is nested bars stale cache publication', function(c)
  controlled(function()
    local calls = 0
    db.get_schema_batch = function()
      calls = calls + 1
      if calls == 1 then completion.invalidate(c.url); return schema('old_table') end
      return schema('fresh_table')
    end
    completion.get_schema(c.url)
    H.eq(completion.get_schema(c.url), schema('fresh_table'))
    H.eq(calls, 2, 'stale synchronous result must not be reused')
  end)
end)
H.test('S04 successful ALTER refreshes actual cached completion column names', function(c)
  c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT)')
  local before = completion.get_schema(c.url)
  assert(before.t and #before.t == 2)
  c.exec('ALTER TABLE t ADD COLUMN added TEXT')
  local after = completion.get_schema(c.url)
  local names = {}; for _, col in ipairs(after.t or {}) do names[#names + 1] = col.column_name end
  H.eq(names, { 'id', 'payload', 'added' })
end)
H.test('S05 successful CREATE and DROP refresh actual table suggestions', function(c)
  c.exec('CREATE TABLE before_table(id INTEGER PRIMARY KEY)')
  assert(completion.get_schema(c.url).before_table)
  c.exec('DROP TABLE before_table'); c.exec('CREATE TABLE after_table(id INTEGER PRIMARY KEY)')
  local got = completion.get_schema(c.url)
  assert(got.after_table and not got.before_table, vim.inspect(got))
end)
H.test('S06 explicit schema refresh recovers completion after external DDL', function(c)
  c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY)')
  assert(completion.get_schema(c.url).t)
  local native = vim.system({ 'sqlite3', c.url:sub(8), 'ALTER TABLE t ADD COLUMN external TEXT' }, { text = true }):wait()
  assert(native.code == 0, native.stderr)
  require('dadbod-grip.schema').refresh(c.url)
  local cols = completion.get_schema(c.url).t
  H.eq(cols and cols[2] and cols[2].column_name, 'external')
end)
H.test('S07 failed DDL retains the accurate cached schema and other URL isolation', function(c)
  c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY)')
  local before = completion.get_schema(c.url)
  local result = db.execute('ALTER TABLE absent ADD COLUMN x TEXT', c.url)
  assert(not result, 'invalid native DDL must fail')
  H.eq(completion.get_schema(c.url), before)
  controlled(function()
    local callbacks = {}
    db.get_schema_batch_async = function(url, callback) callbacks[url] = callback end
    completion.warm_schema(c.url); completion.warm_schema(c.url .. '.other')
    completion.invalidate(c.url)
    callbacks[c.url .. '.other'](schema('other_connection'))
    H.eq(completion.get_schema(c.url .. '.other'), schema('other_connection'))
  end)
end)
H.finish('reliability_adversarial_schema_spec')
