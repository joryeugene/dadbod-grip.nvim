-- Live matrix: GRIP_SAFETY_URL must point only at a task-owned disposable DB.
local grip, db, view, data = require('dadbod-grip'), require('dadbod-grip.db'), require('dadbod-grip.view'), require('dadbod-grip.data')
local paths, adapters, sql = require('dadbod-grip.paths'), require('dadbod-grip.adapters'), require('dadbod-grip.sql')
local root=vim.fn.tempname();vim.fn.mkdir(root,'p')
local oldroot, oldexpand, oldnotify, oldconfirm = paths.project_root,vim.fn.expand,vim.notify,vim.fn.confirm
local opts=grip.get_opts()
paths.project_root=function() return root end
vim.fn.expand=function(s,...) if s=='~' then return root end return oldexpand(s,...) end
local editor=require("dadbod-grip.editor")
local real_error=editor.show_error
local notices={};editor.show_error=function(title,lines) notices[#notices+1]=table.concat(lines,"\n");real_error(title,lines) end
vim.notify=function(s) notices[#notices+1]=s end;vim.fn.confirm=function() return 1 end
grip.setup({discovery=false,open_sidebar=false,timeout=10000})
local url=vim.env.GRIP_SAFETY_URL or ('sqlite:'..root..'/test.db')
local kind=adapters.kind(url)
local maria=url:match('^mariadb:')~=nil
local pass,fail=0,0
local prefix='grip_safe_'..vim.fn.getpid()..'_'
local created={}
local function exec(s) local r,e=db.execute(s,url);assert(r,e);return r end
local function rows(s) local r,e=db.query(s,url);assert(r,e);return r.rows end
local function scalar(s) return rows(s)[1][1] end
local function test(name,fn) notices={};local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)..' notices='..vim.inspect(notices)) end end
local function table_(name,definition)
 local t=prefix..name;exec('CREATE TABLE '..sql.quote_ident(t)..' ('..definition..')');created[#created+1]=t;return t
end
local function cleanup()
 for b in pairs(view._sessions) do view._sessions[b]=nil;pcall(vim.api.nvim_buf_delete,b,{force=true}) end
 for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative~='' then pcall(vim.api.nvim_win_close,w,true) end end
end
local function open(t)
 cleanup();grip.open(t,url,{from_pad=true});local b=vim.api.nvim_get_current_buf()
 local session=assert(view._sessions[b],'grid not opened')
 -- Quiesce the existing asynchronous column-info callback in this fixture;
 -- cross-process DuckDB query scheduling is a separately scoped limitation.
 vim.wait(1000,function() return session._column_info~=nil end,1)
 return b,session
end
local function undo(b)
 vim.api.nvim_set_current_win(vim.fn.bufwinid(b))
 for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n')) do if m.lhs=='u' then m.callback();return end end
 error('Undo mapping missing')
end
local function apply(b,s) s.on_apply(b);assert(#(s._txn_undo_stack or {})>0,'write did not establish verified Undo') end

test('NULL empty literal NULL and exact numeric/JSON spelling',function()
 local t=table_('typed','id INTEGER PRIMARY KEY, v TEXT')
 exec('INSERT INTO '..t.." VALUES(1,NULL),(2,''),(3,'NULL'),(4,'9007199254740993'),(5,'{\"x\":9007199254740993,\"x\":2}')")
 local r=rows('SELECT v FROM '..t..' ORDER BY id')
 assert(r[1][1]==vim.NIL,'NULL: '..vim.inspect(r));assert(r[2][1]=='','empty: '..vim.inspect(r));assert(r[3][1]=='NULL','literal: '..vim.inspect(r));assert(r[4][1]=='9007199254740993','big: '..vim.inspect(r));assert(r[5][1]=='{"x":9007199254740993,"x":2}','JSON: '..vim.inspect(r))
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,2,'v','changed'));apply(b,s);undo(b)
 assert(scalar('SELECT v FROM '..t..' WHERE id=2')=='','Undo lost empty text')
end)
test('boolean values use the same spelling in guards as in fetched rows',function()
 local t=table_('boolean','id INTEGER PRIMARY KEY,flag BOOLEAN,v TEXT')
 exec('INSERT INTO '..t.." VALUES(1,TRUE,'before')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','ours'));apply(b,s);undo(b)
 assert(scalar('SELECT v FROM '..t)=='before')
end)
if kind=='duckdb' then
 test('nested JSON transport stays consistent with guarded snapshots',function()
  local t=table_('nested','id INTEGER PRIMARY KEY,nested STRUCT(x BIGINT,y VARCHAR),v VARCHAR')
  exec('INSERT INTO '..t.." VALUES(1,{'x':9007199254740993,'y':'literal'},'before')")
  local b,s=open(t);local original=s.state.rows[1][2]
  view.apply_edit(b,data.add_change(s.state,1,'v','ours'));apply(b,s);undo(b)
  assert(scalar('SELECT nested FROM '..t)==original);assert(scalar('SELECT v FROM '..t)=='before')
 end)
end
if kind=='sqlite' then
 test('NUL text key cannot impersonate a separate empty key',function()
  local t=table_('nul_key','id TEXT PRIMARY KEY,v TEXT')
  exec('INSERT INTO '..t.." VALUES(CAST(X'004e554c4c00' AS TEXT),'nul'),('','empty')")
  local b,s=open(t);local idx;for i,r in ipairs(s.state.rows) do if r[2]=='nul' then idx=i end end
  view.apply_edit(b,data.add_change(s.state,idx,'v','ours'));apply(b,s)
  assert(scalar('SELECT v FROM '..t.." WHERE id=''")=='empty');undo(b)
  assert(scalar('SELECT v FROM '..t.." WHERE hex(id)='004E554C4C00'")=='nul')
 end)
 test('quoted and dotted key/column names remain exact identifiers',function()
  local t=table_('identifiers','"key.dot" TEXT PRIMARY KEY,"quote""name" TEXT')
  exec('INSERT INTO '..t.." VALUES('one','before')")
  local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'quote"name','ours'));apply(b,s);undo(b)
  assert(scalar('SELECT "quote""name" FROM '..t)=='before')
 end)
