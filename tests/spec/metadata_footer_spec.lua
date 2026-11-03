local grip, view = require('dadbod-grip'), require('dadbod-grip.view')
local query = require('dadbod-grip.query')
local root = vim.fn.tempname() .. '_metadata_footer'; vim.fn.mkdir(root, 'p')
local file = root .. '/fixture.sqlite'; local url = 'sqlite:' .. file
local result = vim.system({'sqlite3',file},{stdin=[[CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT); INSERT INTO people VALUES(1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');]],text=true}):wait()
assert(result.code==0,result.stderr)
local pass, fail = 0, 0
local saved_notify = vim.notify; local notice
local saved_keys = vim.deepcopy(grip._keymaps)
vim.notify = function(s) notice=s end
local function cleanup()
 local buffers={};for b in pairs(view._sessions) do buffers[#buffers+1]=b end
 for _,b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete,b,{force=true}) end
end
local function test(name,fn)
 cleanup();local ok,err=xpcall(fn,debug.traceback);cleanup()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err) end
end
local function open(hints)
 grip.setup({limit=2,show_hints=hints,completion=false,connections_path=root..'/connections.json'})
 grip.open('people',url,{from_pad=true})
 local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b])
 s.on_requery(b,query.set_page(s.query_spec,3));return b,s
end
local function status(s)
 local r=s._render
 if r.status_items then
  local parts={};for _,item in ipairs(r.status_items) do parts[#parts+1]=item[1] end
  return table.concat(parts,' ')
 end
 return r.lines[r.status_row+1]
end
for _,hints in ipairs({true,false}) do
 for _,name in ipairs({'columns','indexes'}) do
  test(name..' footer shows its own count with hints '..tostring(hints),function()
   local b,s=open(hints);local spec=s.query_spec
   view.switch_view(b,name)
   local text=status(s);local count=#s._meta_state.rows
   assert(text:find(count..' rows',1,true),'metadata count absent: '..text)
   assert(not text:find('Page',1,true) and not text:find('→L',1,true) and not text:find('H←',1,true),'records paging leaked: '..text)
   assert(s.query_spec==spec and s.query_spec.page==3 and s.total_rows==5,'record paging state changed')
   view.switch_view(b,'records')
   assert(status(s):find('Page 3/3',1,true) and status(s):find('5 rows',1,true),'records footer not restored')
  end)
 end
end
for _,key in ipairs({'3','z3',false}) do
 test('repeat-view hint uses effective Records binding '..tostring(key),function()
  local b=open(true);grip._keymaps.tab_3=key
  view.switch_view(b,'columns');view.switch_view(b,'columns')
  assert(not notice:find('press 2',1,true),'wrong surface advertised')
  if key then assert(notice:find('press '..key..' for Records',1,true),'effective key absent')
  else assert(not notice:find('press ',1,true),'disabled key advertised') end
 end)
end
vim.notify=saved_notify;grip._keymaps=saved_keys;vim.fn.delete(root,'rf')
print(string.format('metadata_footer_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1) end
