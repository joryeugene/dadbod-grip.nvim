-- Actual native provider admission/race tests; assigned core fixtures only.
-- Requires the composed read-first reader, not the historical gated reader.
local url=vim.env.GRIP_SOURCE_TEST_URL
if not url or url=='' then print('mysql_source_provider_live_spec: SKIPPED (assigned fixture required)');return end
local sql,adapters=require('dadbod-grip.sql'),require('dadbod-grip.adapters')
local mysql,provider=require('dadbod-grip.adapters.mysql'),require('dadbod-grip.mysql_source')
local parsed=assert(sql.parse_dadbod_url(url));assert(parsed.dbname=='grip_safety_core','unassigned database')
local admission=require('dadbod-grip.provenance')
local pass,fail=0,0
local name='grip_source_provider_'..vim.fn.getpid()
local audit,fn,backing,view=name..'_audit',name..'_fn',name..'_backing',name..'_view'
local function execute(text) local count,err=mysql.execute(text,url);assert(count~=nil,err) end
local function query(text) local r,err=mysql.query(text,url);assert(r,err);return r end
local function test(label,body)
 local ok,err=xpcall(body,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..label..': '..tostring(err)) end
end
local function admitted(r)
 assert(r.source_schema_proof and admission.validate_source(r.source_schema_proof,r.source_columns,'read_complete'))
 assert(type(r.source_schema_proof.receipt)=='function')
end
local function table_setup(table_name)
 execute('CREATE TABLE '..table_name..'(id INT PRIMARY KEY,payload TEXT CHARACTER SET utf8mb4,hidden TEXT INVISIBLE,b VARBINARY(8),g INT GENERATED ALWAYS AS(id+1) STORED) ENGINE=InnoDB')
 execute('INSERT INTO '..table_name.."(id,payload,hidden,b) VALUES(1,CONVERT(X'610062' USING utf8mb4),'hidden',X'00FF'),(2,'','hidden',X''),(3,NULL,'hidden',NULL)")
end
local native_args={'mysql','--batch','--raw','--skip-column-names','--unbuffered','--skip-force','--skip-reconnect','--binary-mode','--default-character-set=utf8mb4',
 '-h',parsed.host,'-P',tostring(parsed.port or 3306),'-u',parsed.user,parsed.dbname}
