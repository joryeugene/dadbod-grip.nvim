-- Protocol denials are controlled models; host process cleanup is actual.
local read, adapters = require('dadbod-grip.mysql_read'), require('dadbod-grip.adapters')
local pass, fail = 0, 0
local function eq(a,b) assert(vim.deep_equal(a,b),vim.inspect(a)..' ~= '..vim.inspect(b)) end
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..tostring(err)) end
end
local function run(mode, actual_provider, expected_result)
 local root=vim.fn.tempname();vim.fn.mkdir(root,'p','0700')
 local calls,completed=0,0
 local system,legacy=vim.system,adapters.run_cmd
 vim.system=function(...) calls=calls+1;return system(...) end
 adapters.run_cmd=function() error('typed failure must not choose legacy') end
 local candidate={columns={{column_name='id',data_type='int',ordinal=1,visible=true}}}
 local provider={}
 function provider.describe(_,_,fetch)
  local lines=fetch('SHOW HEADER;', 'header metadata');eq(lines,{'metadata'});return candidate
 end
 function provider.inspect(client,value,marker)
  eq(value,candidate)
  local lines=client.exchange('SHOW POST;',marker,'post-read metadata');eq(lines,{'metadata'})
  return {descriptor=candidate,client=client,mismatch=mode=='mismatch' and 'source signature changed' or nil}
 end
 function provider.complete(context,completion,columns)
  completed=completed+1;eq(context.client,completion.client);eq(completion.committed,true)
  eq(completion.reaped,true);eq(completion.code,0);eq(columns[1].column_name,'id')
  return nil,'controlled model does not issue source attestation'
 end
 if actual_provider then provider=require('dadbod-grip.mysql_source') end
 local ok,result,err=pcall(read.query,'SELECT /* DERIVED_ORIGINAL_SECRET */ id FROM tasks',{
  args={'/usr/bin/python3','tests/fixtures/mysql_read_first_client.py',root,mode},env={MYSQL_PWD='private-process-secret'},
  setup="SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\n",timeout=mode:find('hang') and 200 or 2000,
  identity={schema='fixture',instance='synthetic'},source_provider=provider})
 vim.system,adapters.run_cmd=system,legacy
 assert(ok,result)
 if expected_result then assert(result,err) else eq(result,nil);assert(type(err)=='string',vim.inspect(err)) end
 local transcripts={}
 for _,path in ipairs(vim.fn.glob(root..'/*',false,true)) do
  if vim.fn.isdirectory(path)==1 then
   local pid=table.concat(vim.fn.readfile(path..'/pid'))
   eq(vim.uv.fs_stat('/proc/'..pid),nil)
   local argv=table.concat(vim.fn.readfile(path..'/argv'))
   assert(not argv:find('private-process-secret',1,true) and not argv:find('DERIVED_ORIGINAL_SECRET',1,true),argv)
   assert(argv:find('--skip-force',1,true) and argv:find('--skip-reconnect',1,true),argv)
   eq(table.concat(vim.fn.readfile(path..'/password')),'private-process-secret')
   transcripts[#transcripts+1]=table.concat(vim.fn.readfile(path..'/stdin'),'\n')
  end
 end
 local input=table.concat(transcripts,'\n')
 vim.fn.delete(root,'rf')
 return err,input,calls,completed,result
end
test('actual provider consumes four frames per client before controlled model admission',function()
 local _,input,calls,_,result=run('actual-normal',true,true);eq(calls,2)
 for _,pattern in ipairs({'FROM information_schema.TABLES','FROM information_schema.COLUMNS','SHOW CREATE TABLE',"SHOW VARIABLES LIKE 'show_gipk"}) do
  local count,at=0,1
  while true do local found=input:find(pattern,at,true);if not found then break end;count=count+1;at=found+#pattern end
  eq(count,2)
 end
 eq(result.rows,{{'1'}});eq(result.cell_types,{{'number'}});eq(result.restorable,true)
 assert(require('dadbod-grip.provenance').validate_source(result.source_schema_proof,result.source_columns,'read_complete'))
end)
for _,mode in ipairs({'header-deny','original-deny','post-deny','commit-deny','completion-deny','original-hang','post-hang','commit-hang','completion-hang',
 'header-profile-deny','header-witness-deny','post-profile-deny','post-witness-deny'}) do
 test('actual describe/inspect provider process boundary: '..mode,function()
  local err,input,calls=run(mode,true)
  local before=mode:match('^header')~=nil
  eq(calls,before and 1 or 2)
  local _,count=input:gsub('DERIVED_ORIGINAL_SECRET','');eq(count,before and 0 or 1)
  if mode:match('^post') then assert(not input:find('COMMIT;',1,true),input) end
  if mode:match('deny$') and mode~='completion-deny' then assert(err:find('1142',1,true),err) end
  assert(not err:find('Unproven source inspection phase',1,true),err)
 end)
end
test('header metadata denial submits no original and uses no fallback',function()
 local err,input,calls=run('header-deny');eq(calls,1)
 assert(err:find('1142',1,true),err);assert(not input:find('DERIVED_ORIGINAL_SECRET',1,true),input)
end)
for _,mode in ipairs({'post-deny','original-deny','commit-deny','original-hang','post-hang','commit-hang','completion-deny','completion-hang'}) do
 test(mode..' reaps both clients without replay or attestation',function()
  local err,input,calls,completed=run(mode);eq(calls,2);eq(completed,0)
  local _,count=input:gsub('DERIVED_ORIGINAL_SECRET','');eq(count,1)
  assert(input:find('START TRANSACTION;',1,true),input)
  if mode=='post-deny' or mode=='post-hang' then assert(not input:find('COMMIT;',1,true),input) end
  assert(err:find('do not retry',1,true) or err:find('outcome unknown',1,true),err)
 end)
end
for _,mode in ipairs({'mismatch','malformed','warning','normal'}) do
 test(mode..' successful original commits before withholding bytes',function()
  local err,input,calls,completed=run(mode);eq(calls,2)
  assert(input:find('COMMIT;',1,true),input)
  assert(err:find('result withheld',1,true),err)
  eq(completed,mode=='mismatch' and 0 or 1)
  local _,count=input:gsub('DERIVED_ORIGINAL_SECRET','');eq(count,1)
 end)
end
for _,mode in ipairs({'post-gipk-off','post-quote-off','post-layout-prefix'}) do
 test('post-read unsupported layout commits once and withholds: '..mode,function()
  local err,input,calls=run(mode,true);eq(calls,2)
  assert(input:find('COMMIT;',1,true),input);assert(err:find('result withheld',1,true),err)
  local _,count=input:gsub('DERIVED_ORIGINAL_SECRET','');eq(count,1)
 end)
end
for _,mode in ipairs({'pre-gipk-off','pre-quote-off','pre-layout-prefix'}) do
 test('successfully classified unsupported layout chooses one native legacy original: '..mode,function()
  local root=vim.fn.tempname();vim.fn.mkdir(root,'p','0700')
  local legacy,system=adapters.run_cmd,vim.system
  local native_calls,header_calls=0,0
  vim.system=function(...) header_calls=header_calls+1;return system(...) end
  adapters.run_cmd=function(_,_,opts)
   native_calls=native_calls+1;eq(opts.stdin,"SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\nSELECT id FROM tasks")
   for _,path in ipairs(vim.fn.glob(root..'/*',false,true)) do
    local pid=table.concat(vim.fn.readfile(path..'/pid'));eq(vim.uv.fs_stat('/proc/'..pid),nil)
    local input=table.concat(vim.fn.readfile(path..'/stdin'),'\n')
    assert(not input:find('START TRANSACTION',1,true) and not input:find('AS raw',1,true),input)
   end
   return '<resultset><row><field name="id">1</field></row></resultset>','',0
  end
  local ok,result,err=pcall(read.query,'SELECT id FROM tasks',{
   args={'/usr/bin/python3','tests/fixtures/mysql_read_first_client.py',root,mode},env={},
   setup="SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\n",timeout=2000,
   identity={schema='fixture',instance='synthetic'},source_provider=require('dadbod-grip.mysql_source')})
  adapters.run_cmd,vim.system=legacy,system;vim.fn.delete(root,'rf')
  assert(ok,result);assert(result,err);eq(header_calls,1);eq(native_calls,1)
  eq(result.cell_types,{{'raw_unknown'}});eq(result.readonly,true);eq(result.restorable,false);eq(result.lossless,false)
 end)
end
test('successful VIEW capability chooses one native original after header client is reaped',function()
 local root=vim.fn.tempname();vim.fn.mkdir(root,'p','0700')
 local legacy,system=adapters.run_cmd,vim.system
 local native_calls,header_calls=0,0
 vim.system=function(...) header_calls=header_calls+1;return system(...) end
 adapters.run_cmd=function(_,_,opts)
  native_calls=native_calls+1
  eq(opts.stdin,"SET fixed_session;\nSELECT id FROM task_view")
  for _,path in ipairs(vim.fn.glob(root..'/*',false,true)) do
   local pid=table.concat(vim.fn.readfile(path..'/pid'));eq(vim.uv.fs_stat('/proc/'..pid),nil)
  end
  return '<resultset><row><field name="id">1</field></row></resultset>','',0
 end
 local provider={describe=function(_,_,fetch)
  eq(fetch('SHOW HEADER;','view capability'),{'metadata'});return {route='legacy',source_kind='VIEW'}
 end}
 local ok,result,err=pcall(read.query,'SELECT id FROM task_view',{
  args={'/usr/bin/python3','tests/fixtures/mysql_read_first_client.py',root,'normal'},env={},
  setup='SET fixed_session;\n',timeout=2000,identity={schema='fixture',instance='synthetic'},source_provider=provider})
 adapters.run_cmd,vim.system=legacy,system
 vim.fn.delete(root,'rf')
 assert(ok,result);assert(result,err);eq(header_calls,1);eq(native_calls,1)
 eq(result.rows,{{'1'}});eq(result.readonly,true);eq(result.lossless,false)
 eq(result.cell_types,{{'raw_unknown'}});eq(result.restorable,false)
end)
print(('mysql_read_first_process_spec: %d passed, %d failed'):format(pass,fail))
if fail>0 then os.exit(1) end
