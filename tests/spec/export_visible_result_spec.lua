-- Frozen independent regression bar: real disposable SQLite and public export callbacks.
local grip,view,query,db,ui=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.query'),require('dadbod-grip.db'),require('dadbod-grip.ui')
local root=vim.fn.tempname()..'_independent_export';vim.fn.mkdir(root,'p')
local file=root..'/fixture.sqlite';local url='sqlite:'..file
local function native(sql,path)
 local r=vim.system({'sqlite3',path or file},{stdin=sql,text=true}):wait();assert(r.code==0,r.stderr);return vim.trim(r.stdout)
end
native([[CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT,team TEXT); INSERT INTO people VALUES(1,'person one','red'),(2,'person two','blue');
CREATE TABLE blobs(id INTEGER PRIMARY KEY,value BLOB); INSERT INTO blobs VALUES(1,X'0001FF'),(2,X'41420043');
CREATE TABLE plain(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO plain VALUES(1,NULL),(2,''),(3,'É字');
CREATE TABLE many(id INTEGER PRIMARY KEY,name TEXT); WITH RECURSIVE n(i) AS(SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2505) INSERT INTO many SELECT i,printf('row-%04d',i) FROM n;]])
grip.setup({limit=2,completion=false,ai=false,connections_path=root..'/connections.json'})
local pass,fail=0,0
local function close()
 local bufs={};for b in pairs(view._sessions)do bufs[#bufs+1]=b end;for _,b in ipairs(bufs)do pcall(vim.api.nvim_buf_delete,b,{force=true})end
end
local function test(name,fn)
 close();local ok,err=xpcall(fn,debug.traceback);close()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..err)end
end
local function open(table_name)
 grip.open(table_name,url,{from_pad=true});local b=vim.api.nvim_get_current_buf();local s=assert(view._sessions[b]);assert(vim.wait(1000,function()return s._column_info~=nil end,5));return b,s
end
local function bytes(path)
 local f=io.open(path,'rb');if not f then return nil end;local s=f:read('*a');f:close();return s
