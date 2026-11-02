-- Additive callback/waiter inversion native oracle; D09 is a controlled admission/Ctrl-C model only.
local H=dofile('tests/fixtures/safety_adversarial_harness.lua')
local db,adapters,grip=require('dadbod-grip.db'),require('dadbod-grip.adapters'),require('dadbod-grip')
H.test('D08 callback same-file read with earlier foreground waiter preserves progress',function(c)
 c.url='duckdb:'..c.root..'/q.duckdb'; c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY,payload VARCHAR);INSERT INTO t VALUES(1,\'before\')')
 grip.setup({discovery=false,open_sidebar=false,timeout=500})
 local real_system,grace=vim.system,adapters._exit_grace_ms;adapters._exit_grace_ms=20
 local child,out,reaped,cb,nested,nerr=nil,'',false,false,nil,nil
 vim.system=function(argv,opts,callback)
  if argv[1]=='duckdb'and type(opts.stdin)=='string'and not child then
   local copy=vim.tbl_extend('force',{},opts,{stdin=true,stdout=function(_,s)if s then out=out..s end end})
   child=real_system(argv,copy,function(r)reaped=true;r.stdout=out;callback(r)end)
   child:write(opts.stdin..';\n');return child
  end
  return real_system(argv,opts,callback)
 end
 local ok,err=xpcall(function()
  db.get_schema_batch_async(c.url,function(schema)
   if schema then nested,nerr=db.query('SELECT payload FROM t',c.url)end
   cb=true
  end)
  assert(vim.wait(2000,function()return #out>0 or reaped end,1));assert(not reaped)
  vim.defer_fn(function()child:write(nil)end,30)
  local result,failure=db.execute("UPDATE t SET payload='after' WHERE id=1",c.url)
  assert(vim.wait(2000,function()return cb end,1),'callback missing')
  assert(result,failure);assert(nested,nerr);H.eq(nested.rows,{{'after'}},'earlier queued write must run before callback read')
 end,debug.traceback)
 if child and not reaped then pcall(child.write,child,nil)end
 vim.wait(2000,function()return reaped end,1);vim.system=real_system;adapters._exit_grace_ms=grace
 assert(ok,err)
end)


H.finish('reliability_adversarial_duckdb_admission_spec')
