-- Native public DDL admission and visible-sidebar refresh boundary.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local grip, schema = require('dadbod-grip'), require('dadbod-grip.schema')
local function has(items, name)
  for _, item in ipairs(items or {}) do if item.name == name then return true end end
  return false
end
local function sidebar(c, fn)
  schema.close(); schema._reset_state()
  schema.toggle(c.url)
  local ok, err = xpcall(fn, debug.traceback)
  schema.close(); schema._reset_state()
  assert(ok, err)
end
H.test('confirmed public CREATE refreshes the visible same-connection sidebar', function(c)
  c.exec('CREATE TABLE old_table(id INTEGER PRIMARY KEY)')
  sidebar(c, function()
    assert(has(schema.get_state(c.url).items, 'old_table'))
    grip.open('CREATE TABLE fresh_table(id INTEGER PRIMARY KEY)', c.url)
    H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='fresh_table'"), '1')
    assert(has(schema.get_state(c.url).items, 'fresh_table'), 'committed table absent from visible sidebar')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(schema.get_winid()), 0, -1, false)
    assert(table.concat(lines, '\n'):find('fresh_table', 1, true), 'visible tree did not repaint')
  end)
end)
H.test('failed public DDL keeps the visible schema intact', function(c)
  c.exec('CREATE TABLE old_table(id INTEGER PRIMARY KEY)')
  sidebar(c, function()
    grip.open('CREATE TABLE old_table(id INTEGER PRIMARY KEY)', c.url)
    -- A failed batch may have committed a prefix, so cached knowledge may be
    -- cleared. Its displayed schema and explicit reload must stay accurate.
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(schema.get_winid()), 0, -1, false)
    assert(table.concat(lines, '\n'):find('old_table', 1, true))
    schema.refresh(c.url)
    assert(has(schema.get_state(c.url).items, 'old_table'))
    H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='old_table'"), '1')
  end)
end)
H.test('cancelled DDL cannot create or refresh a table', function(c)
  c.exec('CREATE TABLE old_table(id INTEGER PRIMARY KEY)')
  sidebar(c, function()
    local original = vim.fn.confirm
    vim.fn.confirm = function() return 2 end
    local ok, err = pcall(grip.open, 'CREATE TABLE cancelled(id INTEGER PRIMARY KEY)', c.url)
    vim.fn.confirm = original
    assert(ok, err)
    H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='cancelled'"), '0')
    assert(has(schema.get_state(c.url).items, 'old_table') and not has(schema.get_state(c.url).items, 'cancelled'))
  end)
end)
H.test('DDL on another connection leaves the visible sidebar on its owner', function(c)
  c.exec('CREATE TABLE own_table(id INTEGER PRIMARY KEY)')
  sidebar(c, function()
    local other = 'sqlite:' .. c.root .. '/other.sqlite'
    grip.open('CREATE TABLE foreign_table(id INTEGER PRIMARY KEY)', other)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(schema.get_winid()), 0, -1, false)
    local text = table.concat(lines, '\n')
    assert(text:find('own_table', 1, true) and not text:find('foreign_table', 1, true), 'another connection repainted this sidebar')
    assert(has(schema.get_state(c.url).items, 'own_table'))
  end)
end)
H.test('postcommit sidebar failure cannot turn successful DDL into refusal', function(c)
  c.exec('CREATE TABLE old_table(id INTEGER PRIMARY KEY)')
  sidebar(c, function()
    local original = schema.refresh
    schema.refresh = function() error('controlled refresh failure') end
    local ok, err = pcall(grip.open, 'CREATE TABLE committed_table(id INTEGER PRIMARY KEY)', c.url)
    schema.refresh = original
    assert(ok, err)
    H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='committed_table'"), '1')
    assert(table.concat(c.notices, '\n'):find('CREATE executed', 1, true), 'commit was not reported as successful')
  end)
end)
local function external_alter(c)
  local result = vim.system({ 'sqlite3', c.root .. '/case.sqlite',
    'ALTER TABLE items ADD COLUMN fresh TEXT' }, { text = true }):wait()
  H.eq(result.code, 0, result.stderr)
end
local function has_column(info, name)
  for _, column in ipairs(info or {}) do if column.column_name == name then return true end end
  return false
end
H.test('manual grid refresh replaces cached column metadata after external ALTER', function(c)
  c.exec('CREATE TABLE items(id INTEGER PRIMARY KEY); INSERT INTO items VALUES(1)')
  local buf, session = c.open('items')
  assert(not has_column(session._column_info, 'fresh'))
  external_alter(c)
  H.key(buf, require('dadbod-grip.keymaps').get('grid_refresh'))
  assert(vim.wait(1000, function() return has_column(session._column_info, 'fresh') end, 1),
    'grid retained old column metadata after a successful refreshed SELECT')
  H.eq(session.state.columns, { 'id', 'fresh' })
end)
H.test('delayed old metadata cannot overwrite a newer refreshed grid', function(c)
  c.exec('CREATE TABLE items(id INTEGER PRIMARY KEY); INSERT INTO items VALUES(1)')
  local db, view = require('dadbod-grip.db'), require('dadbod-grip.view')
  local original, armed, injected, session, buf = db.get_column_info, false, false
  db.get_column_info = function(name, url)
    local info, err = original(name, url)
    if armed and not injected and name == 'items' and url == c.url then
      injected = true
      external_alter(c)
      session.on_refresh(buf)
      vim.wait(10)
    end
    return info, err
  end
  local ok, err = xpcall(function()
    grip.open('items', c.url, { from_pad = true })
    buf = vim.api.nvim_get_current_buf(); session = assert(view._sessions[buf])
    armed = true
    assert(vim.wait(1000, function() return injected and session._column_info ~= nil end, 1),
      'metadata completion fixture did not run')
    assert(has_column(session._column_info, 'fresh'), 'older metadata response overwrote refreshed columns')
    H.eq(session.state.columns, { 'id', 'fresh' })
  end, debug.traceback)
  db.get_column_info = original
  assert(ok, err)
end)
H.finish('reliability_ddl_refresh_spec')
