-- Native SQLite read/write lifecycle regression. The held transaction and
-- stdin timing are controlled at the process boundary, not a native outage.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local db, view = require('dadbod-grip.db'), require('dadbod-grip.view')
H.test('a foreground writer immediately after Apply is not blocked by refresh metadata', function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,payload); INSERT INTO items VALUES(1,'before')")
  local buf, session = c.open('items')
  local system, columns, execute = vim.system, db.get_column_info, db.execute
  local trace, armed, in_metadata, held = {}, false, false, false
  local metadata_exit, writer_exit, writes = false, false, 0
  local target = "UPDATE items SET payload=X'6F757273' WHERE id=1"
  local function event(name, extra)
    trace[#trace + 1] = { event = name, ns = tostring(vim.uv.hrtime()), detail = extra }
  end
  db.execute = function(statement, ...)
    if statement == target then writes = writes + 1 end
    local result, err = execute(statement, ...)
    if type(statement) == 'table' and result then armed = true; event('apply_committed') end
    return result, err
  end
  db.get_column_info = function(name, url)
    if armed and not held and name == 'items' and url == c.url then
      held, in_metadata = true, true
      local ok, result, err = pcall(columns, name, url)
      in_metadata = false
      if not ok then error(result, 0) end
      return result, err
    end
    return columns(name, url)
  end
  vim.system = function(args, opts, callback)
    local sql = opts and opts.stdin
    local metadata = in_metadata and type(sql) == 'string' and sql:find('PRAGMA table_info',1,true)
    local writer = type(sql) == 'string' and sql:find(target,1,true)
    if not metadata and not writer then return system(args, opts, callback) end
    local controlled = vim.tbl_extend('force', {}, opts, { stdin = true })
    local process = system(args, controlled, function(result)
      event(metadata and 'metadata_exit' or 'writer_exit', { code = result.code, stderr = result.stderr })
      if metadata then metadata_exit = true else writer_exit = true end
      if callback then callback(result) end
    end)
    event(metadata and 'metadata_spawn' or 'writer_spawn', { pid = process.pid, sql = sql })
    if metadata then
      -- Actual PRAGMA reads sqlite_schema inside this real read transaction.
      process:write('BEGIN;\n' .. sql .. ';\n')
      vim.defer_fn(function()
        event('metadata_commit_sent')
        process:write('\nCOMMIT;\n'); process:write(nil)
      end, 500)
    else
      -- Leave stdin open so the native reader queued by Apply can enter first.
      vim.defer_fn(function()
        event('writer_sql_sent')
        process:write(sql); process:write(nil)
      end, 200)
    end
    return process
  end
  local next_write, next_err
  local ok, err = xpcall(function()
    c.edit(buf, session, 1, 'payload', 'ours')
    session.on_apply(buf)
    assert(#(session._txn_undo_stack or {}) == 1, 'Apply did not establish verified Undo')
    event('apply_returned')
    next_write, next_err = db.execute(target, c.url)
    event('foreground_returned', { success = next_write ~= nil, error = next_err })
    assert(vim.wait(2000, function() return writer_exit and (not held or metadata_exit) end, 1),
      'owned native clients did not exit')
  end, debug.traceback)
  vim.system, db.get_column_info, db.execute = system, columns, execute
  print('SQLITE_METADATA_LIFETIME ' .. vim.json.encode(trace))
  assert(ok, err)
  assert(next_write, 'next foreground writer failed: ' .. tostring(next_err))
  H.eq(writes, 1, 'original next write was retried')
  H.eq(c.scalar("SELECT typeof(payload)||':'||hex(payload) FROM items"), 'blob:6F757273')
  H.key(buf, require('dadbod-grip.keymaps').get('grid_undo'))
  H.eq(c.scalar("SELECT typeof(payload)||':'||hex(payload) FROM items"), 'blob:6F757273',
    'conflicted Undo changed external storage')
  H.eq(#session._txn_undo_stack, 1, 'conflicted Undo was consumed')
  assert(view._sessions[buf] == session, 'live grid ownership changed')
end)
H.finish('reliability_sqlite_reader_lifetime_spec')
