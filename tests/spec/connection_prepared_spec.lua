-- Native metadata and modelled race/transport seams; disposable databases only.
local grip,view,data,ui=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.data'),require('dadbod-grip.ui')
local db,schema,connections=require('dadbod-grip.db'),require('dadbod-grip.schema'),require('dadbod-grip.connections')
local root=vim.fn.tempname()..'_prepared_connection';vim.fn.mkdir(root,'p')
local oldurl,newurl='sqlite:'..root..'/old.sqlite','sqlite:'..root..'/new.sqlite'
for _,name in ipairs({'old','new'})do
 local out=vim.system({'sqlite3',root..'/'..name..'.sqlite'},{stdin="CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT);INSERT INTO people VALUES(1,'one'),(2,'two');",text=true}):wait();assert(out.code==0,out.stderr)
end
local pass,fail=0,0
local saved={opts=grip.get_opts(),confirm=ui.confirm,notify=vim.notify,db=vim.g.db,tables=db.list_tables,routines=db.list_routines}
local registry=root..'/connections.json'
local function cleanup()
 db.list_tables,db.list_routines=saved.tables,saved.routines
 schema.close();local buffers={};for b in pairs(view._sessions)do buffers[#buffers+1]=b end
 for _,b in ipairs(buffers)do pcall(vim.api.nvim_buf_delete,b,{force=true})end
 view.close_all_floats()
end
local function bytes()return table.concat(vim.fn.readfile(registry,'b'),'\n')end
local function open()
 cleanup();schema._reset_state()
 vim.fn.writefile({vim.json.encode({{name='Old',url=oldurl,type='sqlite',last_used=1},{name='Target',url=newurl,type='sqlite',last_used=2}})},registry)
 grip.setup({open_sidebar=true,completion=false,ai=false,discovery=false,connections_path=registry})
 ui.confirm=function()return true end;vim.notify=function()end;vim.g.db=oldurl
 schema.toggle(oldurl);grip.open('people',oldurl,{from_pad=true})
 local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5))
 view.apply_edit(b,data.add_change(s.state,1,'name','pending'));return b,s,bytes()
end
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback);cleanup()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..err)end
end
test('decline performs no target lookup',function()
 local b,s,original=open();local state=s.state;local calls=0
 db.list_tables=function(url,...)if url==newurl then calls=calls+1 end;return saved.tables(url,...)end
 ui.confirm=function()return false end
 assert(connections.switch(newurl,'Target','sqlite')==false)
 assert(calls==0 and s.state==state and view._sessions[b]==s and bytes()==original and vim.g.db==oldurl)
end)
test('accepted target uses one table read despite a poisoned second read',function()
 local _,_,original=open();local calls=0
 db.list_tables=function(url,...)
  if url==newurl then calls=calls+1;if calls>1 then return nil,'controlled second required query failure' end end
  return saved.tables(url,...)
 end
 assert(connections.switch(newurl,'Target','sqlite')==true)
 vim.wait(100,function()return false end,5)
 assert(calls==1,'workspace repeated target metadata query')
 assert(vim.g.db==newurl and bytes()~=original)
 assert(vim.b[vim.api.nvim_win_get_buf(schema.get_winid())].db==newurl,'sidebar did not show accepted target')
 for _,s in pairs(view._sessions)do assert(not data.has_changes(s.state),'accepted discard kept old staging')end
end)
test('failed first required read retains staging and registry',function()
 local b,s,original=open();local state=s.state
 db.list_tables=function(url,...)if url==newurl then return nil,'controlled target query failure' end;return saved.tables(url,...)end
 assert(connections.switch(newurl,'Target','sqlite')==false)
 assert(view._sessions[b]==s and s.state==state and data.has_changes(state) and bytes()==original and vim.g.db==oldurl)
end)
test('schema invalidation during preparation cannot admit stale metadata',function()
 local b,s,original=open();local state=s.state
 db.list_routines=function(url,...)if url==newurl then schema.invalidate(url) end;return saved.routines(url,...)end
 assert(connections.switch(newurl,'Target','sqlite')==false)
 assert(view._sessions[b]==s and s.state==state and bytes()==original and vim.g.db==oldurl)
end)
test('new staging while a target read completes invalidates prior consent',function()
 local b,s,original=open()
 db.list_tables=function(url,...)
  if url==newurl then view.apply_edit(b,data.add_change(s.state,1,'name','newer edit')) end
  return saved.tables(url,...)
 end
 assert(connections.switch(newurl,'Target','sqlite')==false)
 assert(view._sessions[b]==s and data.effective_value(s.state,1,'name')=='newer edit' and bytes()==original and vim.g.db==oldurl)
end)
test('forged or invalidated UI receipts cannot repopulate schema',function()
 open()
 assert(schema.use_prepared_switch(newurl,{})==nil)
 local token=assert(schema.prepare_switch(newurl));schema.invalidate(newurl)
 assert(schema.use_prepared_switch(newurl,token)==nil)
 assert(schema.get_state(newurl).items==nil)
end)
cleanup();grip.setup(saved.opts);ui.confirm,vim.notify,vim.g.db=saved.confirm,saved.notify,saved.db;vim.fn.delete(root,'rf')
print(string.format('connection_prepared_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
