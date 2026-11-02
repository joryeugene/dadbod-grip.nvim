local profile=require('dadbod-grip.mysql_profile')
local pass,fail=0,0
local function test(name,fn) local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
for _,kind in ipairs({'enum','set'}) do
 test(kind..' ordinary unique labels are reversible',function()
  local p,e=profile.enum_set(kind.."('pending','Active','disabled_2','read-only')")
  assert(p,e);assert(p.kind==kind and #p.labels==4 and p.labels[2]=='Active')
 end)
 for _,body in ipairs({"('','a')","('a','a')","('a','A')","('a,b','c')","('a\\b','c')","('can''t','c')","('é','a')","('a' 'b')","('a',)","()","('a') trailing","('a b','c')"}) do
  test(kind..' refuses unproven '..body,function()
   local p,e=profile.enum_set(kind..body);assert(not p and e and e:find('Unsupported',1,true))
  end)
 end
end
for _,type_ in ipairs({'varchar(32)','decimal(65,30)','bigint unsigned','json','blob'}) do
 test(type_..' is outside enum/set profile',function() local p,e=profile.enum_set(type_);assert(p==nil and e==nil) end)
end
print(('mysql_profile_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
