-- Public consumer paths, using deliberately UNBOUND negative provenance only.
-- These fixtures do not fabricate a native lock or source-restoration proof.
local data,view=require('dadbod-grip.data'),require('dadbod-grip.view')
local proof,db=require('dadbod-grip.provenance'),require('dadbod-grip.db')
local pass,fail=0,0
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(err)) end
end
local function result(kind,rows)
 return {columns={'id','payload'},rows=rows or {{'1','a'}},primary_keys={'id'},table_name='fixture',url='mysql://unbound/fixture',
  storage_adapter='mysql',transport_provenance='mysql_derived_v1',byte_exact=true,lossless=true,
  header_provenance={'direct_projection_spelling','explicit_as'},source_columns={false,false},
  source_schema_proof={version=1,binding='metadata_only',restorable=false,editable=false},
  column_info={{kind='number',encoding_proven=true},{kind=kind,encoding_proven=kind=='text',restorable=false}},
  cell_types={{'number',kind}}}
end
local fields={'column_info','header_provenance','source_columns','source_schema_proof','transport_provenance','byte_exact'}
local function retained(actual,expected)
 for _,field in ipairs(fields) do assert(vim.deep_equal(actual[field],expected[field]),'lost '..field) end
end
for _,ordered in ipairs({false,true}) do
 test('page export retains negative column/source proof with ordered='..tostring(ordered),function()
  local r=result('raw_unknown',{{'1','a'},{'2','b'}});r.cell_types={{'number','raw_unknown'},{'number','raw_unknown'}}
  local st=data.new(r);local session={state=st,_render=ordered and {ordered={2,1}} or nil}
  local original=vim.ui.select;vim.ui.select=function(_,_,cb) cb('Current page') end
  local ok,err=pcall(view._request_export_rows,session,'file',function(rows,cols,_,meta)
   retained(meta,r);assert(vim.deep_equal(cols,r.columns));assert(proof.has_unknown(meta))
   assert(rows[1][1]==(ordered and '2' or '1'));assert(meta.cell_types[1][2]=='raw_unknown')
  end)
  vim.ui.select=original;assert(ok,err)
 end)
