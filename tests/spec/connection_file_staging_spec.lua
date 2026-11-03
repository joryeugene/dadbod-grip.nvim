-- Approved compatibility boundary: staged work -> file profile refuses before any preflight.
local grip,view,data,connections,db,ui=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.data'),require('dadbod-grip.connections'),require('dadbod-grip.db'),require('dadbod-grip.ui')
local root=vim.fn.tempname()..'_file_switch';vim.fn.mkdir(root,'p')
local sqlite=root..'/fixture.sqlite';local url='sqlite:'..sqlite;local csv=root..'/file.csv';local registry=root..'/connections.json'
local r=vim.system({'sqlite3',sqlite},{stdin="CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT);INSERT INTO people VALUES(1,'one');",text=true}):wait();assert(r.code==0,r.stderr)
vim.fn.writefile({'id,name','1,alpha','2,beta'},csv)
vim.fn.writefile({vim.json.encode({{name='Old',url=url,type='sqlite',last_used=1},{name='File',url=csv,type='file',last_used=2}})},registry)
grip.setup({open_sidebar=false,completion=false,ai=false,discovery=false,connections_path=registry})
local pass,fail=0,0
local function bytes(p)return table.concat(vim.fn.readfile(p,'b'),'\n')end
local function close()local a={};for b in pairs(view._sessions)do a[#a+1]=b end;for _,b in ipairs(a)do pcall(vim.api.nvim_buf_delete,b,{force=true})end end
local function test(name,fn)close();local ok,e=xpcall(fn,debug.traceback);close();if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..e)end end
test('staged file switch refuses with zero prompt/preflight and unchanged work',function()
 vim.g.db=url;grip.open('people',url,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5))
 view.apply_edit(b,data.add_change(s.state,1,'name','pending'));local original=s.state;local old_registry=bytes(registry);local original_mode=connections.current_mode(csv)
 local oldquery,oldconfirm=db.query,ui.confirm;local requests,prompts=0,0
 db.query=function(...)requests=requests+1;return oldquery(...)end;ui.confirm=function()prompts=prompts+1;return true end
 local ok,err=pcall(connections.switch,csv,'File','file');vim.wait(300,function()return false end,10);db.query,ui.confirm=oldquery,oldconfirm;assert(ok,err)
 assert(prompts==0 and requests==0,'file containment attempted prompt or DB preflight')
 assert(view._sessions[b]==s and s.state==original and data.has_changes(s.state),'file refusal lost staging')
 assert(vim.g.db==url and bytes(registry)==old_registry and connections.current_mode(csv)==original_mode,'file refusal mutated active/registry/mode state')
end)
test('unstaged file profile still opens native CSV',function()
 vim.g.db=url;local old=ui.confirm;local prompts=0;ui.confirm=function()prompts=prompts+1;return false end
 local ok,err=pcall(connections.switch,csv,'File','file');local opened=vim.wait(3000,function()for _,s in pairs(view._sessions)do if s.state.rows[1] and s.state.rows[1][2]=='alpha'then return true end end;return false end,10);ui.confirm=old
 assert(ok,err);assert(opened,'no-stage CSV file profile no longer opens');assert(prompts==0,'clean file switch asks to discard')
end)
close();vim.fn.delete(root,'rf');print(string.format('file_switch_control: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
