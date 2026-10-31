local p=require('dadbod-grip.provenance')
local pass,fail=0,0
local function test(name,fn) local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
test('legacy explicit typed values do not require a fabricated source attestation',function()
 assert(not p.write_error({cell_types={{'integer','blob','text'}},storage_adapter='sqlite'}))
 assert(not p.write_error({cell_types={{'number','blob','text'}},storage_adapter='mysql'}))
end)
test('metadata-only and forged flags never establish a source binding',function()
 for _,binding in ipairs({'metadata_only','transaction_mdl'}) do
  local negative={transport_provenance='mysql_derived_v1',source_columns={false},source_schema_proof={version=1,binding=binding,restorable=true,editable=true}}
  assert(p.write_error(negative):find('Unproven',1,true))
 end
end)
test('column proof survives all-NULL and empty row vectors',function()
 for _,types in ipairs({{},{{'null'}}}) do assert(p.has_unknown({cell_types=types,column_info={{kind='raw_unknown'}}})) end
end)
test('encoding-only text allows presentation export but not SQL restoration',function()
 local negative={header_provenance={'explicit_as'},column_info={{kind='text',encoding_proven=true}},source_columns={false}}
 assert(not p.export_error(negative,'json'));assert(p.export_error(negative,'sql'))
end)
test('metadata copy preserves false positional source entries and independent proof',function()
 local original={source_columns={false,{column='id'}},source_schema_proof={binding='metadata_only'},header_provenance={'explicit_as','source_schema'},byte_exact=true}
 local copied=p.copy(original);original.source_schema_proof.binding='changed'
 assert(copied.source_columns[1]==false and copied.source_columns[2].column=='id' and copied.source_schema_proof.binding=='metadata_only')
end)
print(('provenance_contract_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
