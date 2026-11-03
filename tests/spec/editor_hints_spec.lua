-- Read real window footers and invoke the exact registered editor callbacks.
local grip, editor = require('dadbod-grip'), require('dadbod-grip.editor')
local saved_keys = vim.deepcopy(grip._keymaps)
local pass, fail = 0, 0
local function text(win)
 local chunks=vim.api.nvim_win_get_config(win).footer
 if type(chunks)=='string' then return chunks end
 local s={};for _,chunk in ipairs(chunks or {})do s[#s+1]=chunk[1]end;return table.concat(s)
end
local function close()
 vim.cmd('stopinsert')
 for _,w in ipairs(vim.api.nvim_list_wins())do
  if vim.api.nvim_win_get_config(w).relative~='' then pcall(vim.api.nvim_win_close,w,true)end
 end
 vim.wait(5,function()return false end,1)
end
local function test(name,fn)
 close();local ok,err=xpcall(fn,debug.traceback);close()
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err)end
end
local function open(keys)
 grip.setup({keymaps=keys});local calls,value=0,nil
 editor.open('fixture.name','9007199254740993',function(v)calls=calls+1;value=v end)
 local w,b=vim.api.nvim_get_current_win(),vim.api.nvim_get_current_buf()
 return w,b,function()return calls,value end
end
local function map(buf,mode,key)
 for _,m in ipairs(vim.api.nvim_buf_get_keymap(buf,mode))do
  if m.lhs:lower()==key:lower()then return m end
 end
end
local function footer_mode(buf,mode)
 vim.api.nvim_exec_autocmds(mode=='i' and 'InsertEnter' or 'InsertLeave',{buffer=buf})
end
test('default hints and primary/alternate callbacks remain available',function()
 local w,b,read=open({});assert(text(w):find('<CR>=save',1,true))
 footer_mode(b,'n');assert(text(w):find('q/<Esc>=cancel',1,true))
 assert(map(b,'i','<CR>') and map(b,'n','<C-s>'))
 map(b,'n','<C-s>').callback();local calls,v=read();assert(calls==1 and v=='9007199254740993')
end)
test('remapped save is advertised in initial insert and normal footers',function()
 local w,b,read=open({editor_save='<C-y>',editor_save_alt=false})
 for _,mode in ipairs({'i','n'})do
  footer_mode(b,mode);assert(text(w):find('<C-y>=save',1,true),'effective save absent: '..text(w))
  assert(not text(w):find('<CR>',1,true),'disabled Enter advertised')
  assert(map(b,mode,'<C-y>') and not map(b,mode,'<CR>') and not map(b,mode,'<C-s>'))
 end
 map(b,'n','<C-y>').callback();local calls,v=read();assert(calls==1 and v=='9007199254740993')
end)
test('alternate save is advertised when primary is disabled',function()
 local w,b,read=open({editor_save=false,editor_save_alt='<F9>'})
 for _,mode in ipairs({'i','n'})do footer_mode(b,mode);assert(text(w):find('<F9>=save',1,true),'fallback save absent')end
 assert(not map(b,'n','<CR>'));map(b,'n','<F9>').callback();assert(read()==1)
end)
test('disabled save actions are not advertised',function()
 local w,b=open({editor_save=false,editor_save_alt=false})
 for _,mode in ipairs({'i','n'})do footer_mode(b,mode);assert(not text(w):find('=save',1,true),'unavailable save advertised')end
 assert(not map(b,'n','<CR>') and not map(b,'n','<C-s>'))
end)
test('normal cancellation uses remapped bindings and callback',function()
 local w,b,read=open({editor_cancel='<F8>',editor_cancel_q=false,editor_cancel_insert='<C-x>'})
 footer_mode(b,'n');assert(text(w):find('<F8>=cancel',1,true),'effective cancel absent')
 assert(not text(w):find('q/',1,true) and not text(w):find('<Esc>=cancel',1,true))
 assert(not map(b,'n','q') and not map(b,'n','<Esc>') and map(b,'i','<C-x>'))
 map(b,'n','<F8>').callback();local calls,v=read();assert(calls==1 and v==nil)
end)
test('alternate cancellation is advertised when Escape action disabled',function()
 local w,b,read=open({editor_cancel=false,editor_cancel_q='<F10>'})
 footer_mode(b,'n');assert(text(w):find('<F10>=cancel',1,true),'alternate cancel absent')
 map(b,'n','<F10>').callback();local calls,v=read();assert(calls==1 and v==nil)
end)
test('disabled normal cancel actions are not advertised; insert Escape stays natural',function()
 local w,b=open({editor_cancel=false,editor_cancel_q=false,editor_cancel_insert=false})
 footer_mode(b,'n');assert(not text(w):find('=cancel',1,true),'unavailable cancel advertised')
 footer_mode(b,'i');assert(text(w):find('<Esc>=normal',1,true),'natural insert Escape hint lost')
 assert(not map(b,'i','<Esc>') and not map(b,'i','<C-c>'))
end)
test('open editor hints stay paired with installed bindings after setup changes',function()
 local w,b,read=open({editor_save='<C-y>',editor_save_alt=false})
 grip.setup({keymaps={editor_save='<F12>',editor_save_alt=false}})
 footer_mode(b,'n');assert(text(w):find('<C-y>=save',1,true),'hint changed without rebinding editor')
 assert(map(b,'n','<C-y>') and not map(b,'n','<F12>'))
 map(b,'n','<C-y>').callback();local calls,v=read();assert(calls==1 and v=='9007199254740993')
end)
grip._keymaps=saved_keys
print(string.format('editor_hints_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
