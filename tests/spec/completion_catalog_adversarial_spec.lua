-- Independent async catalog tests. Controlled metadata callbacks; no fork SQL runs.
dofile('tests/minimal_init.lua')
local c, db = require('dadbod-grip.completion'), require('dadbod-grip.db')
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass=pass+1 else fail=fail+1; print('FAIL: '..name..': '..err) end
end
local sequence=0
local function with_catalog(fn)
  sequence=sequence+1
  local url='duckdb:/synthetic/independent-'..sequence..'.duckdb'
  local orig={async=db.get_completion_functions_async, batch=db.get_schema_batch,
    batchasync=db.get_schema_batch_async, query=db.query, clock=os.time}
  local callbacks, requests, now={},0,1000
  db.get_schema_batch=function() return {users={{column_name='name',data_type='text'}}} end
  db.get_schema_batch_async=function(_,cb) cb({users={{column_name='name',data_type='text'}}}) end
  db.query=function() error('catalog must never synchronously query') end
  db.get_completion_functions_async=function(target,cb)
    requests=requests+1; callbacks[#callbacks+1]={url=target,cb=cb}
  end
  -- luacheck: push ignore 122
  os.time=function() return now end
  -- luacheck: pop
  local ok,err=xpcall(function()
    assert(type(c.get_functions)=='function' and type(c.warm_functions)=='function','async catalog API missing')
    fn({url=url, callbacks=callbacks, count=function() return requests end,
      clock=function(v) now=v end})
  end,debug.traceback)
  db.get_completion_functions_async,db.get_schema_batch,db.get_schema_batch_async,db.query=orig.async,orig.batch,orig.batchasync,orig.query
  -- luacheck: push ignore 122
  os.time=orig.clock
  -- luacheck: pop
  if not ok then error(err) end
end
local catalog={
  {name='abs',type='scalar'},{name='avg',type='aggregate'},
  {name='aliasmacro',type='macro'},{name='range',type='table'},
  {name='relmacro',type='table_macro'},{name='abs',type='scalar'},
}
local function words(items)
  local out={}
  for _,it in ipairs(items) do out[it.word]=(out[it.word] or 0)+1 end
  return out
end

test('F01 cold cache is nonblocking and coalesces requests',function() with_catalog(function(s)
  assert(#c.get_functions(s.url)==0,'cold fetch returned blocking result')
  for _=1,10 do c.get_functions(s.url); c.warm_functions(s.url) end
  assert(s.count()==1,'duplicate in-flight requests: '..s.count())
  s.callbacks[1].cb(catalog)
  assert(#c.get_functions(s.url)>0,'completed catalog not cached')
  assert(s.count()==1,'fresh catalog queried again')
end) end)

test('F02 invalidate fences old callback and does not clear newer pending',function() with_catalog(function(s)
  c.warm_functions(s.url)
  c.invalidate(s.url)
  c.warm_functions(s.url)
  assert(s.count()==2)
  s.callbacks[1].cb({{name='obsolete',type='scalar'}})
  assert(#c.get_functions(s.url)==0,'old callback repopulated cache')
  assert(s.count()==2,'old callback cleared newer in-flight request')
  s.callbacks[2].cb({{name='fresh',type='scalar'}})
  assert(c.get_functions(s.url)[1].name=='fresh','new callback lost')
end) end)

test('F03 successful TTL expiry starts one background refresh',function() with_catalog(function(s)
  c.warm_functions(s.url); s.callbacks[1].cb(catalog)
  s.clock(1301)
  c.get_functions(s.url); c.get_functions(s.url)
  assert(s.count()==2,'expired cache did not refresh exactly once')
end) end)

test('F04 errors use short cooldown rather than successful-empty TTL',function() with_catalog(function(s)
  c.warm_functions(s.url); s.callbacks[1].cb(nil)
  for _=1,5 do c.get_functions(s.url) end
  assert(s.count()==1,'failed request flood')
  s.clock(1006); c.get_functions(s.url)
  assert(s.count()==2,'error cached for full successful TTL')
  s.callbacks[2].cb({})
  s.clock(1012); c.get_functions(s.url)
  assert(s.count()==2,'legitimate empty catalog not cached')
end) end)

test('F05 URL caches isolated across invalidation',function() with_catalog(function(s)
  local other=s.url..'.other'
  c.warm_functions(s.url); c.warm_functions(other)
  s.callbacks[1].cb({{name='one',type='scalar'}})
  s.callbacks[2].cb({{name='two',type='scalar'}})
  c.invalidate(s.url)
  assert(c.get_functions(other)[1].name=='two','unrelated URL lost')
end) end)

test('F06 scalar aggregate macro names in expressions and deduplicated',function() with_catalog(function(s)
  c.warm_functions(s.url); s.callbacks[1].cb(catalog)
  local items=c.complete('SELECT a',s.url)
  local w=words(items)
  assert(w['abs(']==1 and w['avg(']==1 and w['aliasmacro(']==1,'expression functions missing/duplicated')
  assert(not words(c.complete('SELECT r',s.url))['range(']
    and not words(c.complete('SELECT r',s.url))['relmacro('],'table functions leaked into expressions')
end) end)

test('F07 table functions only after FROM or JOIN',function() with_catalog(function(s)
  c.warm_functions(s.url); s.callbacks[1].cb(catalog)
  local from=words(c.complete('SELECT * FROM r',s.url))
  local join=words(c.complete('JOIN r',s.url))
  assert(from['range('] and from['relmacro('] and join['range('],'FROM/JOIN function missing')
  assert(not words(c.complete('UPDATE r',s.url))['range('],'table function in UPDATE')
  assert(not words(c.complete('INSERT INTO r',s.url))['range('],'table function in INSERT')
  assert(not words(c.complete('SELECT u.r',s.url,{u='users'}))['range('],'function after column qualifier')
end) end)

test('F08 function data shared by omnifunc cmp and blink',function() with_catalog(function(s)
  c.warm_functions(s.url); s.callbacks[1].cb(catalog)
  local buf=vim.api.nvim_create_buf(false,true)
  local old=vim.api.nvim_get_current_buf(); local ve=vim.o.virtualedit
  local cmpold,typesold=package.loaded.cmp,package.loaded['cmp.types']
  local ok,err=xpcall(function()
    vim.api.nvim_set_current_buf(buf); vim.b.db=s.url; vim.o.virtualedit='onemore'
    vim.api.nvim_buf_set_lines(buf,0,-1,false,{'SELECT ab'})
    vim.api.nvim_win_set_cursor(0,{1,9})
    assert(words(c.omnifunc(0,'ab'))['abs('],'omnifunc missing function')
    local cmp_source
    package.loaded.cmp={register_source=function(_,src) cmp_source=src end}
    package.loaded['cmp.types']={lsp={CompletionItemKind={Field=5,Module=9,Function=3,Keyword=14}}}
    c.register_cmp_source()
    local result
    cmp_source:complete({context={cursor_before_line='SELECT ab',bufnr=buf}},function(v) result=v end)
    local function found(items)
      for _,it in ipairs(items or {}) do if it.label=='abs(' then return it end end
    end
    assert(found(result and result.items) and found(result.items).kind==3,'cmp function kind/insert missing')
    assert(found(result.items).insertText=='abs(','cmp inserted different text')
    local blink=require('dadbod-grip.completion.blink').new()
    blink:get_completions({line='SELECT ab',cursor={1,9},bufnr=buf},function(v) result=v end)
    assert(found(result.items) and found(result.items).kind==3,'blink function kind missing')
  end,debug.traceback)
  package.loaded.cmp,package.loaded['cmp.types']=cmpold,typesold
  vim.o.virtualedit=ve; vim.api.nvim_set_current_buf(old); vim.api.nvim_buf_delete(buf,{force=true})
  if not ok then error(err) end
end) end)

print(string.format('completion_catalog_adversarial_spec: %d passed, %d failed',pass,fail))
if fail>0 then os.exit(1) end