end
test('WHERE inside text survives Apply and committed Undo',function()
 local t=table_('where_literal','id INTEGER PRIMARY KEY,v TEXT')
 exec('INSERT INTO '..t.." VALUES(1,'before WHERE original')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','plain WHERE text'));apply(b,s)
 assert(scalar('SELECT v FROM '..t)=='plain WHERE text');undo(b)
 assert(scalar('SELECT v FROM '..t)=='before WHERE original')
end)
if kind=='sqlite' then
 test('Undo does not change an untouched BLOB storage class',function()
  local t=table_('blob','id INTEGER PRIMARY KEY,payload TEXT,bytes BLOB')
  exec('INSERT INTO '..t.." VALUES(1,'before',X'4142')")
  local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'payload','ours'));apply(b,s);undo(b)
  assert(scalar("SELECT typeof(bytes)||':'||hex(bytes) FROM "..t)=='blob:4142')
 end)
 test('Undo preserves untyped integer key and payload storage classes',function()
  local t=table_('untyped','id PRIMARY KEY,payload TEXT,n')
  exec('INSERT INTO '..t.." VALUES(1,'before',42)")
  local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'payload','ours'));apply(b,s);undo(b)
  assert(scalar("SELECT typeof(id)||':'||typeof(n) FROM "..t)=='integer:integer')
 end)
 test('DELETE Undo reinserts BLOBs with their exact original storage type',function()
  local t=table_('blob_delete','id INTEGER PRIMARY KEY,bytes BLOB')
  exec('INSERT INTO '..t.." VALUES(1,X'0041FF')")
  local b,s=open(t);s.on_delete(b,1);apply(b,s);undo(b)
  assert(scalar("SELECT typeof(bytes)||':'||hex(bytes) FROM "..t)=='blob:0041FF')
 end)
 test('clone preserves actual BLOB and untyped numeric storage',function()
  local t=table_('typed_clone','id INTEGER PRIMARY KEY,bytes TEXT,n,r')
  exec('INSERT INTO '..t.." VALUES(1,X'0041FF',9007199254740993,1.2345678901234567)")
  local before=scalar("SELECT typeof(bytes)||':'||hex(bytes)||':'||typeof(n)||':'||n||':'||typeof(r)||':'||printf('%!.26g',r) FROM "..t)
  local b,s=open(t);s.on_clone(b,1);apply(b,s)
  assert(scalar("SELECT typeof(bytes)||':'||hex(bytes)||':'||typeof(n)||':'||n||':'||typeof(r)||':'||printf('%!.26g',r) FROM "..t..' WHERE id=2')==before)
  undo(b);assert(scalar('SELECT count(*) FROM '..t)=='1')
 end)
 test('delete and Undo preserve infinite and subnormal REAL values',function()
  local t=table_('real_edges','id INTEGER PRIMARY KEY,r')
  exec('INSERT INTO '..t..' VALUES(1,1e999),(2,-1e999),(3,4.9406564584124654e-324)')
  local before=rows("SELECT typeof(r),printf('%!.26g',r) FROM "..t..' ORDER BY id')
  local b,s=open(t);s.on_delete(b,1);s.on_delete(b,2);s.on_delete(b,3);apply(b,s);undo(b)
  assert(vim.deep_equal(rows("SELECT typeof(r),printf('%!.26g',r) FROM "..t..' ORDER BY id'),before))
 end)
 test('concurrent same-byte TEXT to BLOB change conflicts',function()
  local t=table_('type_conflict','id INTEGER PRIMARY KEY,payload')
  exec('INSERT INTO '..t.." VALUES(1,'before')")
  local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'payload','ours'));apply(b,s)
  exec('UPDATE '..t.." SET payload=X'6F757273' WHERE id=1");undo(b)
  assert(scalar("SELECT typeof(payload)||':'||hex(payload) FROM "..t)=='blob:6F757273')
  assert(#s._txn_undo_stack==1)
 end)
 test('same-byte BLOB and TEXT keys remain separate identities',function()
  local t=table_('typed_keys','id PRIMARY KEY,payload TEXT')
  exec('INSERT INTO '..t.." VALUES(X'4142','same'),('AB','same')")
  local b,s=open('SELECT id,payload FROM '..t.." WHERE typeof(id)='text'")
  view.apply_edit(b,data.add_change(s.state,1,'payload','ours'));apply(b,s)
  assert(scalar('SELECT payload FROM '..t.." WHERE typeof(id)='blob'")=='same')
  assert(scalar('SELECT payload FROM '..t.." WHERE typeof(id)='text'")=='ours');undo(b)
  assert(scalar('SELECT count(*) FROM '..t.." WHERE payload='same'")=='2')
 end)
 test('staged SQL preview retains actual binary key identity',function()
  local t=table_('typed_preview','id PRIMARY KEY,payload TEXT')
  exec('INSERT INTO '..t.." VALUES(X'4142','blob'),('AB','text')")
  local b,s=open(t);local idx;for i,row in ipairs(s.state.rows) do if row[2]=='blob' then idx=i end end
  view.apply_edit(b,data.add_change(s.state,idx,'payload','ours'))
  local preview=sql.preview_staged(t,data.get_updates(s.state),{},{});exec(preview)
  assert(scalar('SELECT payload FROM '..t.." WHERE typeof(id)='blob'")=='ours')
  assert(scalar('SELECT payload FROM '..t.." WHERE typeof(id)='text'")=='text')
 end)
 test('SQL export retains actual BLOB and untyped numeric storage',function()
  local t=table_('typed_export','id PRIMARY KEY,bytes,n,r')
  local dest=table_('typed_export_copy','id PRIMARY KEY,bytes,n,r')
  exec('INSERT INTO '..t.." VALUES(1,X'0041FF',9007199254740993,1.2345678901234567)")
  local _,s=open(t)
  exec(table.concat(view._format_export(s.state.rows,s.state.columns,'sql',dest,s.state),'\n'))
  local expression="typeof(id)||':'||typeof(bytes)||':'||hex(bytes)||':'||typeof(n)||':'||n||':'||typeof(r)||':'||printf('%!.26g',r)"
  assert(scalar('SELECT '..expression..' FROM '..dest)==scalar('SELECT '..expression..' FROM '..t))
 end)
