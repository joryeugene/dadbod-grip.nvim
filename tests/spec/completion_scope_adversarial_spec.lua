-- Native completeopt ownership checks, including Neovim0.10 global-only lease.
dofile('tests/minimal_init.lua')
local c=require('dadbod-grip.completion')
local pass,fail=0,0
local function test(name,fn)
 local ok,err=xpcall(fn,debug.traceback)
 if ok then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..err)end
end
local function owned_scope(fn)
 local initial,initialbuf=vim.go.completeopt,vim.api.nvim_get_current_buf()
 local owner,other=vim.api.nvim_create_buf(false,true),vim.api.nvim_create_buf(false,true)
 local ok,err=xpcall(function()
  vim.api.nvim_set_current_buf(other)
  c.setup_auto_complete(owner,function()return nil end)
  fn(owner,other)
 end,debug.traceback)
 vim.api.nvim_set_current_buf(initialbuf)
 for _,buf in ipairs({owner,other})do if vim.api.nvim_buf_is_valid(buf)then vim.api.nvim_buf_delete(buf,{force=true})end end
 vim.go.completeopt=initial
 if not ok then error(err)end
end
local global_only=vim.api.nvim_get_option_info2('completeopt',{}).scope=='global'
local function effective(buf)
 return global_only and vim.go.completeopt or vim.bo[buf].completeopt
end
local function quiet(value)
 return value:find('noinsert',1,true) and value:find('noselect',1,true)
end
test('SC01 active pad quiet; other buffers preserve their global setting',function()owned_scope(function(owner,other)
 local before=vim.go.completeopt
 assert(vim.go.completeopt==before)
 vim.api.nvim_set_current_buf(owner)
 assert(quiet(effective(owner)),'focused owner lacks noinsert/noselect')
 if not global_only then assert(vim.go.completeopt==before,'current Neovim changed global')end
 vim.api.nvim_set_current_buf(other)
 assert(vim.go.completeopt==before,'leave leaked quiet settings into other buffer')
end)end)
test('SC02 reentry restores the newest outside preference',function()owned_scope(function(owner,other)
 vim.go.completeopt='menu,preview'
 vim.api.nvim_set_current_buf(owner)
 assert(quiet(effective(owner)))
 vim.api.nvim_set_current_buf(other)
 assert(vim.go.completeopt=='menu,preview')
 vim.go.completeopt='menu,menuone,longest'
 vim.api.nvim_set_current_buf(owner)
 assert(quiet(effective(owner)))
 vim.api.nvim_set_current_buf(other)
 assert(vim.go.completeopt=='menu,menuone,longest','reentry restored stale saved preference')
end)end)
test('SC03 explicit active global change is preserved',function()owned_scope(function(owner,other)
 vim.api.nvim_set_current_buf(owner)
 vim.go.completeopt='menu,longest'
 vim.api.nvim_set_current_buf(other)
 assert(vim.go.completeopt=='menu,longest','lease overwrote explicit user change')
end)end)
test('SC04 deleting focused owner restores original global setting',function()owned_scope(function(owner)
 vim.go.completeopt='menu,preview'
 vim.api.nvim_set_current_buf(owner)
 assert(quiet(effective(owner)))
 vim.api.nvim_buf_delete(owner,{force=true})
 assert(vim.go.completeopt=='menu,preview','delete leaked option lease')
end)end)
print(string.format('completion_scope_adversarial_spec: %d passed, %d failed',pass,fail))
if fail>0 then os.exit(1)end