end
test('all-row export uses newly fetched proof instead of upgrading page proof',function()
 local r=result('raw_unknown');local session={state=data.new(result('text')),query_spec=require('dadbod-grip.query').new_table('fixture',100),total_rows=1,url='unused'}
 local old_select,old_query=vim.ui.select,db.query
 vim.ui.select=function(_,_,cb) cb('All matching rows') end;db.query=function() return r end
 local delivered=false
 local ok,err=pcall(view._request_export_rows,session,'file',function(_,_,_,meta) delivered=true;retained(meta,r);assert(proof.has_unknown(meta)) end)
 vim.ui.select,db.query=old_select,old_query;assert(ok,err);assert(delivered)
end)
test('every streamed JSON batch retains encoding and negative restoration proof',function()
 local r=result('text',{});r.cell_types={}
 for i=1,1001 do r.rows[i]={tostring(i),'a'};r.cell_types[i]={'number','text'} end
 local path=vim.fn.tempname();local old=proof.export_error;local seen={}
 proof.export_error=function(meta,format)
  retained(meta,r);seen[#seen+1]=#meta.cell_types;return old(meta,format)
 end
 local ok,err=pcall(function()
  local wrote,problem=view._write_export_file(r.rows,r.columns,'json','fixture',path,r);assert(wrote,problem)
  assert(#vim.json.decode(table.concat(vim.fn.readfile(path),'\n'))==1001)
 end)
 proof.export_error=old;vim.fn.delete(path);assert(ok,err);assert(vim.deep_equal(seen,{1001,1000,1}))
end)
for _,kind in ipairs({'text','raw_unknown'}) do
 test('refused SQL file export keeps destination and removes partial file: '..kind,function()
  local r=result(kind);local path=vim.fn.tempname();vim.fn.writefile({'keep'},path)
  local wrote,problem=view._write_export_file(r.rows,r.columns,'sql','fixture',path,r)
  assert(not wrote and tostring(problem):lower():find('unproven',1,true));assert(vim.fn.readfile(path)[1]=='keep')
  local leftovers=vim.fn.glob(path..'.grip-tmp-*',false,true);vim.fn.delete(path);assert(#leftovers==0)
 end)
end
for _,scope in ipairs({'Current page','All matching rows'}) do
 test('public clipboard export refuses unknown bytes before clipboard mutation: '..scope,function()
  local r=result('raw_unknown');local buf=vim.api.nvim_create_buf(false,true)
  view._sessions[buf]={state=data.new(r),query_spec=require('dadbod-grip.query').new_table('fixture',100),total_rows=1,url='unused'}
  local old_select,old_query,old_notify,old_setreg=vim.ui.select,db.query,vim.notify,vim.fn.setreg
  local mutated,notice=false,''
  vim.ui.select=function(_,opts,cb) cb(opts.prompt=='Export scope:' and scope or 'JSON') end
  db.query=function() return r end;vim.notify=function(msg) notice=tostring(msg) end;vim.fn.setreg=function() mutated=true end
  local ok,err=pcall(view.export_to_clipboard,buf)
  vim.ui.select,db.query,vim.notify,vim.fn.setreg=old_select,old_query,old_notify,old_setreg
  view._sessions[buf]=nil;vim.api.nvim_buf_delete(buf,{force=true})
  assert(ok,err);assert(not mutated);assert(notice:lower():find('unproven',1,true))
 end)
end
local function with_grid(fn)
 local r=result('raw_unknown',{{'1','{"x":"\255"}\0'}});r.url='sqlite:test.db'
 local buf=view.open(data.new(r),r.url,'SELECT id,payload FROM fixture',{})
 local win=vim.fn.bufwinid(buf);local render=view._sessions[buf]._render
 vim.api.nvim_set_current_win(win);vim.api.nvim_win_set_cursor(win,{render.data_start,render.byte_positions[1].payload.start})
 local ok,err=xpcall(function() fn(buf) end,debug.traceback)
 for _,b in ipairs(vim.api.nvim_list_bufs()) do
  if b==buf or vim.api.nvim_buf_get_name(b):match('^grip://cell/') then
   view._sessions[b]=nil;pcall(vim.api.nvim_buf_delete,b,{force=true})
  end
 end
 while #vim.api.nvim_tabpage_list_wins(0)>1 do vim.api.nvim_win_close(vim.api.nvim_tabpage_list_wins(0)[2],true) end
 assert(ok,err)
end
test('actual split renders raw bytes as HEX without text/JSON inference or save commands',function()
 with_grid(function(buf)
  local cb=require('dadbod-grip.cell_buffer');local old=cb.render_value
  cb.render_value=function() error('unproven bytes reached text renderer') end
  local ok,cell=pcall(cb.open,buf);cb.render_value=old;assert(ok,cell)
  local text=table.concat(vim.api.nvim_buf_get_lines(cell,0,-1,false),'\n')
  assert(text:find('7B2278223A22FF227D00',1,true));assert(not text:find('\255',1,true))
  assert(vim.bo[cell].readonly and not vim.bo[cell].modifiable and vim.bo[cell].filetype=='')
  assert(vim.api.nvim_buf_get_commands(cell,{}).GripCellEmpty==nil)
 end)
end)
test('actual JSON/row inspectors and yanks refuse raw bytes without side effects',function()
 with_grid(function(buf)
  local old_notify,old_setreg=vim.notify,vim.fn.setreg;local changed=false;local notices={}
  local windows=vim.api.nvim_tabpage_list_wins(0)
  vim.notify=function(msg) notices[#notices+1]=tostring(msg) end;vim.fn.setreg=function() changed=true end
  local maps={};for _,map in ipairs(vim.api.nvim_buf_get_keymap(buf,'n')) do maps[map.lhs]=map.callback end
  local ok,err=pcall(function()
   for _,lhs in ipairs({'gK','K','y','Y','gy','gY','gc','gs'}) do assert(type(maps[lhs])=='function','missing '..lhs);maps[lhs]() end
  end)
  vim.notify,vim.fn.setreg=old_notify,old_setreg
  assert(ok,err);assert(not changed and #notices==8,vim.inspect(notices));assert(vim.deep_equal(vim.api.nvim_tabpage_list_wins(0),windows))
 end)
end)
for _,r in ipairs({
 {columns={'payload'},rows={{'AB'}},transport_provenance='unbound-review'},
 {columns={'payload'},rows={{vim.NIL}},transport_provenance='unbound-review'},
 {columns={'id','payload'},rows={{'1','AB'}},transport_provenance='unbound-review',column_info={{kind='text',encoding_proven=true}}},
}) do
test('public all-row file export refuses missing column proof across '..#r.columns..' positions',function()
 assert(proof.export_error(r,'csv'))
 local path=vim.fn.tempname();vim.fn.writefile({'keep'},path)
 local buf=vim.api.nvim_create_buf(false,true)
 view._sessions[buf]={state=data.new(r),query_spec=require('dadbod-grip.query').new_table('fixture',100),total_rows=1,url='unused'}
 local ui=require('dadbod-grip.ui');local old_input,old_select,old_query,old_notify=ui.input,vim.ui.select,db.query,vim.notify
 local notices={};local inputs={'csv',path}
 ui.input=function() return table.remove(inputs,1) end
 vim.ui.select=function(_,_,cb) cb('All matching rows') end;db.query=function() return r end
 vim.notify=function(msg) notices[#notices+1]=tostring(msg) end
 local ok,err=pcall(view.do_export,buf)
 ui.input,vim.ui.select,db.query,vim.notify=old_input,old_select,old_query,old_notify
 view._sessions[buf]=nil;vim.api.nvim_buf_delete(buf,{force=true})
 local content=vim.fn.readfile(path);local leftovers=vim.fn.glob(path..'.grip-tmp-*',false,true);vim.fn.delete(path)
 assert(ok,err);assert(vim.deep_equal(content,{'keep'}),'unproved bytes replaced destination')
 assert(#leftovers==0);assert(table.concat(notices,'\n'):lower():find('unproven',1,true))
end)
end
test('empty streamed SQL helper refuses unknown proof without replacing destination',function()
 local r={columns={'payload'},rows={},transport_provenance='unbound-review',column_info={{kind='raw_unknown'}}}
 local path=vim.fn.tempname();vim.fn.writefile({'keep'},path)
 local wrote,err=view._write_export_file(r.rows,r.columns,'sql','fixture',path,r)
 local content=vim.fn.readfile(path);local leftovers=vim.fn.glob(path..'.grip-tmp-*',false,true);vim.fn.delete(path)
 assert(not wrote and tostring(err):lower():find('unproven',1,true));assert(vim.deep_equal(content,{'keep'}));assert(#leftovers==0)
end)
test('export span retention does not overwrite the full-table transaction column list',function()
 local st=data.new({columns={'id','payload'},rows={{'1','old'}},primary_keys={'id'},table_name='fixture',storage_adapter='sqlite',cell_types={{'integer','text'}}})
 local plan,err=require('dadbod-grip.transaction').plan(data.add_change(st,1,'payload','new'),{
  {column_name='id',data_type='integer'},{column_name='payload',data_type='text'},{column_name='not_projected',data_type='text'},
 })
 assert(plan,err);assert(vim.deep_equal(plan.columns,{'id','payload','not_projected'}))
end)
print(('provenance_paths_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
