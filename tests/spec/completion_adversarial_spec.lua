-- Independent contract regressions, frozen before candidate inspection.
-- Native autocmd/keymap dispatch; popup calls and scheduling are controlled seams.
dofile('tests/minimal_init.lua')
local completion = require('dadbod-grip.completion')
local db = require('dadbod-grip.db')
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print('FAIL: ' .. name .. ': ' .. err) end
end

local function auto_case(line, mutate, expected, raw)
  local originals = {schedule=vim.schedule, complete=vim.fn.complete, pum=vim.fn.pumvisible,
    mode=vim.fn.mode, getmode=vim.api.nvim_get_mode, candidates=completion.complete}
  local oldbuf, oldve = vim.api.nvim_get_current_buf(), vim.o.virtualedit
  local buf = vim.api.nvim_create_buf(false, true)
  local queued, seen, mode, url, popup = {}, {}, 'i', 'duckdb:/synthetic/independent.duckdb', 0
  local ok, err = xpcall(function()
    vim.api.nvim_set_current_buf(buf)
    vim.o.virtualedit = 'onemore'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {line})
    vim.api.nvim_win_set_cursor(0, {1, #line})
    completion.complete = function() return raw or {{word='SELECT', menu='[keyword]'}} end
    vim.fn.mode = function() return mode end
    vim.api.nvim_get_mode = function() return {mode=mode} end
    vim.fn.pumvisible = function() return popup end
    vim.fn.complete = function(start, items) seen[#seen + 1] = {buf=vim.api.nvim_get_current_buf(),start=start,items=items} end
    completion.setup_auto_complete(buf, function() return url end)
    vim.schedule = function(cb) queued[#queued + 1] = cb end
    vim.api.nvim_exec_autocmds('TextChangedI', {buffer=buf})
    if mutate then mutate({buf=buf, mode=function(v) mode=v end, url=function(v) url=v end,
      popup=function(v) popup=v end}) end
    for _, cb in ipairs(queued) do cb() end
    assert(#seen == expected, 'expected popup calls '..expected..', got '..#seen)
    if #seen > 0 then assert(seen[1].buf == buf, 'popup targeted another buffer') end
  end, debug.traceback)
  vim.schedule, vim.fn.complete, vim.fn.pumvisible = originals.schedule, originals.complete, originals.pum
  vim.fn.mode, vim.api.nvim_get_mode, completion.complete = originals.mode, originals.getmode, originals.candidates
  vim.o.virtualedit = oldve
  if vim.api.nvim_buf_is_valid(oldbuf) then vim.api.nvim_set_current_buf(oldbuf) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, {force=true}) end
  if not ok then error(err) end
end

test('A01 one character stays quiet', function() auto_case('S', nil, 0) end)
test('A02 two characters can open a menu', function() auto_case('SE', nil, 1) end)
test('A03 sole exact match is quiet case-insensitively', function() auto_case('select', nil, 0) end)
test('A04 qualifier dot remains useful', function() auto_case('u.', nil, 1, {{word='name',menu='[text]'}}) end)
test('A05 switched buffer does not receive stale completion', function()
  auto_case('SE', function()
    local other=vim.api.nvim_create_buf(false,true)
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_buf_set_lines(other,0,-1,false,{'SE'})
    vim.api.nvim_win_set_cursor(0,{1,2})
  end, 0)
end)
test('A06 normal mode suppresses deferred work', function() auto_case('SE', function(s) s.mode('n') end, 0) end)
test('A07 changed text suppresses deferred work', function()
  auto_case('SE', function(s) vim.api.nvim_buf_set_lines(s.buf,0,-1,false,{'FR'}) end, 0)
end)
test('A08 changed cursor suppresses deferred work', function()
  auto_case('SE', function() vim.api.nvim_win_set_cursor(0,{1,1}) end, 0)
end)
test('A09 changed connection suppresses deferred work', function()
  auto_case('SE', function(s) s.url('duckdb:/synthetic/other.duckdb') end, 0)
end)
test('A10 deleted buffer suppresses deferred work', function()
  auto_case('SE', function(s) vim.api.nvim_buf_delete(s.buf,{force=true}) end, 0)
end)
test('A11 existing popup is left alone', function() auto_case('SE',function(s) s.popup(1) end,0) end)
test('A12 native options stay scoped and non-inserting on supported floors', function()
  local global, oldbuf = vim.o.completeopt, vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false,true)
  completion.setup_auto_complete(buf,function() return nil end)
  local scope = vim.api.nvim_get_option_info2('completeopt',{}).scope
  -- Neovim0.10 has a global-only option. The original literal buffer accessor
  -- fails before a popup; preserve that RED, and check equivalent native scope.
  assert(vim.o.completeopt == global,'unfocused pad changed global completeopt')
  vim.api.nvim_set_current_buf(buf)
  local opts = scope == 'global' and vim.o.completeopt or vim.bo[buf].completeopt
  vim.api.nvim_set_current_buf(oldbuf)
  vim.api.nvim_buf_delete(buf,{force=true})
  assert(vim.o.completeopt == global,'pad leave did not restore global completeopt')
  assert(opts:find('noinsert',1,true) and opts:find('noselect',1,true),'missing noinsert/noselect: '..opts)
end)

test('A13 Enter without selected native entry dismisses then inserts newline', function()
  local pad = require('dadbod-grip.query_pad')
  local cget, warm, schema = completion.get_schema, completion.warm_schema, db.get_schema_batch
  local feed, pum, info = vim.api.nvim_feedkeys, vim.fn.pumvisible, vim.fn.complete_info
  local cmp = package.loaded.cmp
  local captured
  local ok, err = xpcall(function()
    completion.get_schema = function() return {} end
    completion.warm_schema = function() end
    db.get_schema_batch = function() return {} end
    pad.open('sqlite:/synthetic/never-opened.sqlite', {initial_sql='SE'})
    local buf = pad.get_pad_bufnr()
    local maps = vim.api.nvim_buf_get_keymap(buf,'i')
    local enter
    for _, map in ipairs(maps) do if map.lhs == '<CR>' then enter=map.callback end end
    assert(enter,'query pad Enter callback missing')
    package.loaded.cmp = {visible=function() return false end}
    vim.fn.pumvisible = function() return 1 end
    vim.fn.complete_info = function() return {selected=-1} end
    vim.api.nvim_feedkeys = function(keys) captured=keys end
    enter()
    assert(captured == vim.api.nvim_replace_termcodes('<C-e><CR>',true,true,true), 'unselected menu did not dismiss/newline')
  end, debug.traceback)
  completion.get_schema, completion.warm_schema, db.get_schema_batch = cget,warm,schema
  vim.api.nvim_feedkeys,vim.fn.pumvisible,vim.fn.complete_info=feed,pum,info
  package.loaded.cmp=cmp
  local buf=pad.get_pad_bufnr()
  if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf,{force=true}) end
  if not ok then error(err) end
end)

print(string.format('completion_adversarial_spec: %d passed, %d failed',pass,fail))
if fail > 0 then os.exit(1) end
