-- A bounded server-generated SHOW CREATE TABLE column-span witness. This does
-- not parse types/expressions/options or execute returned DDL. Fixed SQL mode
-- and sql_quote_show_create are independently checked by the source provider.
local M={}
function M.batch_decode(value)
 local escapes={['0']='\0',n='\n',r='\r',t='\t',b='\b',Z='\26',['\\']='\\'}
 local output,i={},1
 while i<=#value do
  local ch=value:sub(i,i)
  if ch=='\\' then local decoded=escapes[value:sub(i+1,i+1)];if not decoded then return nil,'unknown native batch escape' end;output[#output+1]=decoded;i=i+2
  else output[#output+1]=ch;i=i+1 end
 end
 return table.concat(output)
end
local function tokens(ddl)
 assert(type(ddl)=='string' and #ddl<=1048576,'unsupported SHOW CREATE size')
 local result,i,depth={},1,0
 while i<=#ddl do
  local first,ch,pair=i,ddl:sub(i,i),ddl:sub(i,i+1)
  if ch:match('%s') then i=i+1
  elseif pair=='/*' then
   local last,nested=ddl:find('*/',i+2,true),ddl:find('/*',i+2,true)
   assert(last and (not nested or nested>last),'ambiguous DDL comment')
   result[#result+1]={kind='comment',raw=ddl:sub(i,last+1),depth=depth};i=last+2
  elseif ch=='#' or (pair=='--' and ddl:sub(i+2,i+2):match('[%s%c]')) then
   local last=ddl:find('[\r\n]',i+1) or (#ddl+1)
   result[#result+1]={kind='comment',raw=ddl:sub(i,last-1),depth=depth};i=last
  elseif ch=='"' or ch=='`' or ch=="'" then
   local quote,out,closed=ch,{},false;i=i+1
   while i<=#ddl do
    ch=ddl:sub(i,i)
    if ch==quote then
     if ddl:sub(i+1,i+1)==quote then out[#out+1]=quote;i=i+2 else i=i+1;closed=true;break end
    else out[#out+1]=ch;i=i+1 end
   end
   assert(closed,'unterminated DDL quote')
   result[#result+1]={kind=quote=="'" and 'literal' or 'identifier',raw=ddl:sub(first,i-1),value=table.concat(out),depth=depth}
  elseif ch:match('[%a_]') then
   repeat i=i+1 until i>#ddl or not ddl:sub(i,i):match('[%w_$]')
   result[#result+1]={kind='word',raw=ddl:sub(first,i-1):upper(),depth=depth}
  else
   result[#result+1]={kind='symbol',raw=ch,depth=depth};i=i+1
   if ch=='(' then depth=depth+1 elseif ch==')' then depth=depth-1;assert(depth>=0,'unbalanced DDL parentheses') end
  end
 end
 assert(depth==0,'unbalanced DDL parentheses')
 return result
end
local function quoted(token)
 return token and token.kind=='identifier' and token.value~='' and not token.value:find('[%c\\]')
end
local function constraint(def)
 local first=def[1] and def[1].raw
 if first=='CONSTRAINT' then
  assert(quoted(def[2]),'unproved constraint name')
  local rest={};for i=3,#def do rest[#rest+1]=def[i] end;return constraint(rest)
 end
 if first=='PRIMARY' or first=='FOREIGN' then return def[2] and def[2].raw=='KEY' end
 if first=='UNIQUE' or first=='FULLTEXT' or first=='SPATIAL' then return def[2] and (def[2].raw=='KEY' or def[2].raw=='INDEX') end
 if first=='KEY' or first=='INDEX' then return quoted(def[2]) or (def[2] and def[2].raw=='(') end
 return first=='CHECK' and def[2] and def[2].raw=='('
end
function M.names(ddl,expected_table)
 local ok,result=pcall(function()
  local list=tokens(ddl);assert(list[1] and list[1].raw=='CREATE' and list[2] and list[2].raw=='TABLE','not a canonical CREATE TABLE')
  local pos=3;assert(quoted(list[pos]),'unquoted/unproved table name');local table_name=list[pos].value;pos=pos+1
  if list[pos] and list[pos].raw=='.' then pos=pos+1;assert(quoted(list[pos]),'unproved qualified table name');table_name=list[pos].value;pos=pos+1 end
  assert(not expected_table or table_name==expected_table,'SHOW CREATE source name mismatch')
  assert(list[pos] and list[pos].raw=='(' and list[pos].depth==0,'missing column definition list')
  pos=pos+1;local definitions,current,finished={},{},false
  while pos<=#list do
   local token=list[pos]
   if token.depth==1 and (token.raw==',' or token.raw==')') then
    assert(#current>0,'empty column/constraint definition');definitions[#definitions+1]=current;current={}
    if token.raw==')' then finished=true;pos=pos+1;break end
   else current[#current+1]=token end
   pos=pos+1
  end
  assert(finished,'unclosed column layout')
  -- Options are not interpreted. They cannot append SQL columns after the
  -- balanced definition list. A second statement is never accepted.
  for i=pos,#list do
   if list[i].raw==';' then
    for j=i+1,#list do assert(list[j].kind=='comment','multiple DDL statements') end
   end
   assert(not (list[i].kind=='word' and (list[i].raw=='CREATE' or list[i].raw=='ALTER' or list[i].raw=='DROP')),'unproved DDL tail')
  end
  local names,seen={},{ }
  for _,def in ipairs(definitions) do
   for _,token in ipairs(def) do
    if token.kind=='comment' and token.raw:match('^/%*[mM]?!') then
     assert(token.raw:match('^/%*[mM]?!%d+%s+INVISIBLE%s*%*/$'),'unproved executable DDL attribute')
    end
   end
   if quoted(def[1]) then
    assert(def[2] and def[2].kind=='word','unproved column declaration')
    local name=def[1].value;assert(not seen[name:lower()],'duplicate DDL column name');seen[name:lower()]=true;names[#names+1]=name
   else assert(constraint(def),'unknown layout definition') end
  end
  assert(#names>0,'empty SQL column layout');return names
 end)
 if not ok then return nil,tostring(result) end;return result
end
function M.matches(names,columns)
 if type(names)~='table' or type(columns)~='table' or #names==0 or #names~=#columns then return false end
 for i,name in ipairs(names) do if columns[i].column_name~=name then return false end end
 return true
end
-- This is a visibility profile, not a server-version feature claim. GIPKs
-- were introduced in MySQL8.0.30; an absent flag is only proved on identified
-- MariaDB or the documented MySQL8.0.0--29 pre-GIPK profile.
function M.profile(version,comment,quote,mode,gipk)
 if type(version)~='string' or type(comment)~='string' or type(mode)~='string' then return nil,'unproved server visibility profile' end
 local modes={};for value in mode:gmatch('[^,]+') do if modes[value] then return nil,'unproved SQL mode' end;modes[value]=true end
 if not modes.ANSI_QUOTES or not modes.NO_BACKSLASH_ESCAPES then return nil,'unproved fixed SQL mode' end
 modes.ANSI_QUOTES,modes.NO_BACKSLASH_ESCAPES=nil,nil;if next(modes) then return nil,'unproved fixed SQL mode' end
 -- MariaDB CONVERT(system_boolean USING utf8mb4) returns ON/OFF even
 -- though direct scalar output is 1/0. This is a declared capability field.
 if quote=='ON' then quote='1' elseif quote=='OFF' then quote='0' end
 if quote=='0' then return false,'sql_quote_show_create is disabled' end
 if quote~='1' then return nil,'unproved SHOW CREATE quoting' end
 if gipk=='OFF' then return false,'generated invisible primary-key metadata is hidden' end
 if gipk and gipk~='ON' then return nil,'unproved generated invisible primary-key visibility' end
 local maria=version:lower():find('mariadb',1,true)~=nil
 local mysql=comment:match('^MySQL')~=nil
 if not maria and not mysql then return nil,'unproved server visibility profile' end
 local visibility=gipk
 if not visibility then
  local major,minor,patch=version:match('^(%d+)%.(%d+)%.(%d+)')
  if maria then visibility='mariadb_without_gipk'
  elseif major=='8' and minor=='0' and tonumber(patch)<30 then visibility='mysql_pre_8_0_30'
  else return nil,'generated invisible primary-key visibility is unproved' end
 end
 return {version,comment,quote,'ANSI_QUOTES,NO_BACKSLASH_ESCAPES',visibility}
end
return M
