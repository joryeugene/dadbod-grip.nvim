-- Provider state-machine MODEL only. Native admission is tested separately.
-- Positive model receipts are minted by the provider API, never fabricated
-- result flags. No SQL is dispatched by these unit fixtures.
local ok,source=pcall(require,'dadbod-grip.mysql_source')
if not ok then print('mysql_source_provider_spec: 0 passed, 1 failed (provider absent)');os.exit(1) end
local transport=require('dadbod-grip.transport')
local pass,fail=0,0
local function test(name,fn) local good,err=xpcall(fn,debug.traceback);if good then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(err)) end end
local function t(value) return value==vim.NIL and 'N' or 'T'..transport.hex(tostring(value)) end
local function frames(kind,extra)
 local head={'I|42|'..t('fixture'),'S|'..t('fixture')..'|'..t('a.b λ')..'|'..t(kind or 'BASE TABLE')..'|'..t('InnoDB')..'|'..t('utf8mb4_bin'),'W|0'}
 local row={'C','1',t('i`d'),t('bigint unsigned'),t('bigint'),t('NO'),t(vim.NIL),t('PRI'),t(extra or ''),t(vim.NIL),t(vim.NIL),t(''),t('fixture'),t('a.b λ'),t('comment')}
 return head,{'I|42|'..t('fixture'),table.concat(row,'|'),'W|0'}
