-- Deferred UI callbacks cannot silently change the selected export source.
local view,data=require('dadbod-grip.view'),require('dadbod-grip.data')
local old_select,old_notify=vim.ui.select,vim.notify
local pass,fail=0,0
local function test(name,fn)local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..tostring(e))end end
local function session()
 local state=data.new({columns={'id'},rows={{'1'}},primary_keys={'id'},table_name='people'})
 return {state=state,current_view='columns',_meta_state={columns={'column_name'},rows={{'id'}}},_render={ordered={1}}}
end
local pending,notice
vim.ui.select=function(_,_,cb)pending=cb end;vim.notify=function(s)notice=s end
test('metadata changed to Records while choosing scope refuses',function()
 local s=session();local delivered=false;view._request_export_rows(s,'file',function()delivered=true end)
 s.current_view='records';pending('Current page');assert(not delivered and notice:find('visible result changed',1,true))
end)
test('replaced metadata snapshot refuses without canonical query',function()
 local s=session();local delivered=false;view._request_export_rows(s,'file',function()delivered=true end)
 s._meta_state={columns={'other'},rows={{'other'}}};pending('All matching rows');assert(not delivered and notice:find('visible result changed',1,true))
end)
test('cancel has no callback or notification',function()
 local s=session();local delivered=false;notice=nil;view._request_export_rows(s,'file',function()delivered=true end)
 pending(nil);assert(not delivered and notice==nil)
end)
vim.ui.select,vim.notify=old_select,old_notify
print(string.format('export_scope_ownership_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
