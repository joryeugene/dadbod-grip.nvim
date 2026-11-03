-- Labelled repaint-failure model: real SELECT succeeds, main-buffer paint fails.
-- Only disposable SQLite fixture setup writes to a database.
local grip,view,data,editor=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.data'),require('dadbod-grip.editor')
local root=vim.fn.tempname()..'_repaint_mutation';vim.fn.mkdir(root,'p');local file=root..'/fixture.sqlite';local url='sqlite:'..file
local oldnotify,oldeditor=vim.notify,editor.open;vim.notify=function()end
local pass,fail=0,0
local function close()editor.open=oldeditor;local a={};for b in pairs(view._sessions)do a[#a+1]=b end;for _,b in ipairs(a)do pcall(vim.api.nvim_buf_delete,b,{force=true})end end
local function native(sql)local r=vim.system({'sqlite3',file},{stdin=sql,text=true}):wait();assert(r.code==0,r.stderr);return vim.trim(r.stdout)end
local function press(b,key)for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n'))do if m.lhs==key then assert(m.callback)();return end end;error('missing '..key)end
local function open()
 close();native("DROP TABLE IF EXISTS people;CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT,team TEXT);INSERT INTO people VALUES(1,'Alice','red'),(2,'Bob','blue');")
 grip.setup({limit=5,completion=false,ai=false,connections_path=root..'/connections.json'})
 grip.open('people',url,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5));view.switch_view(b,'columns');return b,s
end
local function test(name,fn)local ok,e=xpcall(fn,debug.traceback);close();if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..e)end end
for _,key in ipairs({'i','d','o','c','x','column'})do
 test('healthy Columns refuses mutation '..key..' and retains its readable snapshot',function()
  local b,s=open();local before=s.state;local display=view.get_display_state(b);local lines=vim.api.nvim_buf_get_lines(b,0,-1,false)
  local opens=0;editor.open=function(_,_,save)opens=opens+1;save('SHOULD NOT STAGE')end
  local r=s._render;vim.api.nvim_win_set_cursor(0,{r.data_start,r.byte_positions[1][r.visible_columns[1]].start})
  if key=='column'then view._column_set(b)else press(b,key)end
  assert(not view._is_editable(s) and opens==0 and s.state==before and not data.has_changes(s.state),'healthy metadata allowed mutation')
  assert(view.get_display_state(b)==display and display.columns[1]=='column_name','metadata read context changed')
  assert(vim.deep_equal(lines,vim.api.nvim_buf_get_lines(b,0,-1,false)),'metadata pixels changed')
  assert(native('SELECT group_concat(name) FROM people')=='Alice,Bob','native data changed')
 end)
end
test('successful refreshed Records still permits ordinary cell edit',function()
 local b,s=open();press(b,'r');local save;editor.open=function(_,_,cb)save=cb end
 local r=s._render;vim.api.nvim_win_set_cursor(0,{r.data_start,r.byte_positions[1].name.start});press(b,'i')
 assert(save,'successful refreshed Records became noneditable');save('valid stage')
 assert(data.effective_value(s.state,1,'name')=='valid stage' and data.has_changes(s.state),'normal edit did not stage')
 assert(native('SELECT group_concat(name) FROM people')=='Alice,Bob','staging unexpectedly wrote database')
end)
close();vim.notify=oldnotify;vim.fn.delete(root,'rf');print(string.format('metadata_mutation_guard_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
