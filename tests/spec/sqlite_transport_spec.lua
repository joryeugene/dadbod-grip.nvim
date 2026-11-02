-- A single disposable CLI process owns a private script and its cleanup.
local adapter, adapters = require('dadbod-grip.adapters.sqlite'), require('dadbod-grip.adapters')
if vim.env.GRIP_SQLITE_TRANSPORT_BASELINE then adapter=dofile(vim.env.GRIP_SQLITE_TRANSPORT_BASELINE) end
local transport, grip = require('dadbod-grip.transport'), require('dadbod-grip')
local pass, fail = 0, 0
local function test(name, fn)
 local real_private, real_system, real_run, opts = transport.private_script, vim.system, adapters.run_cmd, grip.get_opts()
 local files, exited = {}, false
 transport.private_script=function()
  local path, cleanup, err=real_private();assert(path,err)
  assert(vim.fn.getfperm(path)=='rw-------');assert(vim.fn.getfperm(vim.fn.fnamemodify(path,':h'))=='rwx------')
  files[#files+1]=path
  return path,function() assert(exited,'cleanup before confirmed process exit');cleanup() end
 end
 vim.system=function(args, options, callback)
  return real_system(args,options,function(result) exited=true;if callback then callback(result) end end)
 end
 local ok, err=xpcall(fn,debug.traceback)
 transport.private_script,vim.system,adapters.run_cmd=real_private,real_system,real_run;grip.setup(opts)
 for _,path in ipairs(files) do
  if vim.fn.filereadable(path)~=0 or vim.fn.isdirectory(vim.fn.fnamemodify(path,':h'))~=0 then
   ok=false;err=tostring(err)..' private artifact remained';vim.fn.delete(vim.fn.fnamemodify(path,':h'),'rf')
  end
 end
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(err)) end
end
local function query(s) return adapter.query(s,'sqlite::memory:') end

test('successful single query preserves NUL CRLF positional columns and cleanup',function()
 local r,e=query([[SELECT CAST(X'004e554c4c00' AS TEXT) AS "one",char(13)||char(10) AS "quote""name",'x' AS "dot.name",'y' AS "one"]])
 assert(r,e);assert(r.rows[1][1]=='\0NULL\0');assert(r.rows[1][2]=='\r\n');assert(r.rows[1][3]=='x');assert(r.rows[1][4]=='y')
 assert(r.columns[2]=='quote"name');assert(r.columns[3]=='dot.name');assert(#r.columns==4)
end)
test('first attempt error surfaces without retry and cleans after exit',function()
 local run,calls=adapters.run_cmd,0
 adapters.run_cmd=function(...)
  calls=calls+1
  local out,e,c=run(...)
  assert(c~=0,'expected SQLite parser error')
  return out,e,c
 end
 local r,e=query('SELECT missing_function(random()) AS v')
 assert(not r and e);assert(calls==1,'user query was retried')
end)
test('volatile output is evaluated once before reading its storage type and bytes',function()
 local r,e=query([[WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<100)
 SELECT CASE WHEN random()%2=0 THEN X'4142' ELSE 7 END AS v FROM c]])
 assert(r,e)
 for i,row in ipairs(r.rows) do
  assert((r.cell_types[i][1]=='blob' and row[1]=='AB') or (r.cell_types[i][1]=='integer' and row[1]=='7'),
   'storage tag and bytes came from different evaluations: '..vim.inspect({row,r.cell_types[i]}))
 end
end)
test('observable scalar side effect runs once, without a read retry',function()
 local path=vim.fn.tempname();vim.fn.writefile({'0'},path,'b')
 local literal=require('dadbod-grip.sql').quote_value(path)
 local r,e=query('SELECT writefile('..literal..', CAST(CAST(readfile('..literal..') AS INTEGER)+1 AS TEXT)) AS v')
 local observed=table.concat(vim.fn.readfile(path,'b'),'\n');vim.fn.delete(path)
 assert(r,e);assert(observed=='1','original read expression executed '..observed..' times')
end)
for _,encoding in ipairs({'UTF-16le','UTF-16be'}) do
 test(encoding..' is refused before the original read or a structured mutation',function()
  local path,side=vim.fn.tempname()..'.db',vim.fn.tempname()
  local url='sqlite:'..path;vim.fn.writefile({'0'},side,'b')
  local db,sql=require('dadbod-grip.db'),require('dadbod-grip.sql')
  assert(db.execute("PRAGMA encoding='"..encoding.."';CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT);INSERT INTO t VALUES(1,'before')",url))
  local r,e=adapter.query('SELECT writefile('..sql.quote_value(side)..",'changed') AS v",url)
  local observed=table.concat(vim.fn.readfile(side,'b'),'\n')
  local plan={version=1,table_name='t',columns={'id','v'},writable={'id','v'},pks={'id'},
   ops={{kind='delete',keys={id='1'},expected={id='1',v='before'},expected_types={id='integer',v='text'}}}}
  local written,err=adapter.grid_write(plan,url)
  local result=vim.system({'sqlite3',path,'SELECT count(*) FROM t;PRAGMA encoding;'}, {text=true}):wait()
  vim.fn.delete(path);vim.fn.delete(side)
  assert(not r and e and e:find('require UTF-8',1,true),'unsupported encoding was presented as lossless: '..vim.inspect({r,e}))
  assert(observed=='0','unsupported read ran its side effect')
  assert(not written and err and err:find('require UTF-8',1,true),'unsupported write was allowed')
  assert(result.code==0 and result.stdout=='1\n'..encoding..'\n','fixture data or encoding changed: '..vim.inspect(result))
 end)
end
test('long read timeout reaps child before deleting private script',function()
 grip.setup({timeout=20})
 local r,e=query('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000000000) SELECT sum(x) FROM c')
 assert(not r and e,'long read did not time out')
end)
test('interrupted read reaps child before deleting private script',function()
 grip.setup({timeout=2000})
 vim.defer_fn(function() vim.api.nvim_input('\003') end,20)
 local r,e=query('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000000000) SELECT sum(x) FROM c')
 assert(not r and e and e:find('interrupted',1,true),'interruption was not preserved')
end)
print(('sqlite_transport_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
