-- One bounded result/storage profile shared by native reads and grid writes.
-- COLUMN_TYPE is server metadata, but a definition still needs an injective
-- display spelling before text receipts can stand for its stored value.
local M={}
function M.enum_set(definition)
 local kind=(definition or ''):match('^%s*([A-Za-z]+)')
 kind=kind and kind:lower()
 if kind~='enum' and kind~='set' then return nil end
 local function refusal(reason) return nil,'Unsupported '..kind:upper()..' definition: '..reason end
 local body=definition:match('^%s*[A-Za-z]+%s*(.-)%s*$')
 if not body or body:sub(1,1)~='(' or body:sub(-1)~=')' then return refusal('unproven label syntax') end
 local labels,seen,pos={},{},2
 while true do
  while body:sub(pos,pos):match('%s') do pos=pos+1 end
  if body:sub(pos,pos)~="'" then return refusal('expected a quoted nonempty label') end
  local finish=body:find("'",pos+1,true)
  if not finish then return refusal('unterminated label') end
  local label=body:sub(pos+1,finish-1)
  if not label:match('^[A-Za-z0-9_%-]+$') then
   return refusal('labels must be nonempty ASCII letters, digits, underscores or hyphens without escapes')
  end
  local folded=label:lower()
  if seen[folded] then return refusal('duplicate or case-equivalent labels') end
  seen[folded]=true;labels[#labels+1]=label;pos=finish+1
  while body:sub(pos,pos):match('%s') do pos=pos+1 end
  local separator=body:sub(pos,pos)
  if separator==')' and pos==#body then break end
  if separator~=',' then return refusal('unsupported quoting, escapes or trailing syntax') end
  pos=pos+1
 end
 if #labels>(kind=='set' and 64 or 65535) then return refusal('label count exceeds native limits') end
 return {kind=kind,labels=labels}
end
return M
