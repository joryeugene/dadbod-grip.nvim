-- Actual child completion callbacks exercise the fast-event resource boundary;
-- no database connection is made by this synthetic client transport fixture.
local adapter,grip=require('dadbod-grip.adapters.postgresql'),require('dadbod-grip')
if vim.env.GRIP_PG_CLEANUP_BASELINE then adapter=dofile(vim.env.GRIP_PG_CLEANUP_BASELINE) end
local pass,fail=0,0
local function test(name,mode)
 local system,opts=vim.system,grip.get_opts()
 local path,exited,fast,remained=nil,false,false,nil
 grip.setup({timeout=mode=='timeout' and 20 or 1000})
 vim.system=function(args,settings,callback)
  assert(args[1]=='psql');path=assert(settings.env.PGSERVICEFILE)
  local stat=assert(vim.uv.fs_stat(path));assert(stat.mode%512==384,'service file is not private')
  local command=mode=='timeout' and {'sh','-c','sleep 2'} or {'sh','-c',"cat >/dev/null; printf 'v\\n1\\n'"}
  if mode=='spawn failure' then command={'/grip-fixture-client-does-not-exist'} end
  return system(command,settings,function(result)
   exited=true;fast=vim.in_fast_event()
   callback(result)
   remained=vim.uv.fs_stat(path)~=nil
  end)
 end
 local ok,err=xpcall(function()
  local result,e=adapter.query('SELECT 1 AS v','postgresql://fixture:synthetic@127.0.0.1/fixture')
  if mode=='success' then assert(result,e);assert(result.rows[1][1]=='1') else assert(not result and e) end
  assert(path and not vim.uv.fs_stat(path),'private service file remained after completion')
  if mode~='spawn failure' then assert(exited and fast and remained==false,'cleanup missed actual fast-event exit') end
 end,debug.traceback)
 vim.system=system;grip.setup(opts)
 if path then pcall(vim.uv.fs_unlink,path) end
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(err)) end
end
for _,mode in ipairs({'success','timeout','spawn failure'}) do test('service cleanup on '..mode,mode) end
print(('pg_service_cleanup_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