end
local function fixture(options)
 options=options or {};local h,c=frames(options.kind,options.extra);local calls={}
 local ddl=options.ddl or 'CREATE TABLE `a.b λ` (`i``d` bigint unsigned NOT NULL,PRIMARY KEY (`i``d`)) ENGINE=InnoDB'
 local profile={'I|42|'..t('fixture'),'V|'..t('8.4.11')..'|'..t('MySQL Community Server - GPL')..'|'..t('1')..'|'..t('ANSI_QUOTES,NO_BACKSLASH_ESCAPES'),
  'show_gipk_in_create_table_and_information_schema\t'..(options.gipk or 'ON'),'W|0'}
 local witness={'I|42|'..t('fixture'),'a.b λ\t'..ddl,'W|0'}
 local function response(phase,after)
  if phase=='source layout profile' then return profile end
  if phase=='source layout witness' then return witness end
  if phase=='source table metadata' then return (after and options.after_head) or h end
  return (after and options.after_columns) or c
 end
 local candidate,err=source.describe({table='a.b λ'},{schema='fixture',instance='unit-model'},function(sql,phase)
  calls[#calls+1]={sql=sql,phase=phase};return response(phase,false)
 end);assert(candidate,err)
 local client={readonly=options.readonly==true,submitted=true,original_completed=true,transaction_started=true,committed=false}
 function client.exchange(sql,marker,phase) return response(phase,true) end
 local ctx,e=source.inspect(client,candidate,'unit_model');assert(ctx,e)
 return candidate,ctx,client,calls
end
local function finish(client)
 client.committed=true
 local completion={client=client,committed=true,reaped=true,code=0,readonly=client.readonly}
 client.completion=completion;return completion
end
test('header metadata is unbound and encodes unusual names without SQL interpolation',function()
 local candidate,_,_,calls=fixture()
 assert(candidate.source_schema_proof.restorable==false and candidate.columns[1].column_name=='i`d')
 for _,call in ipairs(calls) do
  if call.phase=='source layout witness' then assert(call.sql:find('SHOW CREATE TABLE `fixture`.`a.b λ`;',1,true))
  else assert(not call.sql:find('a.b λ',1,true)) end
  assert(not call.sql:find('HANDLER',1,true));assert(not call.sql:find('LIMIT 0',1,true))
 end
end)
test('plain transaction flags never attest a provider receipt',function()
 assert(not require('dadbod-grip.provenance').validate_source({version=1,binding='read_first_transaction',restorable=true,editable=true},{},'held'))
end)
test('inspected but uncommitted metadata never admits restoration',function()
 local _,ctx,client=fixture();local proof=source.complete(ctx,{client=client,committed=false,reaped=true,code=0},ctx.descriptor.columns)
 assert(not proof);assert(not require('dadbod-grip.provenance').validate_source(ctx.descriptor.source_schema_proof,ctx.descriptor.columns,'held'))
end)
for _,field in ipairs({'client','reaped','code','readonly'}) do
 test('reject invalid completion '..field,function()
  local _,ctx,client=fixture();local completion=finish(client)
  completion[field]=field=='client' and {} or field=='code' and 1 or field=='readonly' and true or false
  assert(not source.complete(ctx,completion,ctx.descriptor.columns))
 end)
end
test('complete model receipt survives copying and binds exact projection/source metadata',function()
 local _,ctx,client=fixture();local columns=ctx.descriptor.columns
 local proof,err=source.complete(ctx,finish(client),columns);assert(proof,err)
 local admission=require('dadbod-grip.provenance');assert(admission.validate_source(vim.deepcopy(proof),vim.deepcopy(columns),'held'))
 assert(admission.validate_source(proof,columns,'read_complete'));assert(not admission.validate_source(proof,columns,'arbitrary'))
 local changed=vim.deepcopy(columns);changed[1].column_name='wrong';assert(not admission.validate_source(proof,changed,'read_complete'))
 local modified=vim.deepcopy(proof);modified.signature='wrong';assert(not admission.validate_source(modified,columns,'read_complete'))
end)
test('read-only receipt cannot become editable',function()
 local _,ctx,client=fixture({readonly=true});local p=assert(source.complete(ctx,finish(client),ctx.descriptor.columns))
 assert(p.editable==false);p.editable=true;assert(not require('dadbod-grip.provenance').validate_source(p,ctx.descriptor.columns,'read_complete'))
end)
test('visibility changes withhold actual opaque admission after completion',function()
 local _,changed=frames('BASE TABLE','INVISIBLE');local _,ctx,client=fixture({after_columns=changed})
 assert(ctx.mismatch);assert(not source.complete(ctx,{client=client,committed=true,reaped=true,code=0,readonly=false},ctx.descriptor.columns))
end)
test('view replacement cannot mint a receipt',function()
 local changed=frames('VIEW');local _,ctx,client=fixture({after_head=changed})
 assert(ctx.mismatch);assert(not source.complete(ctx,{client=client,committed=true,reaped=true,code=0,readonly=false},{}))
end)
test('source signature tampering cannot mint a receipt',function()
 local _,ctx,client=fixture();ctx.descriptor.columns[1].data_type='text'
 assert(not source.complete(ctx,{client=client,committed=true,reaped=true,code=0,readonly=false},ctx.descriptor.columns))
end)
test('missing/denied metadata is not replayed',function()
 local calls=0;local c,e=source.describe({table='x'},{schema='fixture',instance='model'},function() calls=calls+1;return nil,'denied' end)
 assert(not c and e:find('denied',1,true) and calls==1)
end)
for _,field in ipairs({'submitted','original_completed','transaction_started','committed','completion'}) do
 test('inspection refuses missing or advanced private lifecycle phase: '..field,function()
  local candidate,_,client=fixture();local calls=0
  client.exchange=function() calls=calls+1;return {} end
  client[field]=(field=='committed' and true) or (field=='completion' and {}) or false
  local ctx=source.inspect(client,candidate,'wrong_phase');assert(not ctx and calls==0)
 end)
end
test('a copied plain completion tuple cannot mint an opaque receipt',function()
 local _,ctx,client=fixture();local actual=finish(client);local forged={}
 for k,v in pairs(actual) do forged[k]=v end
 assert(not source.complete(ctx,forged,ctx.descriptor.columns))
 assert(source.complete(ctx,actual,ctx.descriptor.columns))
end)
test('completion from another server connection is refused',function()
 local _,ctx,client=fixture();local c=finish(client);c.connection_id='43';assert(not source.complete(ctx,c,ctx.descriptor.columns))
end)
test('matching filtered trailing/invisible I_S prefixes cannot mint a complete source receipt',function()
 local candidate,ctx,client=fixture({ddl='CREATE TABLE `a.b λ` (`i``d` bigint unsigned,`hidden` text INVISIBLE)'})
 assert(candidate.route=='legacy' and ctx.mismatch)
 assert(not source.complete(ctx,finish(client),ctx.descriptor.columns))
end)
test('hidden generated-PK visibility cannot mint a source receipt',function()
 local candidate,ctx,client=fixture({gipk='OFF'})
 assert(candidate.route=='legacy' and ctx.mismatch)
 assert(not source.complete(ctx,finish(client),ctx.descriptor.columns))
end)
print(('mysql_source_provider_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
