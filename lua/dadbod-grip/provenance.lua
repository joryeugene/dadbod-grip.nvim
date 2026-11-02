-- Explicit value/provenance admission. Byte fidelity and source restoration
-- are separate: an encoding tag is never a physical SQL type or row identity.
local M={}
local fields={'storage_adapter','cell_types','cell_exact','column_info','lossless','byte_exact',
 'transport_provenance','header_provenance','source_columns','source_schema_proof','restorable','editable'}
local source_validator
local function copy(value)
 if type(value)~='table' then return value end
 local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
function M.copy(metadata,shallow)
 local result={}
 for _,field in ipairs(fields) do if metadata and metadata[field]~=nil then result[field]=shallow and metadata[field] or copy(metadata[field]) end end
 return result
end
function M.scoped(metadata)
 return metadata and (metadata.transport_provenance~=nil or metadata.header_provenance~=nil
  or metadata.source_columns~=nil or metadata.source_schema_proof~=nil)
end
function M.column_unknown(metadata,index)
 local info=metadata and metadata.column_info and metadata.column_info[index]
 if type(info)=='table' and (info.kind=='raw_unknown' or info.storage_type=='raw_unknown' or info.encoding_proven==false) then return true end
 if M.scoped(metadata) and (type(info)~='table' or info.encoding_proven~=true) then return true end
 for _,types in pairs(metadata and metadata.cell_types or {}) do if types[index]=='raw_unknown' then return true end end
 return false
end
function M.has_unknown(metadata)
 if M.scoped(metadata) then
  local positions=metadata.columns or metadata.header_provenance or metadata.source_columns or metadata.column_info
  if type(positions)~='table' or #positions==0 then return true end
  for index in ipairs(positions) do
   if M.column_unknown(metadata,index) then return true end
  end
 end
 for index in pairs(metadata and metadata.column_info or {}) do if M.column_unknown(metadata,index) then return true end end
 for _,types in pairs(metadata and metadata.cell_types or {}) do for _,kind in pairs(types) do if kind=='raw_unknown' then return true end end end
 return false
end
function M.kind_error(kind)
 if kind=='raw_unknown' then return 'Unproven raw bytes cannot be used as SQL values or identities' end
end
function M.raw_display(value)
 if value==nil or value==vim.NIL then return 'NULL (physical type unproven)' end
 return '<raw bytes: '..require('dadbod-grip.transport').hex(tostring(value))..'>'
end
-- Only the core native binding provider may register this verifier. Plain
-- binding/restorable/editable flags do not attest an acquired native lock.
-- No verifier means source-derived restoration stays closed by default.
function M._register_source_validator(validator)
 assert(type(validator)=='function','source verifier must be a function')
 source_validator=validator
end
function M.validate_source(proof,source_columns,phase)
 if not source_validator then return false,'Unproven atomic source binding' end
 local ok,valid,err=pcall(source_validator,proof,source_columns,phase or 'read_complete')
 if not ok or valid~=true then return false,err or 'Unproven atomic source binding' end
 return true
end
function M.restoration_error(metadata)
 if metadata and metadata.restorable==false then return 'Unproven source restoration; result is read-only' end
 if M.has_unknown(metadata) then return 'Unproven raw bytes cannot be restored, cloned or exported' end
 if M.scoped(metadata) then
  local proof=metadata.source_schema_proof
  if type(proof)~='table' or proof.restorable~=true or metadata.restorable==false then return 'Unproven source restoration; result is read-only' end
  local valid,err=M.validate_source(proof,metadata.source_columns,'read_complete')
  if not valid then return err end
 end
end
function M.write_error(metadata)
 if metadata and metadata.editable==false then return 'Unproven editable source; result is read-only' end
 local err=M.restoration_error(metadata);if err then return err end
 if M.scoped(metadata) then
  local proof=metadata.source_schema_proof
  if proof.editable~=true or metadata.editable==false then return 'Unproven editable source; result is read-only' end
 end
end
function M.export_error(metadata,format)
 if M.has_unknown(metadata) then return 'Unproven byte encoding; raw values cannot be exported' end
 if format=='sql' then return M.restoration_error(metadata) end
end
function M.assert_plan(plan)
 local err=M.write_error(plan);assert(not err,err)
 for _,op in ipairs(plan.ops or {}) do
  for _,name in ipairs({'expected_types','post_types','value_types','required_after_types','key_types'}) do
   for _,kind in pairs(op[name] or {}) do local problem=M.kind_error(kind);assert(not problem,problem) end
  end
 end
end
return M
