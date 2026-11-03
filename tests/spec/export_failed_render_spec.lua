-- Controlled renderer-error model, not a native outage claim.
local view,data=require('dadbod-grip.view'),require('dadbod-grip.data')
local pass,fail=0,0
for _,key in ipairs({'gY','gy'})do
 local ok,err=xpcall(function()
  local st=data.new({columns={'id','name'},rows={{'1','Alice'}},primary_keys={'id'},table_name='fixture'})
  local b=view.open(st,'sqlite::memory:','SELECT * FROM fixture',{})
  local native=vim.api.nvim_buf_set_extmark;local original_notify=vim.notify
  vim.api.nvim_buf_set_extmark=function()error('controlled render extmark failure')end
  vim.notify=function()end
  local rendered,error_message=pcall(view.render,b,st)
  vim.api.nvim_buf_set_extmark=native;vim.notify=original_notify
  assert(rendered,error_message);assert(view._sessions[b]._render.read_failed,'render failure was not latched')
  vim.fn.setreg('+','KEEP CLIPBOARD')
  local callback;for _,map in ipairs(vim.api.nvim_buf_get_keymap(b,'n'))do if map.lhs==key then callback=map.callback end end
  assert(callback,'missing yank callback');local called,problem=pcall(callback)
  assert(called,'failed-render yank threw instead of refusing: '..tostring(problem))
  assert(vim.fn.getreg('+')=='KEEP CLIPBOARD','failed-render yank changed clipboard')
 end,debug.traceback)
 local bufs={};for b in pairs(view._sessions)do bufs[#bufs+1]=b end;for _,b in ipairs(bufs)do pcall(vim.api.nvim_buf_delete,b,{force=true})end
 if ok then pass=pass+1 else fail=fail+1;print('FAIL '..key..': '..err)end
end
print(string.format('export_failed_render_spec: %d passed, %d failed',pass,fail));if fail>0 then os.exit(1)end