end
local function put(path,s)local f=assert(io.open(path,'wb'));assert(f:write(s));assert(f:close())end
local function csv(rows,cols)
 local function cell(v)
  if v==nil or v==vim.NIL then return ''end;v=tostring(v)
  if v=='' or v:find('[,"\r\n]')then return '"'..v:gsub('"','""')..'"'end;return v
 end
 local lines={};local function row(r)local fields={};for i=1,#cols do fields[i]=cell(r[i])end;return table.concat(fields,',')end
 lines[1]=row(cols);for _,r in ipairs(rows)do lines[#lines+1]=row(r)end;return table.concat(lines,'\n')..'\n'
end
local function json_file(path)
 local r=vim.system({'/usr/bin/python3','-c','import json,sys;json.loads(open(sys.argv[1],encoding="utf-8",errors="strict").read())',path},{text=true}):wait()
 assert(r.code==0,'JSON is not strict UTF-8/valid JSON');return vim.json.decode(assert(bytes(path)))
end
local function export(b,scope,format,path)
 local oldselect,oldinput,oldnotify,oldquery=vim.ui.select,ui.input,vim.notify,db.query
 local calls,notices,index=0,{},0
 vim.ui.select=function(_,opts,cb)assert(opts.prompt=='Export scope:');cb(scope)end
 ui.input=function()index=index+1;return index==1 and format or path end
 vim.notify=function(s)notices[#notices+1]=tostring(s)end
 db.query=function(...)calls=calls+1;return oldquery(...)end
 local ok,err=pcall(view.do_export,b)
 vim.ui.select,ui.input,vim.notify,db.query=oldselect,oldinput,oldnotify,oldquery
 assert(ok,err);return calls,table.concat(notices,'\n')
end
for _,scope in ipairs({'Current page','All matching rows'})do
 for _,format in ipairs({'csv','json','sql'})do
  test('metadata '..scope..' '..format..' never exports canonical records',function()
   local b,s=open('people');view.switch_view(b,'columns');local meta=assert(s._meta_state)
   assert(#meta.rows==3 and #s.state.rows==2,'ghost-row fixture is not active')
   local path=root..'/meta-'..scope:gsub(' ','-')..'.'..format;put(path,'KEEP EXISTING\n')
   local calls,notice=export(b,scope,format,path)
   if format=='sql'then
    assert(bytes(path)=='KEEP EXISTING\n','metadata SQL export replaced existing destination without proven target')
    assert(notice:lower():find('metadata',1,true)or notice:lower():find('restor',1,true)or notice:lower():find('unsupported',1,true),'unsupported metadata SQL has no clear refusal')
   elseif format=='csv'then
    assert(bytes(path)==csv(meta.rows,meta.columns),'CSV headers/rows differ from actual metadata view')
   else
    local decoded=json_file(path);assert(#decoded==#meta.rows,'JSON row count differs from metadata')
    for ri,row in ipairs(meta.rows)do for ci,col in ipairs(meta.columns)do local v=row[ci];if v==nil then v=vim.NIL end;assert(vim.deep_equal(decoded[ri][col],v),'JSON cell differs from displayed metadata')end end
    assert(decoded[1].id==nil,'canonical Records fields leaked into metadata JSON')
   end
   assert(calls==0,'metadata export re-evaluated underlying Records SQL')
   assert(#vim.fn.glob(path..'.grip-tmp-*',false,true)==0,'export temporary file remains')
  end)
 end
end
for _,format in ipairs({'csv','json'})do
 test('Records all-row '..format..' preserves filters/sort across batches',function()
  local b,s=open('many');local spec=query.add_filter(s.query_spec,'id > 5');spec=query.toggle_sort(query.toggle_sort(spec,'id'),'id');spec=query.set_page(spec,2);s.on_requery(b,spec)
  local path=root..'/many.'..format;export(b,'All matching rows',format,path)
  if format=='csv'then local lines=vim.split(assert(bytes(path)),'\n',{plain=true});assert(#lines==2502 and lines[1]=='id,name' and lines[2]=='2505,row-2505' and lines[2501]=='6,row-0006','CSV lost rows/order or duplicated batch header')
  else local a=json_file(path);assert(#a==2500 and a[1].id=='2505' and a[2500].id=='6','JSON lost filtered rows/order across batch')end
  assert(s.query_spec.page==2,'export changed Records page')
 end)
end
test('invalid UTF-8 BLOB JSON refuses before replacing destination or creating temp files',function()
 local b=open('blobs');local path=root..'/blob.json';put(path,'KEEP EXISTING\n')
 local _,notice=export(b,'Current page','json',path)
 assert(bytes(path)=='KEEP EXISTING\n','unsupported binary JSON replaced existing destination')
 assert(#vim.fn.glob(path..'.grip-tmp-*',false,true)==0,'binary refusal left temporary file')
 local message=notice:lower();assert(message:find('binary',1,true)or message:find('blob',1,true)or message:find('utf',1,true),'binary JSON refusal is not explained')
end)
test('ordinary NULL empty text and Unicode JSON remains exact',function()
 local b=open('plain');local path=root..'/plain.json';export(b,'All matching rows','json',path)
 local a=json_file(path);assert(#a==3 and a[1].value==vim.NIL and a[2].value=='' and a[3].value=='É字','ordinary JSON values changed')
end)
test('BLOB SQL export remains typed and native-reimportable',function()
 local b=open('blobs');local path=root..'/blob.sql';export(b,'Current page','sql',path)
 local sql=assert(bytes(path));local imported=root..'/import.sqlite';native('CREATE TABLE blobs(id INTEGER PRIMARY KEY,value BLOB);'..sql,imported)
 assert(native("SELECT group_concat(id||':'||hex(value)||':'||typeof(value),'|') FROM (SELECT * FROM blobs ORDER BY id)",imported)=='1:0001FF:blob|2:41420043:blob','typed SQL binary roundtrip changed')
end)
close();vim.fn.delete(root,'rf')
print(string.format('independent_export_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
