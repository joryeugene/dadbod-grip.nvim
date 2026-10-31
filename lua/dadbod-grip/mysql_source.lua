-- Source metadata is a header candidate until the ONE original has run and
-- same-session metadata, COMMIT and process completion have all been proved.
-- No SQL executes here except through the reader's private native clients.
local transport=require('dadbod-grip.transport')
local admission=require('dadbod-grip.provenance')
local layout=require('dadbod-grip.mysql_layout')
local M={}
local candidates=setmetatable({},{__mode='k'})
local contexts=setmetatable({},{__mode='k'})
local issued=setmetatable({},{__mode='k'})
local nonbase={VIEW=true,['SYSTEM VIEW']=true,SEQUENCE=true,['SYSTEM VERSIONED']=true}
local decode,parse
local function clone(v) return vim.deepcopy(v) end
local function checked_name(value)
 assert(type(value)=='string' and value~='' and not value:find('%z'),'unproved source name')
 return value
end
local function literal(value)
 return "CONVERT(UNHEX('"..transport.hex(checked_name(value)).."') USING utf8mb4)"
end
local function text(column)
 return "IF("..column.." IS NULL,'N',CONCAT('T',HEX(CONVERT("..column.." USING utf8mb4))))"
end
local function where(source)
 return 'TABLE_SCHEMA='..literal(source.schema)..' AND TABLE_NAME='..literal(source.table)
end
local function identity_sql()
 return "SELECT CONCAT('I|',CONNECTION_ID(),'|',"..text('DATABASE()')..");\n"