end
test('PK edits reverse via post-write identity',function()
 local t=table_('moved','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'id','99'));apply(b,s);undo(b)
 assert(scalar('SELECT id FROM '..t)=='1','PK Undo missed its row');assert(#s._txn_undo_stack==0)
end)
test('conflicted Undo preserves external changes and stack',function()
 local t=table_('conflict','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','ours'));apply(b,s)
 exec('UPDATE '..t.." SET v='external' WHERE id=1");undo(b)
 assert(scalar('SELECT v FROM '..t)=='external');assert(#s._txn_undo_stack==1)
end)
test('multiple explicit inserts reverse atomically with duplicate payloads',function()
 local t=table_('multi','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'same')")
 local b,s=open(t)
 view.apply_edit(b,data.insert_row_with_values(s.state,1,{id='2',v='same'}))
 view.apply_edit(b,data.insert_row_with_values(s.state,1,{id='3',v='same'}));apply(b,s)
 exec('INSERT INTO '..t.." VALUES(4,'same')");undo(b)
 assert(scalar('SELECT count(*) FROM '..t)=='2');assert(scalar('SELECT count(*) FROM '..t..' WHERE id IN(1,4)')=='2')
end)
test('generated identities captured in the original write session',function()
 local definition
 if kind=='sqlite' then definition='id TEXT PRIMARY KEY NOT NULL DEFAULT(lower(hex(randomblob(16)))),v TEXT'
 elseif kind=='postgresql' then definition='id TEXT PRIMARY KEY DEFAULT md5(random()::text),v TEXT'
 elseif kind=='duckdb' then definition='id VARCHAR PRIMARY KEY DEFAULT (CAST(uuid() AS VARCHAR)),v VARCHAR'
 elseif maria then definition='id VARCHAR(64) PRIMARY KEY DEFAULT (uuid()),v TEXT'
 else definition='id BIGINT PRIMARY KEY AUTO_INCREMENT,v TEXT' end
 local t=table_('generated',definition)
 local old=kind=='mysql' and not maria and '999999' or 'zzzz'
 exec('INSERT INTO '..t..' VALUES('..sql.quote_value(old)..",'same')")
 local b,s=open(t);s.on_clone(b,1);apply(b,s)
 assert(scalar('SELECT count(*) FROM '..t)=='2');undo(b)
 assert(scalar('SELECT count(*) FROM '..t)=='1');assert(scalar('SELECT id FROM '..t)==old)
end)
test('composite PK edits restore all original fields',function()
 local t=table_('composite','a INTEGER,b INTEGER,v TEXT,PRIMARY KEY(a,b)')
 exec('INSERT INTO '..t.." VALUES(1,2,'before'),(1,3,'sibling')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'b','22'));apply(b,s);undo(b)
 assert(scalar('SELECT v FROM '..t..' WHERE a=1 AND b=2')=='before')
 assert(scalar('SELECT v FROM '..t..' WHERE a=1 AND b=3')=='sibling')
end)
test('zero-effect Undo preserves stack without claiming success',function()
 local t=table_('missing','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','ours'));apply(b,s)
 exec('DELETE FROM '..t..' WHERE id=1');notices={};undo(b)
 assert(#s._txn_undo_stack==1);assert(scalar('SELECT count(*) FROM '..t)=='0')
 for _,notice in ipairs(notices) do assert(not notice:find('Undid transaction',1,true),'false success') end
end)
test('conflicted multi-row reversal rolls every earlier reversal back',function()
 local t=table_('atomic','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'one'),(2,'two')")
 local b,s=open(t)
 view.apply_edit(b,data.add_change(s.state,1,'v','ours-one'))
 view.apply_edit(b,data.add_change(s.state,2,'v','ours-two'));apply(b,s)
 local first=s._txn_undo_stack[1].ops[1].keys.id
 local other=first=='1' and '2' or '1'
 exec('UPDATE '..t.." SET v='external' WHERE id="..other);undo(b)
 assert(scalar('SELECT v FROM '..t..' WHERE id='..first)=='ours-'..(first=='1' and 'one' or 'two'))
 assert(scalar('SELECT v FROM '..t..' WHERE id='..other)=='external');assert(#s._txn_undo_stack==1)
end)
test('deletion Undo restores empty NULL literal and unprojected data',function()
 local t=table_('deleted','id INTEGER PRIMARY KEY,v TEXT,n TEXT,lit TEXT')
 exec('INSERT INTO '..t.." VALUES(1,'',NULL,'NULL')")
 local b,s=open('SELECT id, v FROM '..t);s.on_delete(b,1);apply(b,s);undo(b)
 local r=rows('SELECT v,n,lit FROM '..t)[1]
 assert(r[1]=='');assert(r[2]==vim.NIL);assert(r[3]=='NULL')
end)
test('stale forward edits cannot overwrite concurrent changes',function()
 local t=table_('stale','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
 local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','ours'))
 exec('UPDATE '..t.." SET v='external' WHERE id=1");s.on_apply(b)
 assert(scalar('SELECT v FROM '..t)=='external');assert(data.has_changes(s.state));assert(#(s._txn_undo_stack or {})==0)
end)
if kind=='mysql' then
 test('case and trailing-space changes conflict under a case-insensitive collation',function()
  local t=table_('collation','id INTEGER PRIMARY KEY,v VARCHAR(64) COLLATE utf8mb4_general_ci')
  exec('INSERT INTO '..t.." VALUES(1,'before')")
  for _,external in ipairs({'foo','Foo '}) do
   exec('UPDATE '..t.." SET v='before' WHERE id=1")
   local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','Foo'));apply(b,s)
   exec('UPDATE '..t..' SET v='..sql.quote_value(external)..' WHERE id=1');undo(b)
   assert(scalar('SELECT HEX(v) FROM '..t)==(external=='foo' and '666F6F' or '466F6F20'))
   assert(#s._txn_undo_stack==1)
  end
 end)
end
if kind=='sqlite' then
 for _,operation in ipairs({'Apply','Undo'}) do
  test('fault model: a pre-write SELECT cannot settle a later uncertain '..operation,function()
   local t=table_('old_select_'..operation:lower(),'id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
   local b,s=open(t);s.on_clone(b,1)
   if operation=='Undo' then apply(b,s) end
   local state=s.state
   local run,nested,writes=adapters.run_cmd,false,0
   adapters.run_cmd=function(args,timeout,settings)
    local out,err,code=run(args,timeout,settings)
    if settings and settings.stdin and settings.stdin:match('^BEGIN') then
     writes=writes+1;assert(code==0,err);return '', 'synthetic response lost after commit',1
    end
    if not nested and settings and settings.stdin and settings.stdin:find('.once ',1,true) then
     nested=true
     -- The actual read is complete, but its older snapshot is not published
     -- until after this nested public write and its confirmed child exit.
     if operation=='Apply' then s.on_apply(b) else undo(b) end
    end
    return out,err,code
   end
   local ok,err=pcall(s.on_refresh,b);adapters.run_cmd=run;assert(ok,err)
   assert(nested and writes==1 and s._write_unknown and s._write_lifecycle.settled)
   assert(s.state==state,'older read replaced the initiating state')
   if operation=='Apply' then assert(data.has_changes(s.state) and scalar('SELECT count(*) FROM '..t)=='2')
   else assert(#s._txn_undo_stack==1 and s._txn_undo_stack[1].outcome_unknown and scalar('SELECT count(*) FROM '..t)=='1') end
  end)
 end
 test('fault model: a committed write with a lost client receipt stays unknown until inspection',function()
  local t=table_('lost_receipt','id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
  local b,s=open(t);s.on_clone(b,1)
  local run,calls=adapters.run_cmd,0
  adapters.run_cmd=function(args,timeout,settings)
   local out,err,code=run(args,timeout,settings)
   if settings and settings.stdin and settings.stdin:match('^BEGIN') then
    calls=calls+1;assert(code==0,err);return out,'synthetic connection closed after commit',1
   end
   return out,err,code
  end
  local ok,err=pcall(s.on_apply,b);adapters.run_cmd=run;assert(ok,err)
  assert(calls==1 and scalar('SELECT count(*) FROM '..t)=='2')
  assert(s._write_unknown==true and s._write_lifecycle.settled and data.has_changes(s.state))
  s.on_refresh(b);assert(not s._write_unknown and not data.has_changes(s.state) and #s.state.rows==2)
 end)
 for _,surface in ipairs({'callback','mapping'}) do
  test('fault model: pending child blocks '..surface..' refresh until actual completion',function()
   local t=table_('pending_'..surface,'id INTEGER PRIMARY KEY,v TEXT');exec('INSERT INTO '..t.." VALUES(1,'before')")
   local b,s=open(t);s.on_clone(b,1)
   local run,calls,child,result=adapters.run_cmd,0,nil,nil
   local ready=root..'/ready-'..surface
   adapters.run_cmd=function(args,timeout,settings)
    if settings and settings.stdin and settings.stdin:match('^BEGIN') then
     calls=calls+1;assert(calls==1,'automatic retry')
     local paused,n=settings.stdin:gsub('COMMIT;%s*$',function()
      return 'SELECT writefile('..sql.quote_value(ready)..",'ready');\n.shell sleep 0.3\nCOMMIT;"
     end);assert(n==1)
     child=vim.system(args,{stdin=paused,text=false,env=settings.env},function(r)
      result=r;if settings.on_complete then settings.on_complete() end
     end)
     if settings.on_start then settings.on_start(child) end
     assert(vim.wait(1000,function() return vim.fn.filereadable(ready)==1 end,1))
     return '', 'command timed out; process completion unknown',124
    end
    return run(args,timeout,settings)
   end
   local ok,err=pcall(s.on_apply,b);adapters.run_cmd=run
   if not ok then if child then pcall(child.kill,child,9);pcall(child.wait,child,1000) end;error(err) end
   assert(s._write_unknown and not s._write_lifecycle.settled and not result)
   if surface=='callback' then s.on_refresh(b)
   else for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n')) do if m.lhs=='r' then m.callback();break end end end
   assert(s._write_unknown and data.has_changes(s.state) and #s.state.rows==1)
   assert(scalar('SELECT count(*) FROM '..t)=='1' and not result)
   assert(vim.wait(2000,function() return result~=nil end,1));assert(result.code==0,result.stderr)
   s.on_refresh(b);assert(not s._write_unknown and #s.state.rows==2 and not data.has_changes(s.state))
   assert(calls==1)
  end)
 end
 test('unsupported generated WITHOUT ROWID batch is refused before any write',function()
  local t=prefix..'without_rowid'
  exec('CREATE TABLE '..t..'(id TEXT PRIMARY KEY DEFAULT(lower(hex(randomblob(16)))),v TEXT) WITHOUT ROWID')
  created[#created+1]=t;exec('INSERT INTO '..t.." VALUES('old','before')")
  local b,s=open(t);view.apply_edit(b,data.add_change(s.state,1,'v','ours'));s.on_clone(b,1);s.on_apply(b)
  assert(scalar('SELECT count(*) FROM '..t)=='1');assert(scalar('SELECT v FROM '..t)=='before')
  assert(data.has_changes(s.state));assert(#(s._txn_undo_stack or {})==0)
 end)
 test('AFTER INSERT key changes use the actual generated row identity',function()
  local t=table_('triggered',"id TEXT PRIMARY KEY DEFAULT(lower(hex(randomblob(16)))),v TEXT DEFAULT 'default'")
  exec('CREATE TRIGGER '..prefix..'after_insert AFTER INSERT ON '..t.." BEGIN UPDATE "..t.." SET id='trigger-'||NEW.id,v='normalized' WHERE rowid=NEW.rowid; END")
  exec('INSERT INTO '..t.." VALUES('old',NULL)")
  local b,s=open(t);s.on_clone(b,1);apply(b,s);undo(b)
  assert(scalar('SELECT count(*) FROM '..t)=='1');assert(scalar('SELECT id FROM '..t)=='trigger-old')
 end)
end

cleanup()
for _,t in ipairs(created) do exec('DROP TABLE '..sql.quote_ident(t)) end
paths.project_root,vim.fn.expand,vim.notify,vim.fn.confirm=oldroot,oldexpand,oldnotify,oldconfirm
editor.show_error=real_error
grip.setup(opts);vim.fn.delete(root,'rf')
print(('grid_write_spec(%s): %d passed, %d failed'):format(kind,pass,fail));if fail>0 then os.exit(1) end
