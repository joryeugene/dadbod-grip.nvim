-- Native MySQL/MariaDB value receipts; only uniquely named disposable tables.
local url=vim.env.GRIP_SAFETY_URL or vim.env.GRIP_TEST_MYSQL_URL
if not url or require('dadbod-grip.adapters').kind(url)~='mysql' then
 print('mysql_value_receipt_spec: SKIPPED (assigned MySQL/MariaDB URL required)');return
end
if vim.env.GRIP_TRANSACTION_BASELINE then package.loaded['dadbod-grip.transaction']=dofile(vim.env.GRIP_TRANSACTION_BASELINE) end
local db,data,transaction=require('dadbod-grip.db'),require('dadbod-grip.data'),require('dadbod-grip.transaction')
local prefix='grip_receipt_'..vim.fn.getpid()..'_'
local pass,fail,created=0,0,{}
local function exec(s) local r,e=db.execute(s,url);assert(r,e);return r end
local function scalar(s) local r,e=db.query(s,url);assert(r,e);return r.rows[1][1] end
local function test(name,fn) local ok,e=xpcall(fn,debug.traceback);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
local function table_(suffix,definition)
 local t=prefix..suffix;exec('CREATE TABLE '..t..' ('..definition..') ENGINE=InnoDB');created[#created+1]=t;return t
end
local function state(t)
 return data.new({table_name=t,primary_keys={'id'},columns={'id','payload','latin','bytes'},
  rows={{'1','a\0b','é','\0\255A'}},cell_types={{'number','text','text','blob'}},storage_adapter='mysql'})
end
local function write(st)
 local info,e=db.get_column_info(st.table_name,url);assert(info,e)
 local plan,err=transaction.plan(st,info);assert(plan,err)
 local r,why=db.execute(plan,url);assert(r,why);return r
end
local function reverse(r) local result,e=db.execute(r.undo,url);assert(result,e) end
local function seed(suffix)
 local t=table_(suffix,'id BIGINT AUTO_INCREMENT PRIMARY KEY,payload LONGTEXT CHARACTER SET utf8mb4,latin VARCHAR(16) CHARACTER SET latin1,bytes LONGBLOB')
 exec("INSERT INTO "..t.." VALUES(1,CONVERT(X'610062' USING utf8mb4),CONVERT(X'E9' USING latin1),X'00FF41')")
 return t
end
local function oracle(t)
 return scalar("SELECT CONCAT(HEX(payload),':',HEX(latin),':',HEX(bytes)) FROM "..t..' WHERE id=1')
end
test('UPDATE receipts preserve control text, mixed charset and untouched binary',function()
 local t=seed('update');local r=write(data.add_change(state(t),1,'payload','ours'))
 assert(r.undo.ops[1].values.payload=='a\0b');assert(r.undo.ops[1].expected.bytes=='\0\255A')
 reverse(r);assert(oracle(t)=='610062:E9:00FF41')
end)
test('DELETE Undo restores binary and mixed-charset values exactly',function()
 local t=seed('delete');local r=write(data.toggle_delete(state(t),1))
 assert(scalar('SELECT count(*) FROM '..t)=='0');reverse(r)
 assert(oracle(t)=='610062:E9:00FF41')
end)
test('clone retains binary storage and UTF8 text before exact Undo',function()
 local t=seed('clone');local r=write(data.clone_row(state(t),1))
 assert(scalar("SELECT CONCAT(HEX(payload),':',HEX(latin),':',HEX(bytes)) FROM "..t..' WHERE id=2')=='610062:E9:00FF41')
 reverse(r);assert(scalar('SELECT count(*) FROM '..t)=='1' and oracle(t)=='610062:E9:00FF41')
end)
test('VARBINARY key receipts preserve non-UTF8 bytes across PK edits and Undo',function()
 local t=table_('key','id VARBINARY(16) PRIMARY KEY,payload TEXT')
 exec("INSERT INTO "..t.." VALUES(X'0041FF','before')")
 local st=data.new({table_name=t,primary_keys={'id'},columns={'id','payload'},rows={{'\0A\255','before'}},cell_types={{'blob','text'}}})
 -- Public editors keep binary cells read-only. Explicit typed plans still need
 -- an exact original identity and executable compensating operation.
 local r=write(data.add_change(st,1,'payload','ours'));reverse(r)
 assert(scalar("SELECT CONCAT(HEX(id),':',payload) FROM "..t)=='0041FF:before')
end)
for _,kind in ipairs({'enum','set'}) do
 test('ordinary '..kind..' labels and zero values retain update clone delete and Undo',function()
  local definition=kind=='enum' and "ENUM('pending','active','disabled')" or "SET('read','write','admin')"
  local value=kind=='enum' and "'active'" or "'read,admin'"
  local t=table_('ordinary_'..kind,'id BIGINT AUTO_INCREMENT PRIMARY KEY,payload '..definition..',note TEXT')
  exec('INSERT INTO '..t..' VALUES(1,'..value..",'before'),(2,0,'zero')")
  local function fetched()
   local r,e=db.query('SELECT id,payload,note FROM '..t..' ORDER BY id',url);assert(r,e)
   r.table_name,r.primary_keys=t,{'id'};return data.new(r)
  end
  local function original()
   local r,e=db.query('SELECT id,payload+0,HEX(payload),note FROM '..t..' ORDER BY id',url);assert(r,e);return r.rows
  end
  local before=original()
  reverse(write(data.add_change(fetched(),1,'note','ours')));assert(vim.deep_equal(original(),before))
  for _,idx in ipairs({1,2}) do
   local r=write(data.clone_row(fetched(),idx));reverse(r);assert(vim.deep_equal(original(),before))
   r=write(data.toggle_delete(fetched(),idx));reverse(r);assert(vim.deep_equal(original(),before))
  end
 end)
end
for i,definition in ipairs({"ENUM('','a')","SET('','a')","ENUM('a','a')","ENUM('a','A') COLLATE utf8mb4_general_ci", "SET('a,b','c')", "ENUM('can''t','plain')", "ENUM('a\\b','plain')"}) do
 test('unproven native definition refuses an entire mixed batch '..definition,function()
  local ok_table,t=pcall(table_,'refuse_'..i,'id INTEGER PRIMARY KEY,payload '..definition..',note TEXT')
  if not ok_table and definition=="SET('a,b','c')" then
   assert(tostring(t):find('1367',1,true),t)
   print('NATIVE REFUSAL: server rejects comma-bearing SET label at CREATE; pure profile control covers parser refusal')
   return
  end
  assert(ok_table,t)
  exec('INSERT INTO '..t.."(id,note) VALUES(1,'before'),(2,'two')")
  local st=data.new({table_name=t,primary_keys={'id'},columns={'id','note'},rows={{'1','before'},{'2','two'}}})
  st=data.toggle_delete(data.add_change(st,1,'note','ours'),2)
  local info=assert(db.get_column_info(t,url));local plan=assert(transaction.plan(st,info))
  local adapter=require('dadbod-grip.adapters');local run,calls=adapter.run_cmd,0
  adapter.run_cmd=function(args,timeout,settings)
   if settings and settings.stdin and settings.stdin:find('CHECK(n=1)',1,true) then calls=calls+1 end
   return run(args,timeout,settings)
  end
  local ok,r,e=pcall(db.execute,plan,url);adapter.run_cmd=run;assert(ok,r)
  assert(not r and e and e:find('Unsupported',1,true),'ambiguous profile was not refused: '..tostring(e))
  assert(calls==0,'target batch was submitted before capability refusal')
  assert(scalar('SELECT count(*) FROM '..t)=='2' and scalar('SELECT note FROM '..t..' WHERE id=1')=='before')
  assert(data.has_changes(st))
 end)
end
for _,t in ipairs(created) do exec('DROP TABLE '..t) end
print(('mysql_value_receipt_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
