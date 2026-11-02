-- Independent native catalog namespace regression, confirmed on candidate7936.
dofile('tests/minimal_init.lua')
local db=require('dadbod-grip.db')
local duck=require('dadbod-grip.adapters.duckdb')
local c=require('dadbod-grip.completion')
local pass,fail=0,0
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err) end
end
if vim.fn.executable('duckdb')==0 then
 assert(vim.env.GRIP_REQUIRE_DUCKDB~='1','DuckDB required')
 print('SKIP completion_catalog_namespace_spec: DuckDB unavailable');return
end
local dir=vim.fn.tempname();vim.fn.mkdir(dir,'p')
local url,side='duckdb:'..dir..'/main.duckdb','duckdb:'..dir..'/side.duckdb'
local function fetch()
 local result,done
 db.get_completion_functions_async(url,function(v) result=v;done=true end)
 assert(vim.wait(10000,function()return done end,10),'native catalog did not finish')
 assert(result,'native catalog failed');return result
end
local function found(items,name)
 for _,it in ipairs(items)do if it.name==name then return true end end
end
test('NS01 attachment-only macro names are not offered as unqualified calls',function()
 assert(db.execute('CREATE MACRO completion_side_only(x) AS x+9; CREATE MACRO completion_side_rows(x) AS TABLE SELECT x AS item;',side))
 assert(db.execute('CREATE MACRO completion_local_only(x) AS x+1;',url))
 assert(not duck.attach(url,dir..'/side.duckdb','review_side'))
 local items=fetch()
 assert(not found(items,'completion_side_only') and not found(items,'completion_side_rows'),
   'attached-only macros emitted with unusable unqualified names')
end)
test('NS02 current-main macro and builtin controls remain discoverable',function()
 local items=fetch()
 assert(found(items,'completion_local_only') and found(items,'abs') and found(items,'range'),
   'namespace filtering removed current/builtin functions')
 local result,err=db.query('SELECT completion_local_only(1) AS value',url)
 assert(result and result.rows[1][1]=='2',err or 'local macro invocation changed')
end)
c.invalidate(url);duck.detach(url,'review_side');vim.fn.delete(dir,'rf')
print(string.format('completion_catalog_namespace_spec: %d passed, %d failed',pass,fail))
if fail>0 then os.exit(1)end
