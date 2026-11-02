-- Independent provider protocol regression. This is not an installed-cmp UI test.
-- nvim-cmp source.lua282-291 reuses same-offset results unless isIncomplete;
-- response nil is coerced to {}, with isIncomplete=false (328-330).
-- Source: https://raw.githubusercontent.com/hrsh7th/nvim-cmp/main/lua/cmp/source.lua
-- Checked 2026-11-02. Actual Grip source dispatch; controlled metadata callbacks.
dofile('tests/minimal_init.lua')
local c,db=require('dadbod-grip.completion'),require('dadbod-grip.db')
local pass,fail=0,0
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err)end
end
local oldcmp,oldtypes=package.loaded.cmp,package.loaded['cmp.types']
local oldschema,oldfunctions=db.get_schema_batch_async,db.get_completion_functions_async
local oldbuf=vim.api.nvim_get_current_buf()
local buf=vim.api.nvim_create_buf(false,true);vim.api.nvim_set_current_buf(buf)
local registered,callbacks
package.loaded.cmp={register_source=function(_,source)registered=source end}
package.loaded['cmp.types']={lsp={CompletionItemKind={Field=5,Module=9,Function=3,Keyword=14}}}
db.get_schema_batch_async=function(_,cb)callbacks.schema=cb end
db.get_completion_functions_async=function(_,cb)callbacks.functions=cb end
c.register_cmp_source()
local index=0
local function cold(before)
 index=index+1; callbacks={}
 vim.b.db='duckdb:/synthetic/independent-cmp-cold-'..index..'.duckdb'
 vim.api.nvim_buf_set_lines(buf,0,-1,false,{before})
 local response
 registered:complete({context={cursor_before_line=before,bufnr=buf}},function(v)response=v end)
 assert(callbacks.functions,'cold provider did not start function warm')
 return response
end
test('CP01 nonempty partial result must permit same-token refetch',function()
 local result=cold('SELECT li')
 assert(result and #result.items>0,'keyword positive missing')
 assert(result.isIncomplete==true,'pending catalog advertised complete; nvim-cmp suppresses same-token refresh')
end)
test('CP02 empty cold result must permit same-token refetch',function()
 local result=cold('SELECT zz')
 assert(result and result.isIncomplete==true and #result.items==0,
   'nil/complete empty response prevents refresh after background warm')
end)
test('CP03 warmed direct provider positive retains function kind',function()
 cold('SELECT li')
 callbacks.functions({{name='list_sum',type='scalar'}});callbacks.schema({})
 local response
 registered:complete({context={cursor_before_line='SELECT lis',bufnr=buf}},function(v)response=v end)
 local found
 for _,it in ipairs(response.items or {})do if it.label=='list_sum(' then found=it end end
 assert(found and found.kind==3 and found.insertText=='list_sum(','warmed function compatibility lost')
end)
package.loaded.cmp,package.loaded['cmp.types']=oldcmp,oldtypes
db.get_schema_batch_async,db.get_completion_functions_async=oldschema,oldfunctions
vim.api.nvim_set_current_buf(oldbuf);vim.api.nvim_buf_delete(buf,{force=true})
print(string.format('completion_cmp_cold_spec: %d passed, %d failed',pass,fail))
if fail>0 then os.exit(1)end
