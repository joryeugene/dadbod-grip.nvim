-- Optional lifecycle hooks attest process exit, not a watchdog's answer.
local adapters = require("dadbod-grip.adapters")
local pass, fail = 0, 0
local function eq(a, b, label)
  assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end

test("native exit attests lifecycle before scheduled result delivery", function()
  local started, completed, callback, pid, fast, got = 0, 0, 0
  local handle = adapters.run_cmd_async({ "sh", "-c", "printf native" }, 2000, function(out, _, code)
    callback = callback + 1
    got = { out = out, code = code, completed = completed }
  end, {
    on_start = function(process) started = started + 1; pid = process.pid end,
    on_complete = function() completed = completed + 1; fast = vim.in_fast_event() end,
  })
  eq(callback, 0)
  assert(handle and handle.cancel and handle.reaped, "missing lifecycle handle")
  assert(vim.wait(2000, function() return callback == 1 end, 1))
  eq(started, 1); eq(completed, 1); eq(handle.reaped(), true)
  eq(got.out, "native"); eq(got.code, 0); eq(got.completed, 1)
  eq(fast, true, "completion came from actual native exit")
  assert(not vim.uv.kill(pid, 0), "child is still alive after completion")
  eq(handle.cancel(), false, "completed child is not cancelled")
end)

test("native spawn failure completes without a child", function()
  local started, completed, failed, callback, exit_code = 0, 0, 0, 0
  local handle = adapters.run_cmd_async({ "grip-nonexistent-lifecycle-7ab1" }, 2000,
    function(_, _, code) callback = callback + 1; exit_code = code end, {
      on_start = function() started = started + 1 end,
      on_spawn_error = function() failed = failed + 1 end,
      on_complete = function() completed = completed + 1 end,
    })
  assert(vim.wait(2000, function() return callback == 1 end, 1))
  eq(started, 0); eq(failed, 1); eq(completed, 1); eq(handle.reaped(), true)
  eq(exit_code, 1)
end)

test("native cancellation escalates a TERM-resistant child and waits for real reap", function()
  local path = vim.fn.tempname() .. "-cancel-ready"
  local completed, callbacks, pid, got = 0, 0
  local original, child = vim.system
  vim.system = function(...)
    child = original(...)
    return child
  end
  local ok, err = xpcall(function()
    local handle = adapters.run_cmd_async({ "python", "-c",
      "import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path("
        .. string.format("%q", path) .. ").write_text('ready'); time.sleep(10)" }, 5000,
      function(_, _, code) callbacks = callbacks + 1; got = { code = code, completed = completed } end, {
        on_start = function(process) pid = process.pid end,
        on_complete = function() completed = completed + 1 end,
      })
    assert(vim.wait(2000, function() return vim.fn.filereadable(path) == 1 end, 1))
    assert(handle, "missing cancellation handle")
    eq(handle.cancel(), true)
    eq(handle.reaped(), false, "SIGTERM request is not completion")
    assert(vim.wait(2000, function() return callbacks == 1 end, 1), "cancelled child was not reaped")
    eq(handle.reaped(), true); eq(completed, 1)
    eq(got.code, 130); eq(got.completed, 1)
    assert(not vim.uv.kill(pid, 0), "TERM-resistant child remains alive")
  end, debug.traceback)
  vim.system = original
  if child then pcall(child.kill, child, 9); pcall(child.wait, child, 1000) end
  vim.fn.delete(path)
  if not ok then error(err) end
end)

test("modeled watchdog answer does not attest reap and late native callback completes once", function()
  local original, grace = vim.system, adapters._exit_grace_ms
  local completed, callbacks, on_exit, exit_code = 0, 0
  vim.system = function(_, _, callback)
    on_exit = callback
    return { kill = function() end }
  end
  adapters._exit_grace_ms = 10
  local ok, err = xpcall(function()
    local handle = adapters.run_cmd_async({ "model-child" }, 10,
      function(_, _, code) callbacks = callbacks + 1; exit_code = code end,
      { on_complete = function() completed = completed + 1 end })
    assert(vim.wait(1000, function() return callbacks == 1 end, 1))
    eq(completed, 0); eq(handle.reaped(), false)
    eq(exit_code, 1)
    on_exit({ stdout = "late", stderr = "", code = 0 })
    eq(completed, 1); eq(handle.reaped(), true)
    vim.wait(30, function() return callbacks > 1 end, 1)
    eq(callbacks, 1)
  end, debug.traceback)
  vim.system, adapters._exit_grace_ms = original, grace
  if not ok then error(err) end
end)

print(string.format("\nrun_cmd_async_lifecycle_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
