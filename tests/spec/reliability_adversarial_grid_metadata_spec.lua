-- Independent bounded review of root's grid metadata ownership delta.
-- SQLite effects are real; explicit callback/error seams are labelled below.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local grip, db, view = require('dadbod-grip'), require('dadbod-grip.db'), require('dadbod-grip.view')

local function has(info, name)
  for _, column in ipairs(info or {}) do if column.column_name == name then return true end end
  return false
end

H.test('GM01 controlled metadata denial after real Apply cannot undo its success', function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,note TEXT); INSERT INTO items VALUES(1,'old')")
  local buf, session = c.open('items')
  local columns, execute = db.get_column_info, db.execute
  local armed, denied, writes = false, 0, 0
  db.get_column_info = function(name, url)
    if armed and name == 'items' and url == c.url then
      denied = denied + 1
      return nil, 'controlled metadata denial after committed Apply'
    end
    return columns(name, url)
  end
  db.execute = function(...)
    writes = writes + 1
    local result, err = execute(...)
    if result then armed = true end
    return result, err
  end
  local ok, err = xpcall(function()
    c.edit(buf, session, 1, 'note', 'committed')
    session.on_apply(buf)
    assert(vim.wait(1000, function() return denied > 0 end, 1), 'postwrite metadata callback did not run')
    H.eq(c.scalar('SELECT note FROM items WHERE id=1'), 'committed')
    H.eq(session.state.rows[1][2], 'committed', 'committed result was replaced')
    H.eq(session._column_info, nil, 'failed metadata was published')
    H.eq(writes, 1, 'Apply was repeated')
    H.eq(#session._txn_undo_stack, 1, 'verified Undo entry was lost')
    assert(session._write_times[session.state.rows] ~= nil, 'successful write timing was lost')
    assert(not require('dadbod-grip.data').has_changes(session.state), 'committed changes remain staged')
  end, debug.traceback)
  db.get_column_info, db.execute = columns, execute
  assert(ok, err)
end)

H.test('GM02 closed grid refuses the scheduled metadata request before dispatch', function(c)
  c.exec('CREATE TABLE items(id INTEGER PRIMARY KEY); INSERT INTO items VALUES(1)')
  local columns, armed, calls = db.get_column_info, false, 0
  db.get_column_info = function(...)
    if armed then calls = calls + 1 end
    return columns(...)
  end
  local ok, err = xpcall(function()
    grip.open('items', c.url, { from_pad = true })
    local buf = vim.api.nvim_get_current_buf()
    local owner = assert(view._sessions[buf])
    armed = true
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.wait(30)
    H.eq(calls, 0, 'closed grid dispatched metadata')
    H.eq(owner._column_info, nil)
    H.eq(view._sessions[buf], nil)
  end, debug.traceback)
  db.get_column_info = columns
  assert(ok, err)
end)

H.test('GM03 edits during a native metadata completion keep the new staged owner', function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,note TEXT); INSERT INTO items VALUES(1,'original')")
  local columns, render = db.get_column_info, grip._render_if_visible
  local armed, injected, metadata_renders, staged = false, false, 0
  local buf, session
  db.get_column_info = function(name, url)
    local result, err = columns(name, url)
    if armed and not injected and name == 'items' and url == c.url then
      injected = true
      c.edit(buf, session, 1, 'note', 'new staging')
      staged = session.state
    end
    return result, err
  end
  grip._render_if_visible = function(...)
    metadata_renders = metadata_renders + 1
    return render(...)
  end
  local ok, err = xpcall(function()
    grip.open('items', c.url, { from_pad = true })
    buf = vim.api.nvim_get_current_buf(); session = assert(view._sessions[buf])
    armed = true
    assert(vim.wait(1000, function() return injected end, 1), 'native metadata completion did not run')
    H.eq(session.state, staged, 'new staged snapshot was replaced')
    H.eq(session._column_info, nil, 'old snapshot admitted metadata after staging changed')
    H.eq(metadata_renders, 0, 'old metadata repainted a newer owner')
    H.eq(c.scalar('SELECT note FROM items'), 'original', 'metadata completion caused a write')
  end, debug.traceback)
  db.get_column_info, grip._render_if_visible = columns, render
  assert(ok, err)
end)

H.test('GM04 reopening another connection excludes the old native metadata result', function(c)
  c.exec('CREATE TABLE items(id INTEGER PRIMARY KEY,old_only TEXT); INSERT INTO items VALUES(1,\'old\')')
  local other = 'sqlite:' .. c.root .. '/other.sqlite'
  local created, create_err = db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,new_only TEXT); INSERT INTO items VALUES(2,'new')", other)
  assert(created, create_err)
  local columns, armed, injected, old_buf, old_session = db.get_column_info, false, false
  local new_buf, new_session
  db.get_column_info = function(name, url)
    local result, err = columns(name, url)
    if armed and not injected and name == 'items' and url == c.url then
      injected = true
      local win = vim.fn.bufwinid(old_buf)
      grip.open('items', other, { from_pad = true, reuse_win = win })
      new_buf = vim.api.nvim_get_current_buf(); new_session = assert(view._sessions[new_buf])
      assert(vim.wait(1000, function() return has(new_session._column_info, 'new_only') end, 1),
        'new connection metadata did not finish')
    end
    return result, err
  end
  local ok, err = xpcall(function()
    grip.open('items', c.url, { from_pad = true })
    old_buf = vim.api.nvim_get_current_buf(); old_session = assert(view._sessions[old_buf])
    armed = true
    assert(vim.wait(1000, function() return injected and new_session ~= nil end, 1), 'connection switch seam did not run')
    H.eq(view._sessions[new_buf], new_session)
    H.eq(new_session.url, other, 'new connection ownership')
    H.eq(new_session.state.rows[1][1], '2', 'new connection rows')
    assert(has(new_session._column_info, 'new_only') and not has(new_session._column_info, 'old_only'),
      'old connection metadata reached the new owner')
    H.eq(old_session._column_info, nil, 'retired owner received a stale metadata result')
  end, debug.traceback)
  db.get_column_info = columns
  assert(ok, err)
end)

H.finish('reliability_adversarial_grid_metadata_spec')
