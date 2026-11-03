-- Frozen independent consent/ownership bar. Native fixture DBs, no write SQL after setup.
local grip,view,data,paths,ui,connections=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.data'),require('dadbod-grip.paths'),require('dadbod-grip.ui'),require('dadbod-grip.connections')
local original_opts,original_db,original_dbs,original_keys=grip.get_opts(),vim.g.db,vim.deepcopy(vim.g.dbs),vim.deepcopy(grip._keymaps)
local root=vim.fn.tempname()..'_connection_bar';vim.fn.mkdir(root,'p')
local pass,fail,index=0,0,0
local function bytes(path)local f=io.open(path,'rb');if not f then return nil end;local r=f:read('*a');f:close();return r end
local function close()
 local bufs={};for _,b in ipairs(vim.api.nvim_list_bufs())do if vim.api.nvim_buf_get_name(b):match('grip://')then bufs[#bufs+1]=b end end
 for _,b in ipairs(bufs)do pcall(vim.api.nvim_buf_delete,b,{force=true})end
end
local function run(name,options,body)
 close();index=index+1;local folder=root..'/'..index;vim.fn.mkdir(folder..'/project/.grip','p');vim.fn.mkdir(folder..'/home/.grip','p')
 local oldroot,oldexpand,oldnotify=paths.project_root,vim.fn.expand,vim.notify
 local oldconfirm,oldnative,oldselect=ui.confirm,vim.fn.confirm,vim.ui.select
 local saved_db=vim.g.db;local notices={}
 paths.project_root=function()return folder..'/project'end
 vim.fn.expand=function(v,...)if v=='~'then return folder..'/home'end;return oldexpand(v,...)end
 vim.notify=function(s)notices[#notices+1]=tostring(s)end
 local oldurl='sqlite:'..folder..'/old.sqlite';local newurl='sqlite:'..folder..'/new.sqlite';local badurl='sqlite:'..folder..'/missing-parent/missing.sqlite'
 for _,file in ipairs({'old.sqlite','new.sqlite'})do local r=vim.system({'sqlite3',folder..'/'..file},{stdin="CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT); INSERT INTO people VALUES(1,'one'),(2,'two');",text=true}):wait();assert(r.code==0,r.stderr)end
 local registry=folder..(options.global and '/home/.grip/connections.json' or '/project/.grip/connections.json')
 vim.fn.writefile({vim.json.encode({{name='Old',url=oldurl,id='old',type='sqlite',mode='rw',color='blue',last_used=1},{name='Target',url=newurl,id='target',type='sqlite',mode='rw',color='red',last_used=2},{name='Broken',url=badurl,id='broken',type='sqlite',last_used=3}})},registry)
 grip.setup({limit=2,completion=false,ai=false,discovery=false,open_sidebar=false,connections_path=not options.global and registry or nil})
 vim.g.db=oldurl;vim.g.dbs=nil;view.set_connection_accent('blue')
 grip.open('people',oldurl,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5))
 local st=data.add_change(s.state,1,'name','pending update');st=data.toggle_delete(st,2);st=data.insert_row_with_values(st,2,{id='99',name='pending insert'});view.apply_edit(b,st)
 if options.background then grip.open('people',oldurl,{from_pad=true,force_split=true})end
 if options.pending then s._write_pending=true end
 if options.unknown then s._write_unknown=true;s._write_lifecycle={settled=false,state='started'}end
 local function snapshot()
  local sessions={};for buf,v in pairs(view._sessions)do sessions[buf]={state=vim.deepcopy(v.state),url=v.url,pending=v.pending_mutation,write_pending=v._write_pending,write_unknown=v._write_unknown,valid=vim.api.nvim_buf_is_valid(buf)}end
  return {sessions=sessions,registry=bytes(registry),local_registry=bytes(folder..'/project/.grip/connections.json'),global_registry=bytes(folder..'/home/.grip/connections.json'),url=vim.g.db,mode=connections.current_mode(newurl),accent=vim.api.nvim_get_hl(0,{name='GripBorder',link=false})}
 end
 local before=snapshot();local questions={};local at_choice={}
 local function asked(message)
  questions[#questions+1]=tostring(message);at_choice[#at_choice+1]=snapshot();return options.accept==true
 end
 ui.confirm=function(message)return asked(message)end
 vim.fn.confirm=function(message,choices)
  if not asked(message)then return 0 end
  local n=0;for label in tostring(choices):gmatch('[^\n]+')do n=n+1;local text=label:gsub('&',''):lower();if text:find('discard',1,true)then return n end end
  return 0
 end
 vim.ui.select=function(items,opts,cb)
  if not asked(opts and opts.prompt or '')then cb(nil);return end
  for n,label in ipairs(items)do if tostring(label):lower():find('discard',1,true)then cb(label,n);return end end;cb(nil)
 end
 local function attempt()
  if options.direct then connections.switch(newurl,'Target','sqlite',{mode='ro'})
  else vim.cmd('GripConnect '..(options.broken and 'Broken' or 'Target'))end
  vim.wait(300,function()return false end,10)
 end
 local ok,err=xpcall(function()body({oldurl=oldurl,newurl=newurl,badurl=badurl,buf=b,session=s,before=before,snapshot=snapshot,attempt=attempt,questions=questions,at_choice=at_choice,notices=notices,oldfile=folder..'/old.sqlite'})end,debug.traceback)
 vim.wait(100,function()return false end,10);close()
 ui.confirm,vim.fn.confirm,vim.ui.select=oldconfirm,oldnative,oldselect;paths.project_root,vim.fn.expand,vim.notify=oldroot,oldexpand,oldnotify;vim.g.db=saved_db
 vim.fn.delete(folder,'rf')
 if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..err)end
end
local function unchanged(c)
 assert(vim.deep_equal(c.snapshot(),c.before),'staged sessions/registry/globalURL/mode/accent changed')
end
for _,case in ipairs({{name='named cancel',opts={}},{name='direct mode override cancel',opts={direct=true}},{name='background dirty session cancel',opts={background=true}},{name='global registry cancel',opts={global=true}}})do
 run(case.name,case.opts,function(c)
  c.attempt();assert(#c.questions>0,'no staged-discard choice was offered (not claiming an actual decline)')
  for _,s in ipairs(c.at_choice)do assert(vim.deep_equal(s,c.before),'mutation occurred before discard choice')end
  unchanged(c)
 end)
end
run('accepted discard is explicit and switches once',{accept=true},function(c)
 c.attempt();assert(#c.questions==1 and c.questions[1]:lower():find('discard',1,true),'discard not explicitly confirmed once')
 assert(vim.deep_equal(c.at_choice[1],c.before),'state changed before accepted choice')
 assert(vim.g.db==c.newurl,'accepted switch did not complete')
 for _,s in pairs(view._sessions)do assert(not data.has_changes(s.state),'accepted discard left staging')end
end)
run('known native-invalid target retains work despite discard consent',{accept=true,broken=true},function(c)
 local bad=vim.system({'sqlite3',c.badurl:sub(8)},{stdin='SELECT 1;',text=true}):wait();assert(bad.code~=0,'invalid target fixture unexpectedly connected')
 local original=bytes(c.oldfile);c.attempt();unchanged(c);assert(bytes(c.oldfile)==original,'old database changed')
end)
for _,case in ipairs({{name='pending writer refuses switch',opts={accept=true,pending=true}},{name='unsettled unknown writer refuses switch',opts={accept=true,unknown=true}}})do
 run(case.name,case.opts,function(c)c.attempt();unchanged(c)end)
end
close();grip.setup(original_opts);grip._keymaps=original_keys;vim.g.db=original_db;vim.g.dbs=original_dbs;vim.fn.delete(root,'rf')
print(string.format('independent_connection_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
