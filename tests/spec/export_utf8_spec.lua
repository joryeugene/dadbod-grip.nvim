local p=require('dadbod-grip.provenance');local pass,fail=0,0
local function test(name,fn)local ok,e=pcall(fn);if ok then pass=pass+1 else fail=fail+1;print('FAIL '..name..': '..tostring(e))end end
for _,value in ipairs({string.char(0x80),string.char(0xff),string.char(0xc0,0x80),string.char(0xe0,0x80,0x80),string.char(0xed,0xa0,0x80),string.char(0xf4,0x90,0x80,0x80),string.char(0xe2,0x82)})do
 test('JSON rejects invalid UTF-8 scalar bytes',function()assert(p.export_error({},'json',{{value}},{'value'}));assert(p.export_error({},'json',{{'valid'}},{value}))end)
end
test('JSON permits valid Unicode, control escapes and max scalar',function()
 assert(not p.export_error({},'json',{{'É字\0\n'..string.char(0xf4,0x8f,0xbf,0xbf),vim.NIL}},{'value','other'}))
end)
test('SQL byte restoration is not blocked by JSON encoding rule',function()
 assert(not p.export_error({},'sql',{{string.char(0xff)}},{'value'}))
end)
print(string.format('export_utf8_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
