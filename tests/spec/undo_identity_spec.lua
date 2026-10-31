local grip, view, db, data = require('dadbod-grip'), require('dadbod-grip.view'), require('dadbod-grip.db'), require('dadbod-grip.data')
local paths = require('dadbod-grip.paths')
local root=vim.fn.tempname(); vim.fn.mkdir(root,'p')
local oldroot, oldexpand, oldnotify, oldconfirm=paths.project_root,vim.fn.expand,vim.notify,vim.fn.confirm
paths.project_root=function() return root end
vim.fn.expand=function(s,...) if s=='~' then return root end return oldexpand(s,...) end
vim.notify=function() end; vim.fn.confirm=function() return 1 end
local url='sqlite:'..root..'/safety.db'
local pass,fail=0,0
local function test(name,fn) local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
local function exec(s) local r,e=db.execute(s,url);assert(r,e) end
local function rows(s) local r,e=db.query(s,url);assert(r,e);return r.rows end
local function open(t)
 for b in pairs(view._sessions) do view._sessions[b]=nil;pcall(vim.api.nvim_buf_delete,b,{force=true}) end
 grip.open(t,url,{from_pad=true});local b=vim.api.nvim_get_current_buf();return b,assert(view._sessions[b])
end
local function undo() local m=vim.fn.maparg(require('dadbod-grip.keymaps').get('grid_undo'),'n',false,true);m.callback() end
exec([[CREATE TABLE generated(id TEXT PRIMARY KEY NOT NULL DEFAULT(lower(hex(randomblob(16)))),value TEXT);INSERT INTO generated VALUES('zzzz','same'); CREATE TABLE moved(id INTEGER PRIMARY KEY,value TEXT);INSERT INTO moved VALUES(1,'before');CREATE TABLE ambiguous(id TEXT PRIMARY KEY,value TEXT);INSERT INTO ambiguous VALUES('','empty'),(NULL,'null');]])
test('generated Undo never guesses a pre-existing matching payload',function()
 local b,s=open('generated');s.on_clone(b,1);s.on_apply(b);undo()
 assert(rows("SELECT count(*) FROM generated WHERE id='zzzz'")[1][1]=='1','pre-existing row was deleted')
 assert(rows('SELECT count(*) FROM generated')[1][1]=='1','generated row was not reversed')
end)
test('edited-key Undo either reverses correctly or preserves its stack',function()
 local b,s=open('moved');view.apply_edit(b,data.add_change(s.state,1,'id','99'));s.on_apply(b);undo()
 assert(rows('SELECT id FROM moved')[1][1]=='1','key edit was not reversed')
end)
test('ambiguous empty/null key cannot target another row',function()
 local b,s=open('ambiguous')
 if not s.state.readonly then
  local idx;for i,r in ipairs(s.state.rows) do if r[2]=='empty' then idx=i end end
  view.apply_edit(b,data.add_change(s.state,idx,'value','changed'));s.on_apply(b)
 end
 assert(rows('SELECT value FROM ambiguous WHERE id IS NULL')[1][1]=='null','NULL-key row was changed')
 assert(rows("SELECT value FROM ambiguous WHERE id=''")[1][1]=='changed','empty key edit was not applied')
end)
for b in pairs(view._sessions) do view._sessions[b]=nil;pcall(vim.api.nvim_buf_delete,b,{force=true}) end
paths.project_root,vim.fn.expand,vim.notify,vim.fn.confirm=oldroot,oldexpand,oldnotify,oldconfirm
vim.fn.delete(root,'rf')
print(('undo_identity_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
