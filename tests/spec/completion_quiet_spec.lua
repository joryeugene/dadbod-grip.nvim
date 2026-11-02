dofile("tests/minimal_init.lua")
local c = require("dadbod-grip.completion")
local pass, fail = 0, 0
local mode, popup, calls, supplied = "i", 0, 0, {}
local saved = { mode = vim.fn.mode, complete = vim.fn.complete, pumvisible = vim.fn.pumvisible,
  complete_fn = c.complete, schedule = vim.schedule }
local scheduled = {}
vim.schedule = function(fn) scheduled[#scheduled + 1] = fn end
vim.fn.mode = function() return mode end
vim.fn.pumvisible = function() return popup end
vim.fn.complete = function(_, items) calls = calls + 1; supplied = items end
local result = { { word = "SELECT", menu = "[keyword]" } }
c.complete = function() return result end
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf); vim.wo.virtualedit = "onemore"
local url = "sqlite:/synthetic/quiet.db"
c.setup_auto_complete(buf, function() return url end)
local function flush()
  local batch = scheduled; scheduled = {}
  for _, fn in ipairs(batch) do fn() end
end
local function change(text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_win_set_cursor(0, { 1, #text })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
test("popup options are local and never insert or select", function()
  local opts = vim.bo[buf].completeopt
  assert(opts:find("noinsert", 1, true) and opts:find("noselect", 1, true), opts)
end)
test("one letter is quiet, two letters suggest", function()
  calls = 0; change("s"); flush(); assert(calls == 0)
  change("se"); flush(); assert(calls == 1 and supplied[1].word == "SELECT")
end)
test("sole exact match is quiet case insensitively", function()
  calls = 0; change("select"); flush(); assert(calls == 0)
end)
test("qualifier dot offers columns without a prefix", function()
  calls = 0; result = { { word = "id", menu = "[INTEGER]" } }
  change("SELECT users."); flush(); assert(calls == 1)
end)
test("deferred callback refuses changed buffer", function()
  calls = 0; change("SELECT us")
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other); flush(); assert(calls == 0)
  vim.api.nvim_set_current_buf(buf); vim.api.nvim_buf_delete(other, { force = true })
end)
test("deferred callback refuses normal mode", function()
  calls = 0; change("SELECT us"); mode = "n"; flush(); assert(calls == 0); mode = "i"
end)
test("deferred callback refuses changed text and connection", function()
  calls = 0; change("SELECT us")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT changed" }); flush(); assert(calls == 0)
  change("SELECT us"); url = url .. "changed"; flush(); assert(calls == 0)
end)
test("another popup is never replaced", function()
  calls = 0; popup = 1; change("SELECT us"); flush(); assert(calls == 0); popup = 0
end)
c.complete = saved.complete_fn
vim.fn.mode, vim.fn.complete, vim.fn.pumvisible = saved.mode, saved.complete, saved.pumvisible
vim.schedule = saved.schedule
vim.api.nvim_buf_delete(buf, { force = true })
print(string.format("\ncompletion_quiet_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
