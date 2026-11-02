-- Proposed-interface guards. Negative metadata is deliberately unbound; these
-- unit fixtures never claim an actual native source-lock attestation.
local data,sql,tx,view=require('dadbod-grip.data'),require('dadbod-grip.sql'),require('dadbod-grip.transaction'),require('dadbod-grip.view')
local pass,fail=0,0
local function test(name,fn) local ok,e=xpcall(fn,debug.traceback);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
local function result(kind,rows)
 return {columns={'id','payload'},rows=rows or {{'1','AB'}},table_name='fixture',primary_keys={'id'},storage_adapter='mysql',readonly=false,lossless=true,byte_exact=true,
  transport_provenance='mysql_derived_v1',header_provenance={'direct_projection_spelling','explicit_as'},source_columns={false,false},
  source_schema_proof={version=1,binding='metadata_only',restorable=false,editable=false},
  column_info={{kind='number',encoding_proven=true},{kind=kind or 'raw_unknown',encoding_proven=kind=='text',restorable=false}},
  cell_types={{'number',kind or 'raw_unknown'}}}
end
local function refusal(fn)
 local ok,e=pcall(fn);assert(not ok and tostring(e):lower():find('unproven',1,true),'missing explicit unproven-value refusal: '..tostring(e))
end
for _,rows in ipairs({{{'1','AB'}},{},{ {'1',vim.NIL} }}) do
 test('column-level unknown proof forces read-only even empty/NULL',function()
  local r=result('raw_unknown',rows);if #rows>0 and rows[1][2]==vim.NIL then r.cell_types={{'number','null'}} end
  assert(data.new(r).readonly==true)
 end)
end
test('provenance survives state creation and edit copies without upgrade',function()
 local r=result('text');local st=data.new(r);local changed=data.add_change(st,1,'payload','new')
 for _,key in ipairs({'header_provenance','source_columns','source_schema_proof','byte_exact','transport_provenance','column_info'}) do
  assert(vim.deep_equal(changed[key],r[key]),'dropped '..key)
 end
 r.source_schema_proof.restorable=true
 assert(st.source_schema_proof.restorable==false and changed.source_schema_proof.restorable==false)
 assert(changed.readonly==true)
end)
test('raw_unknown cannot be cloned after an apparent text edit',function()
 local st=data.new(result());st.readonly=false
 local changed=data.add_change(st,1,'payload','text now')
 refusal(function() data.clone_row(changed,1) end)
end)
test('planner refuses unbound provenance independently of readonly flag',function()
 local st=data.new(result('text'));st.readonly=false
 local plan,e=tx.plan(data.add_change(st,1,'payload','new'),{{column_name='id',data_type='int'},{column_name='payload',data_type='text'}})
 assert(not plan and tostring(e):lower():find('unproven',1,true))
end)
test('compiler refuses raw_unknown explicit plans before SQL submission',function()
 local plan={version=1,table_name='fixture',columns={'id','payload'},writable={'id','payload'},pks={'id'},ops={
  {kind='update',keys={id='1'},values={payload='new'},expected={id='1',payload='AB'},expected_types={id='number',payload='raw_unknown'},post_keys={id='1'}}}}
 local script,e=tx.compile(plan,'sqlite',{rowid=true});assert(not script and tostring(e):lower():find('unproven',1,true))
end)
for _,value in ipairs({'AB',vim.NIL}) do
 test('literal builder refuses raw_unknown including NULL',function() refusal(function() sql.quote_value(value,'mysql','raw_unknown') end) end)
end
for _,format in ipairs({'sql','json','csv','tsv','markdown','grip'}) do
 test(format..' export refuses unknown byte encoding rather than stringify',function()
  local r=result();refusal(function() view._format_export(r.rows,r.columns,format,'fixture',r) end)
 end)
end
test('metadata-only T text can export JSON but cannot claim SQL restoration',function()
 local r=result('text');assert(table.concat(view._format_export(r.rows,r.columns,'json','fixture',r),'\n'):find('AB',1,true))
 refusal(function() view._format_export(r.rows,r.columns,'sql','fixture',r) end)
end)
test('unknown bytes render as explicit ASCII hex without changing bytes',function()
 local raw='\0\255A';local text=view._format_cell(raw,40,false,'raw_unknown')
 assert(text:find('00FF41',1,true) and text:find('raw',1,true));assert(not text:find('\255',1,true))
 local r=result();r.rows[1][2]=raw;assert(data.new(r).rows[1][2]==raw)
end)
for _,flags in ipairs({{restorable=false},{editable=false},{restorable=false,editable=false}}) do
 test('explicit negative capabilities refuse writes without positive provenance markers',function()
  local r={columns={'id','payload'},rows={{'1','AB'}},primary_keys={'id'},table_name='fixture',storage_adapter='mysql',cell_types={{'number','text'}}}
  for k,v in pairs(flags) do r[k]=v end
  local st=data.new(r);assert(st.readonly==true,'negative capability ignored by state')
  refusal(function() data.clone_row(st,1) end)
  st.readonly=false
  local plan,e=tx.plan(data.add_change(st,1,'payload','new'),{{column_name='id',data_type='int'},{column_name='payload',data_type='text'}})
  assert(not plan and tostring(e):lower():find('unproven',1,true))
  local script,err=tx.compile({version=1,table_name='fixture',columns={'id','payload'},writable={'id','payload'},pks={'id'},ops={},restorable=flags.restorable,editable=flags.editable},'mysql',{schema='fixture',table_name='fixture'})
  assert(not script and tostring(err):lower():find('unproven',1,true))
  if flags.restorable==false then refusal(function() view._format_export(r.rows,r.columns,'sql','fixture',r) end) end
 end)
end
print(('provenance_consumer_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
