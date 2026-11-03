-- Public refresh already queries Records: its view identity must agree.
local grip,view=require('dadbod-grip'),require('dadbod-grip.view')
local query,db=require('dadbod-grip.query'),require('dadbod-grip.db')
local root=vim.fn.tempname()..'_refresh_identity';vim.fn.mkdir(root,'p')
local file=root..'/fixture.sqlite';local url='sqlite:'..file
local saved={notify=vim.notify,keys=vim.deepcopy(grip._keymaps),query=db.query}
vim.notify=function()end
local pass,fail=0,0
local function native(sql)
 local r=vim.system({'sqlite3',file},{stdin=sql,text=true}):wait();assert(r.code==0,r.stderr)
end
local function clean()
 db.query=saved.query
 local bs={};for b in pairs(view._sessions)do bs[#bs+1]=b end
 for _,b in ipairs(bs)do pcall(vim.api.nvim_buf_delete,b,{force=true})end
end
local function open(hints)
 clean();native([[DROP TABLE IF EXISTS people;CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT);INSERT INTO people VALUES(1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');]])
 grip.setup({limit=2,show_hints=hints,completion=false,connections_path=root..'/connections.json'})
 grip.open('people',url,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b])
 assert(vim.wait(1000,function()return s._column_info~=nil end,5))
 s.on_requery(b,query.set_page(s.query_spec,3));return b,s
end
local function status(s)
 local r=s._render
 if r.status_items then local out={};for _,p in ipairs(r.status_items)do out[#out+1]=p[1]end;return table.concat(out,' ')end
 return r.lines[r.status_row+1]
end
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback);clean()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err)end
end
for _,hints in ipairs({true,false})do
 for _,facet in ipairs({'columns','indexes'})do
  test(facet..' public refresh publishes Records identity, hints '..tostring(hints),function()
   local b,s=open(hints);view.switch_view(b,facet);native("UPDATE people SET name='fresh' WHERE id=5")
   s.on_refresh(b)
   assert(s.state.rows[1][2]=='fresh','refresh did not keep native Records payload')
   assert(s.current_view=='records','metadata identity survived successful Records refresh')
   assert(not vim.api.nvim_buf_get_name(b):find('[',1,true),'metadata buffer name survived')
   assert(not s._render.lines[1]:find('Columns',1,true) and not s._render.lines[1]:find('Indexes',1,true),'metadata title survived')
   assert(status(s):find('Page 3/3',1,true) and status(s):find('5 rows',1,true),'Records pager absent')
   assert(s._meta_state==nil and s._records_state==s.state,'stale metadata/canonical payload retained')
   assert(s._render.read_state==s.state and s._render.read_metadata_view==nil,'displayed export snapshot changed')
   view.switch_view(b,facet);assert(s.current_view==facet and s._meta_state,'metadata cannot reopen')
   view.switch_view(b,'records');assert(s.state.rows[1][2]=='fresh','return restored stale Records')
  end)
 end
end
test('a second Records buffer cannot leave the refreshed name labeled as metadata',function()
 local b,s=open(true);view.switch_view(b,'columns')
 local peer=vim.api.nvim_create_buf(false,true);vim.api.nvim_buf_set_name(peer,'grip://people')
 s.on_refresh(b)
 local name=vim.api.nvim_buf_get_name(b)
 vim.api.nvim_buf_delete(peer,{force=true})
 assert(s.current_view=='records' and not name:find('[Columns]',1,true),'name collision retained metadata identity')
 assert(name:find('grip://people',1,true),'Records name lost source identity')
end)
test('failed refresh leaves metadata identity and displayed snapshot intact',function()
 local b,s=open(true);view.switch_view(b,'columns');local name=vim.api.nvim_buf_get_name(b);local meta=s._meta_state;local render=s._render
 native('DROP TABLE people');s.on_refresh(b)
 assert(s.current_view=='columns' and s._meta_state==meta and s._render==render and vim.api.nvim_buf_get_name(b)==name,'failed refresh changed visible identity')
end)
test('stale refresh cannot relabel the metadata result',function()
 local b,s=open(true);view.switch_view(b,'columns');local render=s._render;local name=vim.api.nvim_buf_get_name(b)
 db.query=function(sql,...)
  local result,err=saved.query(sql,...)
  if sql:find('SELECT *',1,true)then s._refresh_generation=s._refresh_generation+1 end
  return result,err
 end
 s.on_refresh(b)
 assert(s.current_view=='columns' and s._render==render and vim.api.nvim_buf_get_name(b)==name,'stale refresh changed identity')
end)
test('metadata refresh issues the same query sequence as Records refresh',function()
 local b,s=open(true);local records,metadata={},{};local target=records
 db.query=function(sql,...)target[#target+1]=sql;return saved.query(sql,...)end
 s.on_refresh(b);db.query=saved.query;view.switch_view(b,'columns')
 target=metadata;db.query=function(sql,...)target[#target+1]=sql;return saved.query(sql,...)end
 s.on_refresh(b);assert(vim.deep_equal(records,metadata),'metadata refresh added/changed DB queries: '..vim.inspect({records,metadata}))
end)
vim.notify=saved.notify;grip._keymaps=saved.keys;vim.fn.delete(root,'rf')
print(string.format('metadata_refresh_identity_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