local env=parsed.pass and {MYSQL_PWD=parsed.pass} or {}
local setup,setup_error=xpcall(function()
 table_setup(name);table_setup(backing)
 execute('CREATE TABLE '..audit..'(n INT) ENGINE=InnoDB');execute('INSERT INTO '..audit..' VALUES(0)')
 query('DELIMITER //\nCREATE FUNCTION '..fn..'() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN UPDATE '..audit..' SET n=n+1; RETURN 1; END//\nDELIMITER ;\n')
 execute('CREATE VIEW '..view..' AS SELECT id,CAST('..fn..'() AS CHAR) AS payload,b,g FROM '..backing)
 test('actual receipt restores types, bytes, source identity and invisible full schema',function()
  local r=query('SELECT * FROM '..name..' ORDER BY id DESC');admitted(r)
  assert(r.restorable and r.editable and not r.readonly);assert(#r.columns==4 and r.columns[2]=='payload')
  assert(r.rows[1][2]==vim.NIL and r.rows[2][2]=='' and r.rows[3][2]=='a\0b' and r.rows[3][3]=='\0\255')
  assert(r.cell_types[3][3]=='blob' and r.column_info[2].encoding_proven==true)
  assert(#r.source_schema_proof.columns==5 and r.source_schema_proof.columns[3].visible==false)
 end)
 for _,zero in ipairs({false,true}) do
  test('RO actual native receipt, including zero='..tostring(zero),function()
   local old=adapters.set_call_readonly(true)
   local ok,r,e=pcall(mysql.query,'SELECT * FROM '..name..(zero and ' WHERE id<0' or ' ORDER BY id DESC'),url)
   adapters.set_call_readonly(old);assert(ok,r);assert(r,e);admitted(r)
   assert(r.readonly and not r.editable and r.source_schema_proof.editable==false)
   assert(#r.rows==(zero and 0 or 3));assert(r.column_info[2].kind=='text' and r.column_info[2].encoding_proven)
  end)
 end
 test('all-NULL selected column still needs and receives actual column proof',function()
  local r=query('SELECT payload FROM '..name..' WHERE id=3');admitted(r)
  assert(r.rows[1][1]==vim.NIL and r.cell_types[1][1]=='null' and r.column_info[1].kind=='text' and r.column_info[1].encoding_proven)
 end)
 test('native SHOW CREATE witness matches quoted Unicode/dot/doubled-quote names and generated/invisible layout',function()
  local unusual=name..' space.λ`"'
  local function quoted(value) return '`'..value:gsub('`','``')..'`' end
  local q=quoted(unusual);local id,spaced,dotted,doubled=quoted('i`d'),quoted('sp ace'),quoted('λ.x'),quoted('double"q')
  -- Custom query's explicit UTF8 client seeds identifiers exactly; the legacy
  -- execute fixture path may inherit a host-client default character set.
  query('CREATE TABLE '..q..' ('..id..' INT PRIMARY KEY,'..spaced..' TEXT,'..dotted..' DECIMAL(20,4),'
   ..doubled.." VARCHAR(40) DEFAULT 'a''b,(x)',`hidden field` TEXT INVISIBLE,`gen` BIGINT GENERATED ALWAYS AS (("..id..'+1)) STORED,'
   ..'UNIQUE KEY `u` ('..doubled..'),CONSTRAINT `ck` CHECK (('..id..'>0))) ENGINE=InnoDB')
  local good,problem=xpcall(function()
   query('INSERT INTO '..q..' ('..id..','..spaced..','..dotted..') VALUES(1,CONVERT(X\'CEBB\' USING utf8mb4),1.2300)')
   local r=query('SELECT * FROM '..q);admitted(r)
   assert(vim.deep_equal(r.columns,{'i`d','sp ace','λ.x','double"q','gen'}))
   assert(r.rows[1][2]=='λ' and r.rows[1][3]=='1.2300' and r.rows[1][4]=="a'b,(x)")
   assert(#r.source_schema_proof.columns==6 and r.source_schema_proof.columns[5].visible==false and r.source_schema_proof.columns[6].generated)
  end,debug.traceback)
  query('DROP TABLE '..q);assert(good,problem)
 end)
 test('unavailable metadata diagnostic keeps requested source without claiming native table absence',function()
  local missing=name..'_missing';local r,e=mysql.query('SELECT * FROM '..missing,url)
  assert(not r and tostring(e):find(missing,1,true) and tostring(e):find('metadata unavailable',1,true))
 end)
 test('successful view capability routes one original without a typed receipt',function()
  execute('UPDATE '..audit..' SET n=0')
  local r=query('SELECT * FROM '..view..' ORDER BY id');assert(r.readonly and r.restorable==false and not r.lossless)
  assert(not admission.validate_source(r.source_schema_proof,r.source_columns,'read_complete'))
  assert(query('SELECT n FROM '..audit).rows[1][1]=='3')
 end)
 test('invisible-column race after header candidate withholds and rejects actual receipt',function()
  local original_describe,original_inspect=provider.describe,provider.inspect
  local context,client
  provider.describe=function(...)
   local candidate,e=original_describe(...);if candidate then execute('ALTER TABLE '..name..' ADD raced_hidden INT INVISIBLE') end
   return candidate,e
  end
  provider.inspect=function(c,...) client=c;context=assert(original_inspect(c,...));return context end
  local ok,r,e=pcall(mysql.query,'SELECT * FROM '..name,url)
  provider.describe,provider.inspect=original_describe,original_inspect
  assert(ok,r);assert(not r and tostring(e):find('withheld',1,true));assert(context and client.completion)
  assert(not provider.complete(context,client.completion,context.descriptor.columns))
  execute('ALTER TABLE '..name..' DROP raced_hidden')
 end)
 test('table-to-view replacement cannot mint opaque admission after one committed original',function()
  local race=name..'_replacement';table_setup(race);execute('UPDATE '..audit..' SET n=0')
  local original_describe,original_inspect=provider.describe,provider.inspect;local context,client
  provider.describe=function(...)
   local candidate,e=original_describe(...)
   if candidate then execute('DROP TABLE '..race);execute('CREATE VIEW '..race..' AS SELECT id,CAST('..fn..'() AS CHAR) AS payload,b,g FROM '..backing) end
   return candidate,e
  end
  provider.inspect=function(c,...) client=c;context=assert(original_inspect(c,...));return context end
  local ok,r,e=pcall(mysql.query,'SELECT id,payload,b,g FROM '..race..' ORDER BY id',url)
  provider.describe,provider.inspect=original_describe,original_inspect
  execute('DROP VIEW '..race)
  assert(ok,r);assert(not r and tostring(e):find('withheld',1,true));assert(context and client.completion)
  assert(not provider.complete(context,client.completion,context.descriptor.columns))
  assert(query('SELECT n FROM '..audit).rows[1][1]=='3')
 end)
 for _,zero in ipairs({false,true}) do
  test('real provider retains MDL through metadata for zero='..tostring(zero),function()
   local original_inspect=provider.inspect;local process,done,output=nil,nil,''
   local metadata_wait=false
   provider.inspect=function(client,...)
    process=vim.system(native_args,{stdin="SET SESSION lock_wait_timeout=5;SELECT CONCAT('ALTER_CID:',CONNECTION_ID());ALTER TABLE "..name.." ADD after_native INT;SELECT 'ALTER_FINISHED';",
     env=env,text=false,stdout=function(_,chunk) if chunk then output=output..chunk end end},function(r) done=r end)
    assert(vim.wait(3000,function() return output:find('ALTER_CID:%d+\n')~=nil end,5),'ALTER start missing')
    local cid=assert(output:match('ALTER_CID:(%d+)'))
    vim.wait(50,function() return false end,5)
    local stdout,err,code=adapters.run_cmd(native_args,3000,{stdin='SELECT STATE FROM information_schema.PROCESSLIST WHERE ID='..cid..';',env=env,raw_output=true})
    assert(code==0,err);assert(stdout:find('Waiting for table metadata lock',1,true),'ALTER did not wait')
    assert(not done and not output:find('ALTER_FINISHED',1,true))
    local context,e=original_inspect(client,...);assert(context,e)
    assert(not done and not output:find('ALTER_FINISHED',1,true),'ALTER finished before source metadata/COMMIT')
    metadata_wait=true;return context
   end
   local ok,r,e=pcall(mysql.query,'SELECT * FROM '..name..(zero and ' WHERE id<0' or ' ORDER BY id DESC'),url)
   provider.inspect=original_inspect
   if process then process:wait(6000) end
   assert(ok,r);assert(r,e);admitted(r);assert(metadata_wait and done and done.code==0 and output:find('ALTER_FINISHED',1,true))
   execute('ALTER TABLE '..name..' DROP after_native')
  end)
 end
end,debug.traceback)
-- All cleanup targets are this test's fresh task-owned names only.
for _,statement in ipairs({'DROP VIEW IF EXISTS '..view,'DROP VIEW IF EXISTS '..name..'_replacement','DROP TABLE IF EXISTS '..name..'_replacement',
 'DROP FUNCTION IF EXISTS '..fn,'DROP TABLE IF EXISTS '..name,'DROP TABLE IF EXISTS '..backing,'DROP TABLE IF EXISTS '..audit}) do pcall(execute,statement) end
if not setup then fail=fail+1;print('FAIL setup: '..tostring(setup_error)) end
print(('mysql_source_provider_live_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
