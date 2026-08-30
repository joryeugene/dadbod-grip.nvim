-- run_cmd_async_spec.lua: direct unit tests for adapters.run_cmd_async.
--
-- Every adapter's get_schema_batch_async goes through this one function.
-- Before task 22 nothing exercised it directly -- only indirectly, one
-- adapter at a time, via adapter_spec.lua's argv-parity tests -- except a
-- mocked watchdog/spawn-failure section that had grown inside
-- sqlserver_schema_spec.lua (added alongside task 21's SQL Server work,
-- under an unrelated filename). That section was folded in here, in full,
-- so this file is the one place for the whole contract: real content
-- delivery (a real subprocess, not a mock), a real ENOENT spawn, delivery
-- timing under a mocked inline callback, and the watchdog's exactly-once
-- guarantee from both directions (watchdog-after-on_exit and
-- on_exit-after-watchdog).

local adapters = require("dadbod-grip.adapters")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

-- ── happy path: a real subprocess, not a mock ───────────────────────────────
-- Confirms the actual delivery, not just that *some* callback ran: stdout,
-- stderr and the exit code all have to survive the round trip through
-- vim.system + vim.schedule unchanged.

test("run_cmd_async: real spawn delivers stdout/stderr/code, asynchronously", function()
  local done, got = false, nil
  adapters.run_cmd_async({ "sh", "-c", "printf out; printf err 1>&2; exit 3" }, 5000,
    function(stdout, stderr, code)
      got = { stdout = stdout, stderr = stderr, code = code }
      done = true
    end)
  eq(done, false, "callback must not fire on the calling tick")
  vim.wait(2000, function() return done end, 1)
  assert(done, "callback never fired")
  eq(got.stdout, "out", "stdout delivered")
  eq(got.stderr, "err", "stderr delivered")
  eq(got.code, 3, "exit code delivered")
end)

test("run_cmd_async: feeds stdin without adding it to argv", function()
  local done, got = false, nil
  local secret = "stdin-only-value-7f3c"
  adapters.run_cmd_async({ "sh", "-c", "IFS= read -r line; printf '%s' \"$line\"" }, 5000,
    function(stdout, stderr, code)
      got = { stdout = stdout, stderr = stderr, code = code }
      done = true
    end, { stdin = secret .. "\n" })
  vim.wait(2000, function() return done end, 1)
  assert(done, "callback never fired")
  eq(got.stdout, secret, "stdin delivered")
  eq(got.stderr, "", "no stderr")
  eq(got.code, 0, "exit code delivered")
end)

-- vim.system's own real callback is already asynchronous, so the happy-path
-- test above can't tell "run_cmd_async defers via vim.schedule" apart from
-- "vim.system just happens to always call back later anyway". Mock vim.system
-- to invoke its callback inline (before it even returns) to isolate the claim:
-- run_cmd_async's own vim.schedule wrap is what keeps the contract, not
-- whatever vim.system happens to do.
test("run_cmd_async: delivery is asynchronous even when on_exit fires inline", function()
  local calls = 0
  local orig = vim.system
  vim.system = function(_args, _opts, cb)
    cb({ stdout = "out", stderr = "", code = 0 })
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "true" }, 1000, function() calls = calls + 1 end)
    -- vim.schedule defers to the main loop, so nothing may have run yet.
    eq(calls, 0, "callback must not run inside run_cmd_async")
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "callback must run exactly once")
  end)
  vim.system = orig
  if not ok then error(err) end
end)

-- ── ENOENT: a genuinely missing executable, not a mocked throw ─────────────
-- vim.system() raises synchronously when the executable can't be found;
-- run_cmd_async promises to pcall that away and report it like a failed run
-- instead of letting the exception escape into a caller with no pcall of
-- its own (get_schema_batch_async callers, in particular).

