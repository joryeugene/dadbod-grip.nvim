return function(scenario)
  vim.cmd('filetype plugin on')
  local grip, view = require('dadbod-grip'), require('dadbod-grip.view')
  local data, query = require('dadbod-grip.data'), require('dadbod-grip.query')
  local pad = require('dadbod-grip.query_pad')
  grip.setup({show_hints = false, show_running_time = false, show_result_time = true,
    discovery = false, ai = false, completion = false, open_sidebar = false,
    keymaps = scenario == 'custom' and {qpad_execute = '<F9>', help = '<F2>',
      sidebar_filter = false, sidebar_filter_c = false, tab_1 = '<F8>'} or {}})
  local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local function screen(win)
    vim.cmd('redraw!')
    vim.wait(20, function() return false end, 5)
    vim.cmd('redraw!')
    local info, lines = vim.fn.getwininfo(win)[1], {}
    for row = info.winrow, info.winrow + info.height - 1 do
      local line = ''
      for col = info.wincol + info.textoff, info.wincol + info.width - 1 do
        line = line .. vim.fn.screenstring(row, col)
      end
      lines[#lines + 1] = line:gsub('%s+$', '')
    end
    return table.concat(lines, '\n')
  end
  local function absent(value)
    for _, hint in ipairs({'?:help', 'i:edit', 'H←', '→L', 'Grip keys:', 'Welcome keys'}) do
      assert(not value:find(hint, 1, true), 'automatic hint leaked: ' .. hint .. '\n' .. value)
    end
  end
  local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  end
  if scenario == 'pad-editing' then
    pad.open('sqlite:tests/seed_sqlite.db')
    local buf, win = pad.get_pad_bufnr(), vim.api.nvim_get_current_win()
    assert(text(buf) == '', 'new pad contains help text')
    vim.cmd('GripZen')
    assert(screen(win):find('runs this SQL block.', 1, true), 'empty pad help absent')
    local function check_anchor()
      local visible = screen(win)
      local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('grip_pad_hints'), 0, -1, {details = true})
      assert(#marks == 1 and marks[1][2] == vim.api.nvim_buf_line_count(buf) - 1,
        'pad help interrupts SQL body: ' .. vim.inspect({marks = marks, lines = vim.api.nvim_buf_line_count(buf)}))
      assert(visible:find('runs this SQL block.', 1, true), 'pad help disappeared while editing')
    end
    press('i-- Grip keys: old user comment<CR>SELECT id<CR>FROM users;<Esc>')
    check_anchor()
    vim.fn.setreg('z', {'ORDER BY id;', 'LIMIT 10;'}, 'V')
    press('"zp')
    check_anchor()
    local pasted = text(buf)
    press('u'); check_anchor()
    assert(text(buf) ~= pasted, 'native undo did not undo paste')
    press('<C-r>'); check_anchor()
    assert(text(buf) == pasted, 'native redo did not restore paste')
    local before = {text(buf), vim.bo[buf].modified, vim.api.nvim_buf_get_changedtick(buf),
      vim.api.nvim_buf_call(buf, vim.fn.undotree), vim.api.nvim_win_get_cursor(win)}
    for _ = 1, 3 do vim.cmd('GripZen'); vim.cmd('GripZen'); check_anchor() end
    local after = {text(buf), vim.bo[buf].modified, vim.api.nvim_buf_get_changedtick(buf),
      vim.api.nvim_buf_call(buf, vim.fn.undotree), vim.api.nvim_win_get_cursor(win)}
    assert(vim.deep_equal(before, after), 'pad toggle changed SQL, undo or cursor')
    return true
  end
  if scenario == 'surfaces' or scenario == 'custom' then
    grip.open_welcome()
    local welcome, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    absent(text(welcome))
    assert(text(welcome):find('Open demo', 1, true) and text(welcome):find('Connect a database', 1, true),
      'Zen removed welcome purpose')
    assert(not text(welcome):find('<CR> choose', 1, true), 'welcome instructions leaked')
    local cursor = vim.api.nvim_win_get_cursor(win)
    vim.cmd('GripZen')
    assert(text(welcome):find('Welcome keys', 1, true), 'welcome hints did not restore')
    vim.cmd('GripZen')
    assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win)), 'welcome cursor changed')
    local schema = require('dadbod-grip.schema')
    schema.toggle('sqlite:tests/seed_sqlite.db')
    local sbuf = vim.api.nvim_get_current_buf()
    local before = vim.deepcopy(schema.get_state('sqlite:tests/seed_sqlite.db'))
    absent(text(sbuf))
    assert(text(sbuf):find('users', 1, true), 'sidebar objects disappeared')
    vim.cmd('GripZen')
    local normal = text(sbuf)
    assert(normal:find(scenario == 'custom' and '<F8>:conn' or '1:conn', 1, true), 'sidebar key hint absent')
    if scenario == 'custom' then
      assert(not normal:find(' / ', 1, true) and not normal:find(' F ', 1, true), 'disabled sidebar hint advertised')
    end
    vim.cmd('GripZen')
    assert(vim.deep_equal(before, schema.get_state('sqlite:tests/seed_sqlite.db')), 'Zen refreshed sidebar state')
    press(scenario == 'custom' and '<F2>' or '?')
    assert(vim.api.nvim_win_get_config(0).relative ~= '', 'explicit sidebar help unavailable')
    return true
  end
  if scenario == 'ambiwidth' then vim.o.ambiwidth = 'double' end
  local rows = {}
  for i = 1, 10 do rows[i] = {tostring(i), i == 2 and nil or string.rep('long value ', 8), 'tail'} end
  rows[2][2] = nil
  local state = data.new({columns = {'id', 'note', 'tail'}, rows = rows,
    primary_keys = scenario == 'readonly' and {} or {'id'}, table_name = 'zen_fixture'})
  local buf = view.open(state, 'sqlite:tests/seed_sqlite.db', 'SELECT * FROM zen_fixture',
    {elapsed_ms = 4321, write_elapsed_ms = scenario == 'write-owned' and 1555 or nil,
      reuse_win = vim.api.nvim_get_current_win(), max_col_width = 80})
  local session, win = view._sessions[buf], vim.api.nvim_get_current_win()
  session.query_spec = query.set_page(query.new_table('zen_fixture', 100), 376)
  session.query_spec.filters = {{clause = 'id > 0'}}
  session.total_rows = 100000
  if scenario == 'unknown' then session.total_rows = nil end
  if scenario == 'unknown' then session.query_spec.page_size = 10 end
  session.hidden_columns = {tail = true}
  if scenario == 'metadata' then session.current_view = 'columns' end
  if scenario == 'mutation' then session.pending_mutation = {type = 'UPDATE'} end
  view.apply_edit(buf, data.toggle_delete(data.add_change(state, 3, 'note', '9999'), 4))
  state = session.state
  pad.open('sqlite:tests/seed_sqlite.db')
  local pbuf, pwin = pad.get_pad_bufnr(), vim.api.nvim_get_current_win()
  -- Neovim 0.10's bundled SQL ftplugin leaves this unset. Provide SQL comment
  -- syntax in this fixture while retaining the actual native gc/gcc mappings.
  if vim.bo[pbuf].commentstring == '' then vim.bo[pbuf].commentstring = '-- %s' end
  assert(text(pbuf) == '', 'new pad contains generated SQL comments')
  vim.cmd('GripZen')
  assert(screen(pwin):find('runs this SQL block.', 1, true), 'new normal pad help is not visible')
  vim.cmd('GripZen')
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false,
    {'-- Grip keys: user-owned old comment', '-- unsaved draft', 'SELECT id FROM users;'})
  vim.bo[pbuf].modified = true
  vim.api.nvim_win_set_height(pwin, 5)
  vim.api.nvim_win_set_cursor(pwin, {3, 7})
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, {session._render.data_start + 2, session._render.byte_positions[3].note.start})
  if scenario == 'gutter' then vim.wo.number, vim.wo.signcolumn = true, 'yes:2' end
  local wins = {win}
  if scenario == 'shared' then
    vim.cmd('vsplit')
    wins[#wins + 1] = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(wins[2], 28)
    vim.api.nvim_win_set_cursor(wins[2], {session._render.data_start + 4, 60})
    vim.fn.winrestview({leftcol = 35})
  end
  local function snapshot()
    local values = {state = vim.inspect(session.state), undo = vim.inspect(session.undo_stack),
      sql = session.query_sql, time = session._query_times[state.rows], write_time = session._write_times[state.rows],
      pad = text(pbuf), modified = vim.bo[pbuf].modified, tick = vim.api.nvim_buf_get_changedtick(pbuf),
      pad_undo = vim.api.nvim_buf_call(pbuf, vim.fn.undotree), windows = {}}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      values.windows[w] = {cursor = vim.api.nvim_win_get_cursor(w), width = vim.api.nvim_win_get_width(w),
        height = vim.api.nvim_win_get_height(w), buf = vim.api.nvim_win_get_buf(w)}
    end
    local r = session._render
    values.data = vim.api.nvim_buf_get_lines(buf, 0, r.data_start + #r.ordered, false)
    values.marks = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('dadbod_grip'), 0, -1, {details = true})) do
      if mark[2] >= r.data_start - 1 and mark[2] < r.data_start - 1 + #r.ordered then
        values.marks[#values.marks + 1] = {mark[2], mark[3], mark[4].hl_group, mark[4].end_col}
      end
    end
    return values
  end
  for _, w in ipairs(wins) do screen(w) end
  local original = snapshot()
  local zen_raw = text(buf)
  local function check_zen()
    absent(text(buf))
    assert(text(buf):find('id > 0', 1, true), 'filter lost')
    for _, w in ipairs(wins) do
      local visible = screen(w)
      for _, value in ipairs({'2 staged', '1 hidden', '4.3s client'}) do
        assert(visible:find(value, 1, true), 'essential status not visible: ' .. value .. '\n' .. visible)
      end
      if scenario == 'write-owned' then
        assert(visible:find('Write: 1.6s client', 1, true), 'owned write timing disappeared in Zen: ' .. visible)
      end
      if scenario == 'metadata' then
        assert(visible:find('10 rows', 1, true), 'metadata row count clipped: ' .. visible)
        assert(not visible:find('Page ', 1, true) and not visible:find('100000 rows', 1, true),
          'records pagination leaked into metadata: ' .. visible)
      elseif scenario ~= 'unknown' then
        assert(visible:find('Page 376/1000', 1, true) and visible:find('100000 rows', 1, true), 'page/total clipped: ' .. visible)
      else assert(visible:find('more possible', 1, true), 'unknown-total safety warning lost') end
      if scenario == 'readonly' then assert(visible:find('read-only', 1, true), 'read-only status clipped') end
      absent(visible)
    end
  end
  check_zen()
  for _ = 1, 3 do
    vim.cmd('GripZen')
    assert(grip.get_opts().show_hints == true and session._render.hint_row, 'normal hints not restored')
    assert(screen(pwin):find('runs this SQL block.', 1, true), 'pad decoration not restored')
    vim.cmd('GripZen')
    check_zen()
    local current = snapshot()
    local differences = {}
    for key, value in pairs(original) do
      if not vim.deep_equal(value, current[key]) then differences[#differences + 1] = key .. ': ' .. vim.inspect({value, current[key]}) end
    end
    assert(text(buf) == zen_raw and #differences == 0, 'toggle changed editor/data state: ' .. table.concat(differences, '\n')
      .. (text(buf) ~= zen_raw and ('\nraw: ' .. zen_raw .. '\nnew: ' .. text(buf)) or ''))
    assert(grip.get_opts().show_running_time == false and grip.get_opts().show_result_time == true, 'Zen changed timing flags')
  end
  if scenario == 'shared' then
    vim.api.nvim_win_set_width(wins[2], 14)
    check_zen()
    assert(vim.api.nvim_buf_get_changedtick(pbuf) == original.tick, 'resize edited SQL')
    vim.api.nvim_win_set_width(wins[2], 28)
    check_zen()
  end
  if scenario == 'grid' then
    vim.api.nvim_set_current_win(pwin)
    vim.api.nvim_win_set_cursor(pwin, {3, 0})
    local draft = text(pbuf)
    press('gcc')
    assert(vim.api.nvim_get_current_line():match('^%s*%-%-'), 'native SQL gcc stopped commenting: '
      .. vim.inspect({line = vim.api.nvim_get_current_line(), commentstring = vim.bo.commentstring,
        gc = vim.fn.maparg('gc', 'n', false, true), gcc = vim.fn.maparg('gcc', 'n', false, true)}))
    press('gcc')
    assert(text(pbuf) == draft, 'native SQL gcc did not restore draft')
  end
  if scenario == 'failures' then
    local before = snapshot()
    local notify, notices = vim.notify, {}
    vim.notify = function(message) notices[#notices + 1] = tostring(message) end
    grip.open('SELECT absent_zen_column FROM users', 'sqlite:tests/seed_sqlite.db', {reuse_win = win, from_pad = true})
    vim.notify = notify
    assert(table.concat(notices, '\n'):find('absent_zen_column', 1, true), 'actual SQL error suppressed')
    local completed, reason
    require('dadbod-grip.ui').blocking('Zen cancellation', function()
      vim.defer_fn(function() vim.api.nvim_input('\003') end, 30)
      completed, reason = vim.wait(1000, function() return false end, 5)
    end)
    assert(not completed and reason == -2, 'native Ctrl-C did not interrupt loading')
    assert(vim.deep_equal(before, snapshot()), 'error/cancel changed prior result or editor state')
  end
  grip.setup({show_result_time = false})
  view.render(buf, state)
  assert(not screen(win):find('client', 1, true), 'timing did not hide independently')
  assert(session._query_times[state.rows] == 4321, 'timing measurement discarded')
  if scenario == 'write-owned' then
    assert(not screen(win):find('Write:', 1, true), 'write timing did not hide independently')
    assert(session._write_times[state.rows] == 1555, 'hiding write timing discarded its measurement')
  end
  vim.api.nvim_set_current_win(win)
  press('?')
  assert(vim.api.nvim_win_get_config(0).relative ~= '', 'explicit help unavailable in Zen')
  return true
end
