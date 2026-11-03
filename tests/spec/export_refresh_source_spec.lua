-- A public refresh can repaint Records while a metadata facet was active.
-- Export must follow the actual visible data or refuse; it must not select a different snapshot.
local grip,view,ui=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.ui')
local root=vim.fn.tempname()..'_refresh_export';vim.fn.mkdir(root,'p');local file=root..'/fixture.sqlite'
local r=vim.system({'sqlite3',file},{stdin="CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT,team TEXT);INSERT INTO people VALUES(1,'Alice','red'),(2,'Bob','blue');",text=true}):wait();assert(r.code==0,r.stderr)
grip.setup({limit=5,completion=false,ai=false,connections_path=root..'/connections.json'})
grip.open('people','sqlite:'..file,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5))
view.switch_view(b,'columns');local before_meta=s._meta_state
for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n'))do if m.lhs=='r'then assert(m.callback)();break end end
local columns=s._render.visible_columns
assert(columns[1]=='id' and s.state.columns[1]=='id' and #s.state.rows==2,'native refreshed Records fixture changed')
local path=root..'/result.csv';vim.fn.writefile({'KEEP EXISTING'},path)
local oldselect,oldinput,oldnotify=vim.ui.select,ui.input,vim.notify;local step=0;local notices={}
vim.ui.select=function(_,_,cb)cb('Current page')end;ui.input=function()step=step+1;return step==1 and'csv'or path end;vim.notify=function(v)notices[#notices+1]=tostring(v)end
local ok,err=pcall(view.do_export,b);vim.ui.select,ui.input,vim.notify=oldselect,oldinput,oldnotify;assert(ok,err)
local lines=vim.fn.readfile(path);local unchanged=table.concat(lines,'\n')=='KEEP EXISTING'
if unchanged then assert(#notices>0,'stale displayed-source refusal has no explanation')
else assert(lines[1]==table.concat(columns,',') and lines[2]=='1,Alice,red' and lines[3]=='2,Bob,blue' and #lines==3,'export disagrees with the actual refreshed visible result')end
assert(s._meta_state==before_meta,'export itself altered metadata state')
vim.api.nvim_buf_delete(b,{force=true});vim.fn.delete(root,'rf');print('export_refresh_source_spec: 1 passed, 0 failed')