test("run_cmd_async: a real nonexistent executable does not throw", function()
  local done, got = false, nil
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "dadbod-grip-test-nonexistent-cmd-93hjfd" }, 5000,
      function(stdout, stderr, code)
        got = { stdout = stdout, stderr = stderr, code = code }
        done = true
      end)
  end)
  assert(ok, "run_cmd_async must never throw for a missing executable: " .. tostring(err))
  eq(done, false, "callback must not fire on the calling tick")
  vim.wait(2000, function() return done end, 1)
  assert(done, "callback never fired")
  eq(got.code, 1, "missing executable reports a failed exit")
  contains(got.stderr, "ENOENT", "stderr carries the spawn error")
end)

-- A mocked twin of the real-ENOENT test above: vim.system throwing a
-- synthetic message, asserting the exactly-once delivery with an explicit
-- counter (the real test only tracks a "done" flag).
test("run_cmd_async: a spawn failure is reported once, asynchronously", function()
  local calls, got = 0, nil
  local orig = vim.system
  vim.system = function() error("ENOENT: no such file or directory") end
  local ok, err = pcall(function()
    adapters.run_cmd_async({ "nope" }, 50, function(_stdout, stderr, code)
      calls = calls + 1
      got = { stderr = stderr, code = code }
    end)
    eq(calls, 0, "spawn failure must not call back inline")
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "exactly one delivery")
    eq(got.code, 1, "reported as a failed exit")
    contains(got.stderr, "ENOENT", "carries the spawn error")
  end)
  vim.system = orig
  if not ok then error(err) end
end)

-- ── the watchdog: on_exit never arrives at all ──────────────────────────────
-- Mocked here (a real hung process would make this test as slow as the
-- timeout it's proving) -- vim.system's on_exit callback is simply never
-- invoked, so the watchdog is the only path to a delivered callback.

test("run_cmd_async: on_exit never firing still gets a timeout answer, once", function()
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  local calls, got = 0, nil
  vim.system = function(_args, _opts, _cb)
    -- No on_exit call, ever.
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "hang" }, 10, function(stdout, stderr, code)
      calls = calls + 1
      got = { stdout = stdout, stderr = stderr, code = code }
    end)
    vim.wait(2000, function() return got ~= nil end, 1)
    assert(got, "watchdog must deliver a callback")
    eq(got.code, 1, "timeout reports a failed exit")
    eq(got.stderr, "command timed out", "same message as the blocking path's fallback")
    eq(got.stdout, "", "no output")
    eq(calls, 1, "delivered exactly once")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- ── on_exit DOES fire: no second, watchdog-driven call ──────────────────────

test("run_cmd_async: on_exit firing normally suppresses the watchdog", function()
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  local calls = 0
  vim.system = function(_args, _opts, cb)
    vim.schedule(function() cb({ stdout = "ok", stderr = "", code = 0 }) end)
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "true" }, 10, function() calls = calls + 1 end)
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "delivered once via on_exit")
    -- Wait past the watchdog's deadline: a still-armed timer would fire again.
    vim.wait(300, function() return calls > 1 end, 1)
    eq(calls, 1, "the watchdog must not also deliver")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- The reverse order from the test above: here the watchdog fires *first*
-- (short grace, on_exit never called by the mock), and a captured on_exit
-- callback is then invoked by hand -- proving the deliver-once guard also
-- blocks a late spawn callback that arrives after the watchdog already
-- answered, not just a late watchdog after a normal on_exit.
test("run_cmd_async: a late on_exit after the watchdog does not deliver twice", function()
  local captured_on_exit
  local calls = 0
  local orig = vim.system
  local grace = adapters._exit_grace_ms
  vim.system = function(_args, _opts, cb)
    captured_on_exit = cb
    return { wait = function() end }
  end
  local ok, err = pcall(function()
    adapters._exit_grace_ms = 20
    adapters.run_cmd_async({ "slow" }, 10, function() calls = calls + 1 end)
    vim.wait(2000, function() return calls > 0 end, 1)
    eq(calls, 1, "watchdog delivered once")
    captured_on_exit({ stdout = "late", stderr = "", code = 0 })
    vim.wait(100, function() return calls > 1 end, 1)
    eq(calls, 1, "a late on_exit must be ignored")
  end)
  adapters._exit_grace_ms = grace
  vim.system = orig
  if not ok then error(err) end
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nrun_cmd_async_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
