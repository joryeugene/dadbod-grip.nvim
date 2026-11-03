-- Bounded adjacent clipboard/source/UTF-8 ownership controls; no product writes.
local grip,view,ui=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.ui')
local root=vim.fn.tempname()..'_export_adjacent';vim.fn.mkdir(root,'p')
local file=root..'/fixture.sqlite';local url='sqlite:'..file
local function native(sql)local r=vim.system({'sqlite3',file},{stdin=sql,text=true}):wait();assert(r.code==0,r.stderr);return vim.trim(r.stdout)end
native([[CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT,team TEXT);INSERT INTO people VALUES(1,'Alice','red'),(2,'Bob','blue'); CREATE TABLE invalid_text(id INTEGER PRIMARY KEY,value TEXT);INSERT INTO invalid_text VALUES(1,CAST(X'FF' AS TEXT));]])
grip.setup({limit=2,completion=false,ai=false,connections_path=root..'/connections.json'})
local pass,fail=0,0
local function bytes(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function put(path,s)local f=assert(io.open(path,'wb'));assert(f:write(s));assert(f:close())end
local function close()local a={};for b in pairs(view._sessions)do a[#a+1]=b end;for _,b in ipairs(a)do pcall(vim.api.nvim_buf_delete,b,{force=true})end end
local function test(name,fn)close();local ok,err=xpcall(fn,debug.traceback);close();if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..err)end end
local function open(name)
 grip.open(name or 'people',url,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5));return b,s
end
local function press(b,lhs)for _,m in ipairs(vim.api.nvim_buf_get_keymap(b,'n'))do if m.lhs==lhs then assert(m.callback)();return end end;error('mapping absent '..lhs)end
local function flat(row,cols)local a={};for i=1,#cols do local v=row[i];a[i]=(v==nil or v==vim.NIL)and''or tostring(v)end;return table.concat(a,',')end
for _,lhs in ipairs({'y','Y','gY','gy'})do
 test('metadata '..lhs..' uses the displayed metadata source',function()
  local b,s=open();view.switch_view(b,'columns');local m=s._meta_state;local r=s._render
  vim.api.nvim_win_set_cursor(0,{r.data_start,r.byte_positions[1][m.columns[1]].start});vim.fn.setreg('+','SENTINEL');press(b,lhs)
  local actual=vim.fn.getreg('+');local expected
  if lhs=='y'then expected=m.rows[1][1]
  elseif lhs=='Y'then expected=flat(m.rows[1],m.columns)
  elseif lhs=='gY'then local lines={table.concat(m.columns,',')};for _,row in ipairs(m.rows)do lines[#lines+1]=flat(row,m.columns)end;expected=table.concat(lines,'\n')
  else expected=table.concat(view._format_export(m.rows,m.columns,'markdown'), '\n')end
  assert(actual==expected,'clipboard source differs from metadata display')
 end)
end
test('known invalid UTF-8 TEXT refuses JSON without overwriting destination',function()
 local b=open('invalid_text');assert(native('SELECT typeof(value)||\':\'||hex(value) FROM invalid_text')=='text:FF','native TEXT oracle changed')
 local path=root..'/text.json';put(path,'KEEP EXISTING\n');local oldselect,oldinput=vim.ui.select,ui.input;local n=0
 vim.ui.select=function(_,_,cb)cb('Current page')end;ui.input=function()n=n+1;return n==1 and'json'or path end
 local ok,err=pcall(view.do_export,b);vim.ui.select,ui.input=oldselect,oldinput;assert(ok,err)
 local raw=bytes(path);local evidence=vim.env.GRIP_REVIEW_EVIDENCE
 if evidence then
  vim.fn.mkdir(evidence,'p');put(evidence..'/invalid-text-export.bin',raw)
  local hex=raw:gsub('.',function(c)return string.format('%02X',c:byte())end)
  vim.fn.writefile({vim.json.encode({native_type='text',native_hex='FF',export_hex=hex,replaced=raw~='KEEP EXISTING\n'})},evidence..'/invalid-text-proof.json')
 end
 assert(raw=='KEEP EXISTING\n','invalid UTF-8 TEXT JSON replaced existing destination')
 assert(#vim.fn.glob(path..'.grip-tmp-*',false,true)==0,'TEXT refusal left temp file')
end)
for _,change in ipairs({'changed-view','closed-session'})do
 test('deferred export scope cancels after '..change,function()
  local b=open();view.switch_view(b,'columns');local path=root..'/'..change..'.csv';put(path,'KEEP EXISTING\n')
  local oldselect,oldinput=vim.ui.select,ui.input;local pending;local n=0
  vim.ui.select=function(_,_,cb)pending=cb end;ui.input=function()n=n+1;return n==1 and'csv'or path end
  local ok,err=pcall(function()
   view.do_export(b);assert(pending,'scope callback not captured')
   if change=='closed-session'then vim.api.nvim_buf_delete(b,{force=true});assert(not view._sessions[b],'session did not close')else view.switch_view(b,'records')end
   pending('Current page')
  end)
  vim.ui.select,ui.input=oldselect,oldinput;assert(ok,err)
  assert(bytes(path)=='KEEP EXISTING\n','stale export callback replaced destination')
  assert(n==0,'stale export advanced to format/path prompt')
 end)
end
close();vim.fn.delete(root,'rf')
print(string.format('export_adjacent_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
