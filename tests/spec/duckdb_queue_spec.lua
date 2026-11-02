-- Controlled process-boundary models supplement the separate native CLI suite.
local queue = require("dadbod-grip.duckdb_queue")
local adapters = require("dadbod-grip.adapters")
local pass, fail, serial = 0, 0, 0
local function eq(a, b, label)
  assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function model(fn)
  local original = vim.system
  local jobs = {}
  vim.system = function(args, opts, callback)
    local job = { args = args, opts = opts, callback = callback, exits = 0, signals = {} }
    jobs[#jobs + 1] = job
    function job.finish(code)
      if job.exits > 0 then return end
      job.exits = job.exits + 1
      callback({ stdout = "", stderr = "", code = code or 0 })
    end
    return { kill = function(_, signal) job.signals[#job.signals + 1] = signal end }
  end
  serial = serial + 1
  local prefix = "model-" .. serial .. ":"
  local ok, err = xpcall(function() fn(jobs, function(name) return prefix .. name end) end, debug.traceback)
  for _, job in ipairs(jobs) do job.finish() end
  vim.wait(30, function() return false end, 1)
  vim.system = original
  if not ok then error(err) end
end
local function until_count(jobs, count)
  assert(vim.wait(1000, function() return #jobs == count end, 1), "process admission count " .. count)
end

test("FIFO shared-file ordering and unrelated progress", function()
  model(function(jobs, key)
    local callbacks = 0
    queue.run_async({ key("a") }, { "duckdb", "first" }, 1000, function() callbacks = callbacks + 1 end)
    queue.run_async({ key("a") }, { "duckdb", "second" }, 1000, function() callbacks = callbacks + 1 end)
    queue.run_async({ key("a") }, { "duckdb", "third" }, 1000, function() callbacks = callbacks + 1 end)
    queue.run_async({ key("b") }, { "duckdb", "independent" }, 1000, function() callbacks = callbacks + 1 end)
    until_count(jobs, 2)
    eq(jobs[1].args[2], "first"); eq(jobs[2].args[2], "independent")
    jobs[1].finish(); until_count(jobs, 3); eq(jobs[3].args[2], "second")
    jobs[3].finish(); until_count(jobs, 4); eq(jobs[4].args[2], "third")
    jobs[2].finish(); jobs[4].finish()
    assert(vim.wait(1000, function() return callbacks == 4 end, 1))
  end)
end)

test("reversed multi-file requests acquire all lanes together without deadlock", function()
  model(function(jobs, key)
    queue.run_async({ key("a"), key("b") }, { "duckdb", "ab" }, 1000, function() end)
    queue.run_async({ key("b"), key("a") }, { "duckdb", "ba" }, 1000, function() end)
    queue.run_async({ key("b") }, { "duckdb", "b" }, 1000, function() end)
    eq(#jobs, 1)
    jobs[1].finish(); until_count(jobs, 2); eq(jobs[2].args[2], "ba")
    jobs[2].finish(); until_count(jobs, 3); eq(jobs[3].args[2], "b")
    jobs[3].finish()
  end)
end)

test("queued cancellation reports once and never submits that original", function()
  model(function(jobs, key)
    local calls, code = 0
    queue.run_async({ key("a") }, { "duckdb", "held" }, 1000, function() end)
    local cancelled = queue.run_async({ key("a") }, { "duckdb", "cancelled" }, 1000,
      function(_, _, value) calls = calls + 1; code = value end)
    eq(cancelled.cancel(), true); eq(cancelled.cancel(), false); eq(cancelled.reaped(), true)
    assert(vim.wait(1000, function() return calls == 1 end, 1)); eq(code, 130); eq(#jobs, 1)
    jobs[1].finish(); vim.wait(30, function() return #jobs > 1 end, 1)
    eq(#jobs, 1); eq(calls, 1)
  end)
end)

test("active cancellation cannot release a lane before late completion", function()
  model(function(jobs, key)
    local calls, code = 0
    local first = queue.run_async({ key("a") }, { "duckdb", "held" }, 1000,
      function(_, _, value) calls = calls + 1; code = value end)
    queue.run_async({ key("a") }, { "duckdb", "next" }, 1000, function() end)
    eq(first.cancel(), true); eq(first.reaped(), false)
    vim.wait(30, function() return #jobs > 1 end, 1); eq(#jobs, 1); eq(calls, 0)
    jobs[1].finish(); until_count(jobs, 2)
    assert(vim.wait(1000, function() return calls == 1 end, 1)); eq(code, 130)
    jobs[2].finish()
  end)
end)

test("a watchdog answer quarantines the lane until actual completion", function()
  local grace = adapters._exit_grace_ms
  adapters._exit_grace_ms = 10
  local ok, err = xpcall(function()
    model(function(jobs, key)
      local calls, code = 0
      local first = queue.run_async({ key("a") }, { "duckdb", "late-exit" }, 10,
        function(_, _, value) calls = calls + 1; code = value end)
      queue.run_async({ key("a") }, { "duckdb", "next" }, 1000, function() end)
      assert(vim.wait(1000, function() return calls == 1 end, 1)); eq(code, 1)
      eq(#jobs, 1); eq(first.reaped(), false)
      jobs[1].finish(); until_count(jobs, 2); eq(first.reaped(), true)
      vim.wait(30, function() return calls > 1 end, 1); eq(calls, 1)
      jobs[2].finish()
    end)
  end, debug.traceback)
  adapters._exit_grace_ms = grace
  if not ok then error(err) end
end)

test("queued synchronous cancellation proves not-started lifecycle", function()
  model(function(jobs, key)
    queue.run_async({ key("a") }, { "duckdb", "held" }, 1000, function() end)
    local wait = vim.wait
    vim.wait = function() return false, -2 end
    local started, failed, settled = 0, 0, 0
    local out, err, code = queue.run({ key("a") }, { "duckdb", "never" }, 1000, {
      on_start = function() started = started + 1 end,
      on_spawn_error = function() failed = failed + 1 end,
      on_complete = function() settled = settled + 1 end,
    })
    vim.wait = wait
    eq(out, ""); eq(code, 130); assert(err:find("before execution", 1, true))
    eq(started, 0); eq(failed, 1); eq(settled, 1); eq(#jobs, 1)
    jobs[1].finish()
  end)
end)

test("completed synchronous result survives a later waiter interruption", function()
  local async, run, wait = adapters.run_cmd_async, adapters.run_cmd, vim.wait
  local starts, executed, release_first, release_last = 0, 0
  adapters.run_cmd_async = function(_, _, _, opts)
    starts = starts + 1
    if starts == 1 then release_first = opts.on_complete else release_last = opts.on_complete end
    opts.on_start({})
    return { cancel = function() return true end }
  end
  adapters.run_cmd = function(_, _, opts)
    executed = executed + 1; opts.on_start({}); opts.on_complete()
    return "completed", "", 0
  end
  local ok, err = xpcall(function()
    queue.run_async({ "admission-interrupt" }, { "held" }, 1000, function() end)
    vim.wait = function(_, predicate)
      release_first()
      assert(wait(100, predicate, 1), "synchronous operation did not complete")
      return false, -2
    end
    local output, message, code = queue.run({ "admission-interrupt" }, { "completed" }, 1000)
    vim.wait = wait
    eq(executed, 1); eq(code, 0); eq(output, "completed"); eq(message, "")
    queue.run_async({ "admission-interrupt" }, { "later" }, 1000, function() end)
    wait(30, function() return starts == 2 end, 1)
    eq(starts, 2, "completed operation must release its lane")
  end, debug.traceback)
  adapters.run_cmd_async, adapters.run_cmd, vim.wait = async, run, wait
  if release_last then release_last() end
  if not ok then error(err) end
end)

test("unexpected Lua failure before spawn propagates and releases only its unstarted lane", function()
  local run, async = adapters.run_cmd, adapters.run_cmd_async
  local later, release_later = 0
  adapters.run_cmd = function() error("model Lua interruption") end
  adapters.run_cmd_async = function(_, _, _, opts)
    later = later + 1; release_later = opts.on_complete; opts.on_start({})
    return { cancel = function() return true end }
  end
  local ok, err = xpcall(function()
    local success, message = pcall(queue.run, { "unstarted-Lua-failure" }, { "never" }, 1000)
    eq(success, false); assert(tostring(message):find("model Lua interruption", 1, true))
    queue.run_async({ "unstarted-Lua-failure" }, { "later" }, 1000, function() end)
    eq(later, 1)
  end, debug.traceback)
  adapters.run_cmd, adapters.run_cmd_async = run, async
  if release_later then release_later() end
  if not ok then error(err) end
end)

test("unexpected Lua failure after a start retains the lane until completion", function()
  local run, async = adapters.run_cmd, adapters.run_cmd_async
  local later, complete, release_later = 0
  adapters.run_cmd = function(_, _, opts)
    complete = opts.on_complete; opts.on_start({}); error("model failure after start")
  end
  adapters.run_cmd_async = function(_, _, _, opts)
    later = later + 1; release_later = opts.on_complete; opts.on_start({})
    return { cancel = function() return true end }
  end
  local ok, err = xpcall(function()
    local success, message = pcall(queue.run, { "started-Lua-failure" }, { "started" }, 1000)
    eq(success, false); assert(tostring(message):find("model failure after start", 1, true))
    queue.run_async({ "started-Lua-failure" }, { "later" }, 1000, function() end)
    eq(later, 0, "a Lua error is not proof that the child exited")
    complete()
    assert(vim.wait(1000, function() return later == 1 end, 1))
  end, debug.traceback)
  adapters.run_cmd, adapters.run_cmd_async = run, async
  if complete then complete() end
  if release_later then release_later() end
  if not ok then error(err) end
end)

print(string.format("\nduckdb_queue_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
