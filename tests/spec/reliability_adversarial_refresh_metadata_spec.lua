-- Bounded reviewer controls for the post-refresh reader lifetime correction.
-- Apply and the metadata read are actual SQLite operations. The second case
-- models a Lua metadata exception after a real successful commit.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local db, data = require('dadbod-grip.db'), require('dadbod-grip.data')
local function after_apply(c, throw_metadata)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,note TEXT); INSERT INTO items VALUES(1,'old')")
  local buf, session = c.open('items')
  local columns, execute = db.get_column_info, db.execute
  local armed, entered, completed, writes = false, 0, 0, 0
  db.execute = function(...)
    writes = writes + 1
    local result, err = execute(...)
    if result then armed = true end
    return result, err
  end
  db.get_column_info = function(name, url)
    if armed and name == 'items' and url == c.url then
      entered = entered + 1
      if throw_metadata then error('controlled postcommit metadata exception') end
      local result, err = columns(name, url)
      completed = completed + 1 -- real adapter return proves its native read finished
      return result, err
    end
    return columns(name, url)
  end
  local ok, err = xpcall(function()
    c.edit(buf, session, 1, 'note', 'committed')
    session.on_apply(buf)
    H.eq(entered, 1, 'metadata must be attempted before Apply returns, not queued afterward')
    H.eq(completed, throw_metadata and 0 or 1, 'native read must finish before Apply returns')
    H.eq(writes, 1, 'no original write retry')
    H.eq(session.state.rows[1][2], 'committed', 'committed rows must publish despite metadata failure')
    H.eq(data.has_changes(session.state), false)
    H.eq(#session._txn_undo_stack, 1, 'verified Undo entry retained')
    H.eq(c.scalar('SELECT note FROM items WHERE id=1'), 'committed')
    vim.wait(30)
    H.eq(entered, 1, 'no deferred duplicate metadata read after publication')
  end, debug.traceback)
  db.get_column_info, db.execute = columns, execute
  assert(ok, err)
end
H.test('RM01 Apply drains refreshed native column metadata before returning', function(c)
  after_apply(c, false)
end)
H.test('RM02 postcommit metadata exception cannot turn Apply into a refused or repeated write', function(c)
  after_apply(c, true)
end)
H.finish('reliability_adversarial_refresh_metadata_spec')
