-- Filmed regression: page turns must not leave an active data cursor on a border.
local grip, view = require('dadbod-grip'), require('dadbod-grip.view')
local query, data = require('dadbod-grip.query'), require('dadbod-grip.data')
local ui, paths = require('dadbod-grip.ui'), require('dadbod-grip.paths')
local root = vim.fn.tempname() .. '_page_cursor'; vim.fn.mkdir(root, 'p')
local file = root .. '/fixture.sqlite'; local url = 'sqlite:' .. file
local oldroot, oldconfirm, oldnative, oldnotify = paths.project_root, ui.confirm, vim.fn.confirm, vim.notify
paths.project_root = function() return root end
ui.confirm, vim.fn.confirm, vim.notify = function() return true end, function() return 1 end, function() end
grip.setup({limit=2,completion=false,connections_path=root .. '/connections.json'})
local pass, fail = 0, 0
local function native(sql)
 local result=vim.system({'sqlite3',file},{stdin=sql,text=true}):wait()
 assert(result.code==0,result.stderr);return vim.trim(result.stdout)
end
local function cleanup()
 local buffers={};for b in pairs(view._sessions) do buffers[#buffers+1]=b end
 for _,b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete,b,{force=true}) end
end
local function open()
 cleanup();native([[DROP TABLE IF EXISTS people; CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT); INSERT INTO people VALUES(1,'one'),(2,'two'),(3,'three'),(4,'four'),(5,'five');]])
 grip.open('people',url,{from_pad=true})
 local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b])
 assert(vim.wait(1000,function()return s._column_info~=nil end,5))
 s.on_requery(b,query.toggle_sort(s.query_spec,'id'));return b,s
end
local function press(b,lhs)
 for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n')) do if m.lhs==lhs then assert(m.callback)();return end end
 error('missing mapping '..lhs)
end
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback);cleanup()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err) end
end
test('last-page navigation retains a selectable row and actual Delete Apply Undo works',function()
 local b,s=open();local r=s._render
 vim.api.nvim_win_set_cursor(0,{r.data_start+1,r.byte_positions[2].name.start})
 press(b,']P');assert(s.query_spec.page==3)
 local cell=view.get_cell(b);assert(cell and cell.row_idx==1 and cell.col_name=='name','page turn landed off a data cell')
 press(b,'d');assert(data.has_changes(s.state),'Delete from landed cursor did not stage')
 s.on_apply(b);assert(native('SELECT COUNT(*) FROM people')=='4','native deletion failed')
 assert(s.query_spec.page==2 and #s.state.rows==2,'last-page deletion did not clamp')
 press(b,'u');assert(native('SELECT COUNT(*) FROM people')=='5','native Undo failed')
end)
test('refresh shrinking rows keeps an existing data cursor usable',function()
 local b,s=open();local r=s._render
 vim.api.nvim_win_set_cursor(0,{r.data_start+1,r.byte_positions[2].id.start})
 native('DELETE FROM people WHERE id<>1');s.on_refresh(b)
 assert(view.get_cell(b) and view.get_cell(b).row_idx==1,'refresh left cursor on footer')
end)
test('header inspection is not moved into data by a render',function()
 local b,s=open();vim.api.nvim_win_set_cursor(0,{2,4})
 view.render(b,s.state);assert(vim.api.nvim_win_get_cursor(0)[1]==2,'header cursor moved')
end)
test('empty refresh never invents an editable row',function()
 local b,s=open();local r=s._render
 vim.api.nvim_win_set_cursor(0,{r.data_start,r.byte_positions[1].id.start})
 native('DELETE FROM people');s.on_refresh(b)
 assert(#s.state.rows==0 and view.get_cell(b)==nil,'empty result became a data cell')
end)
cleanup();paths.project_root,ui.confirm,vim.fn.confirm,vim.notify=oldroot,oldconfirm,oldnative,oldnotify
vim.fn.delete(root,'rf')
print(string.format('page_cursor_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1) end