end
local function metadata_sql(source,columns)
 local identity=identity_sql()
 if not columns then
  return identity.."SELECT CONCAT('S|',"..text('TABLE_SCHEMA')..",'|',"..text('TABLE_NAME')..",'|',"..text('TABLE_TYPE')..",'|',"
   ..text('ENGINE')..",'|',"..text('TABLE_COLLATION')..') FROM information_schema.TABLES WHERE '..where(source)
   ..";\nSELECT CONCAT('W|',@@warning_count);"
 end
 local expressions={"'C'","CAST(ORDINAL_POSITION AS CHAR)"}
 for _,field in ipairs({'COLUMN_NAME','COLUMN_TYPE','DATA_TYPE','IS_NULLABLE','COLUMN_DEFAULT','COLUMN_KEY','EXTRA',
  'CHARACTER_SET_NAME','COLLATION_NAME','GENERATION_EXPRESSION','TABLE_SCHEMA','TABLE_NAME','COLUMN_COMMENT'}) do
  expressions[#expressions+1]=text(field)
 end
 return identity..'SELECT CONCAT('..table.concat(expressions,",'|',")..') FROM information_schema.COLUMNS WHERE '
  ..where(source).." ORDER BY ORDINAL_POSITION;\nSELECT CONCAT('W|',@@warning_count);"
end
local function layout_witness(source,fetch,meta)
 local sql=identity_sql().."SELECT CONCAT('V|',"..text('@@version')..",'|',"..text('@@version_comment')..",'|',"
  ..text('@@sql_quote_show_create')..",'|',"..text('@@sql_mode')..");\n"
  .."SHOW VARIABLES LIKE 'show_gipk_in_create_table_and_information_schema';\nSELECT CONCAT('W|',@@warning_count);"
 local lines,err=fetch(sql,'source layout profile');assert(lines,err or 'source layout profile denied')
 local framing,values,gipk={},nil,nil
 for _,line in ipairs(lines) do
  if line:sub(1,2)=='I|' or line:sub(1,2)=='W|' then framing[#framing+1]=line
  elseif line:sub(1,2)=='V|' then
   assert(not values,'duplicate source visibility profile');local fields=vim.split(line,'|',{plain=true});assert(#fields==5,'invalid source visibility profile')
   values={};for i=2,5 do values[#values+1]=decode(fields[i]) end
  else
   local fields=vim.split(line,'\t',{plain=true})
   assert(not gipk and #fields==2 and fields[1]=='show_gipk_in_create_table_and_information_schema','unknown source visibility receipt')
   gipk=fields[2]
  end
 end
 local profile_identity=parse(framing,false);assert(profile_identity.connection_id==meta.connection_id,'source visibility connection changed')
 assert(values,'source visibility profile missing')
 local profile,reason=layout.profile(values[1],values[2],values[3],values[4],gipk)
 assert(profile~=nil,reason)
 if profile==false then meta.layout_verified=false;meta.layout_error=reason;meta.layout_profile={values,gipk or vim.NIL};return end
 local function identifier(value) return '`'..checked_name(value):gsub('`','``')..'`' end
 local witness_sql=identity_sql()..'SHOW CREATE TABLE '..identifier(source.schema)..'.'..identifier(source.table)
  ..";\nSELECT CONCAT('W|',@@warning_count);"
 local witness,witness_error=fetch(witness_sql,'source layout witness');assert(witness,witness_error or 'SHOW CREATE source witness denied')
 local identity_lines,ddl_row={},nil
 for _,line in ipairs(witness) do
  if line:sub(1,2)=='I|' or line:sub(1,2)=='W|' then identity_lines[#identity_lines+1]=line
  else assert(not ddl_row,'ambiguous SHOW CREATE rows');ddl_row=line end
 end
 local witness_identity=parse(identity_lines,false);assert(witness_identity.connection_id==meta.connection_id,'source layout connection changed')
 assert(ddl_row,'source layout witness missing');local fields=vim.split(ddl_row,'\t',{plain=true});assert(#fields==2,'invalid native SHOW CREATE field count')
 local table_name,table_error=layout.batch_decode(fields[1]);assert(table_name,table_error)
 local ddl,ddl_error=layout.batch_decode(fields[2]);assert(ddl,ddl_error)
 assert(table_name==meta.table,'SHOW CREATE source identity changed')
 local names,parse_error=layout.names(ddl,meta.table);assert(names,parse_error)
 meta.layout_names,meta.layout_profile=names,profile
 meta.layout_verified=layout.matches(names,meta.columns)
 if not meta.layout_verified then meta.layout_error='complete SHOW CREATE column span differs from visible metadata' end
end
decode=function(value)
 if value=='N' then return vim.NIL end
 assert(type(value)=='string' and value:sub(1,1)=='T' and value:sub(2):match('^%x*$') and #value%2==1,'invalid source metadata encoding')
 return transport.unhex(value:sub(2))
end
parse=function(lines,columns)
 assert(type(lines)=='table','source metadata receipt missing')
 local result={columns={}};local warning,seen_i,seen_s=false,false,false
 for _,line in ipairs(lines) do
  local fields=vim.split(line,'|',{plain=true})
  if fields[1]=='I' then
   assert(not seen_i and #fields==3 and fields[2]:match('^[1-9]%d*$'),'invalid metadata connection receipt')
   result.connection_id=fields[2];result.database=decode(fields[3]);seen_i=true
  elseif fields[1]=='S' and not columns then
   assert(not seen_s and #fields==6,'ambiguous source table receipt');seen_s=true
   result.schema,result.table,result.table_type,result.engine,result.collation=decode(fields[2]),decode(fields[3]),decode(fields[4]),decode(fields[5]),decode(fields[6])
  elseif fields[1]=='C' and columns then
   assert(#fields==15 and fields[2]==tostring(#result.columns+1),'unproved full source ordinal span')
   local values={};for i=3,15 do values[#values+1]=decode(fields[i]) end
   local extra=values[7];assert(type(extra)=='string','missing source EXTRA metadata')
   result.columns[#result.columns+1]={column_name=values[1],column_type=values[2],data_type=values[2],base_type=values[3],
    is_nullable=values[4],column_default=values[5],column_key=values[6],constraints=values[6]=='PRI' and 'PRIMARY KEY' or values[6],
    extra=extra,character_set=values[8],charset=values[8],collation=values[9],generation_expression=values[10],
    source_schema=values[11],source_table=values[12],schema=values[11],table=values[12],column=values[1],comment=values[13],
    ordinal=#result.columns+1,ordinal_position=#result.columns+1,visible=not extra:upper():find('INVISIBLE',1,true),
    generated=extra:upper():find('VIRTUAL GENERATED',1,true)~=nil or extra:upper():find('STORED GENERATED',1,true)~=nil,
    metadata_source='source_schema'}
  elseif fields[1]=='W' then
   assert(not warning and #fields==2 and fields[2]=='0','source metadata emitted warnings');warning=true
  else error('unexpected source metadata receipt',0) end
 end
 assert(seen_i and warning,'incomplete source metadata receipt')
 return result
end
local canonical_fields={'column_name','column_type','base_type','is_nullable','column_default','column_key','extra',
 'character_set','collation','generation_expression','source_schema','source_table','comment'}
local function canonical(meta)
 local columns={}
 for i,col in ipairs(meta.columns) do
  local values={i};for _,key in ipairs(canonical_fields) do values[#values+1]=col[key] end
  columns[i]=values
 end
 return vim.json.encode({1,{meta.schema,meta.table,meta.table_type,meta.engine,meta.collation},columns,
  meta.layout_names or vim.NIL,meta.layout_profile or vim.NIL,meta.layout_verified==true})
end
local function fetch_metadata(source,fetch)
 local lines,err=fetch(metadata_sql(source,false),'source table metadata');assert(lines,err or 'source metadata denied')
 local meta=parse(lines,false)
 if meta.table_type=='BASE TABLE' then
  local column_lines,column_error=fetch(metadata_sql(source,true),'source column metadata');assert(column_lines,column_error or 'source column metadata denied')
  local detail=parse(column_lines,true);assert(detail.connection_id==meta.connection_id,'source metadata connection changed')
  assert(#detail.columns>0,'full source column metadata unavailable')
  local names={}
  for _,col in ipairs(detail.columns) do
   assert(type(col.column_name)=='string' and not names[col.column_name:lower()],'ambiguous source column names')
   assert(col.source_schema==meta.schema and col.source_table==meta.table,'source column identity mismatch')
   names[col.column_name:lower()]=true
  end
  meta.columns=detail.columns
  layout_witness(source,fetch,meta)
 end
 return meta
end
local function descriptor(meta,identity)
 return {columns=clone(meta.columns),source_schema_proof={version=1,binding='metadata_only',instance=identity.instance,
  schema=meta.schema,table=meta.table,table_type=meta.table_type,signature=vim.fn.sha256(canonical(meta)),
  columns=clone(meta.columns),restorable=false,editable=false}}
end
function M.describe(source,identity,fetch)
 local ok,result=pcall(function()
  assert(type(source)=='table' and type(identity)=='table' and type(identity.instance)=='string' and identity.instance~='','unproved connection instance')
  local target={schema=checked_name(source.schema or identity.schema),table=checked_name(source.table)}
  local meta=fetch_metadata(target,fetch)
  assert(type(meta.schema)=='string' and type(meta.table)=='string','source table metadata unavailable')
  assert(meta.schema:lower()==target.schema:lower() and meta.table:lower()==target.table:lower(),'source table identity mismatch')
  assert(meta.table_type=='BASE TABLE' or nonbase[meta.table_type],'unproved source table type')
  local candidate=descriptor(meta,identity)
  candidate.source_kind,candidate.table_type=meta.table_type,meta.table_type
  if meta.table_type~='BASE TABLE' then candidate.route='legacy';candidate.unsupported='nonbase'
  elseif not meta.layout_verified then candidate.route='legacy';candidate.unsupported=meta.layout_error or 'unproved complete source layout' end
  candidates[candidate]={source={schema=meta.schema,table=meta.table},identity=clone(identity),meta=meta,signature=canonical(meta)}
  return candidate
 end)
 if not ok then
  local target=type(source)=='table' and (vim.inspect(source.schema or (type(identity)=='table' and identity.schema))..'.'..vim.inspect(source.table)) or 'unknown'
  return nil,'source '..target..' metadata unavailable: '..tostring(result)
 end;return result
end
function M.inspect(client,candidate,marker)
 local ok,result=pcall(function()
  local prior=candidates[candidate];assert(prior,'unproved header candidate')
  assert(type(client)=='table' and type(client.exchange)=='function','private original client missing')
  assert(client.submitted==true and client.original_completed==true and client.transaction_started==true
   and client.committed~=true and client.completion==nil,'unproved original transaction phase')
  assert(type(marker)=='string' and marker:match('^[%w_]+$'),'invalid private metadata marker')
  local sequence=0
  local meta=fetch_metadata(prior.source,function(sql,phase)
   sequence=sequence+1;return client.exchange(sql,marker..'_'..sequence,phase)
  end)
  local actual=descriptor(meta,prior.identity)
  local context={descriptor=actual,mismatch=meta.table_type~='BASE TABLE' or not meta.layout_verified or canonical(meta)~=prior.signature}
  if context.mismatch then context.reason='query ran; result withheld because source schema changed or is unproven' end
  contexts[context]={client=client,readonly=client.readonly==true,meta=meta,signature=canonical(meta),identity=prior.identity,
   mismatch=context.mismatch,stage='inspected',descriptor=clone(actual)}
  return context
 end)
 if not ok then return nil,tostring(result) end;return result
end
local function mapping_valid(columns,actual)
 if type(columns)~='table' or #columns==0 then return false end
 for _,col in ipairs(columns) do
  if col~=false then
   if type(col)~='table' or type(col.ordinal)~='number' or not vim.deep_equal(col,actual[col.ordinal]) then return false end
  end
 end
 return true
end
function M.complete(context,completion,source_columns)
 local ok,result=pcall(function()
  local record=contexts[context];assert(record and record.stage=='inspected','unproved source inspection phase')
  assert(record.meta.layout_verified==true,'complete source layout is unproven')
  assert(not record.mismatch and not context.mismatch,'query ran; result withheld because source schema changed or is unproven')
  assert(vim.deep_equal(context.descriptor,record.descriptor),'source descriptor signature changed')
  assert(type(completion)=='table' and completion==record.client.completion and record.client.committed==true
   and completion.client==record.client and completion.committed==true
   and completion.reaped==true and completion.code==0 and completion.readonly==record.readonly,'source completion not proved')
  assert(not completion.connection_id or tostring(completion.connection_id)==record.meta.connection_id,'source completion connection changed')
  assert(mapping_valid(source_columns,record.meta.columns),'source projection mapping is unproven')
  local editable=not record.readonly
  for _,col in ipairs(source_columns) do if col==false then editable=false end end
  local fields={version=1,binding='read_first_transaction',instance=record.identity.instance,
   schema=record.meta.schema,table=record.meta.table,table_type=record.meta.table_type,connection_id=record.meta.connection_id,
   signature=vim.fn.sha256(record.signature),columns=clone(record.meta.columns),restorable=true,editable=editable}
  local receipt=function() end
  issued[receipt]={fields=clone(fields),source_columns=clone(source_columns)}
  fields.receipt=receipt;record.stage='complete'
  return fields
 end)
 if not ok then return nil,tostring(result) end;return result
end
admission._register_source_validator(function(proof,columns,phase)
 if type(proof)~='table' or (phase~='held' and phase~='read_complete') then return false,'Unproven source receipt phase' end
 local record=issued[proof.receipt]
 if not record then return false,'Unproven native source receipt' end
 local copied=clone(proof);copied.receipt=nil
 if not vim.deep_equal(copied,record.fields) or not vim.deep_equal(columns,record.source_columns) then return false,'Unproven source receipt signature or mapping' end
 return true
end)
return M
