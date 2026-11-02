-- Actual DuckDB lock ownership, not a favorable scheduler mock.
local adapter = require("dadbod-grip.adapters.duckdb")
local pass, fail = 0, 0
local root = vim.fn.tempname() .. "-duckdb-coordination"
vim.fn.mkdir(root, "p")

local function eq(a, b, label)
  assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local sequence = 0
local function fixture()
  sequence = sequence + 1
  local path = root .. "/fixture" .. sequence .. ".duckdb"
  local r = vim.system({ "duckdb", "-bail", path }, {
    stdin = "CREATE TABLE items(id INTEGER PRIMARY KEY, value VARCHAR); INSERT INTO items VALUES (1, 'before');",
    text = true,
  }):wait()
  eq(r.code, 0, r.stderr)
  return path, "duckdb:" .. path
end

-- A real CLI evaluates its actual metadata SQL, then keeps stdin open. DuckDB
-- retains its database lock until EOF. The timer closes that same pipe once;
-- no user SQL is replayed, and the test can observe real on_exit ownership.
local function with_held_first(path, fn)
  local original = vim.system
  local original_wait = vim.wait
  local held, alive, marker, starts, overlaps = nil, false, path .. ".ready", 0, 0
  local calls = {}
  vim.system = function(args, opts, callback)
    if args[1] ~= "duckdb" then return original(args, opts, callback) end
    starts = starts + 1
    calls[#calls + 1] = vim.deepcopy(args)
    if held and alive then overlaps = overlaps + 1 end
    if not held and args[#args] == path then
      local changed = vim.tbl_extend("force", {}, opts, { stdin = true })
      held = original(args, changed, function(result)
        alive = false
        if callback then callback(result) end
      end)
      alive = true
      held:write(opts.stdin .. "\n;\nCOPY (SELECT 1) TO '" .. marker:gsub("'", "''") .. "';\n")
      return held
    end
    return original(args, opts, callback)
  end
  local control = {
    ready = function() return vim.fn.filereadable(marker) == 1 end,
    alive = function() return alive end,
    release = function() if held then held:write(nil) end end,
    starts = function() return starts end,
    overlaps = function() return overlaps end,
    calls = function() return calls end,
  }
  local ok, err = xpcall(function() fn(control) end, debug.traceback)
  vim.system = original
  vim.wait = original_wait
  if held then pcall(held.write, held, nil); pcall(held.wait, held, 1000) end
  if not ok then error(err) end
end

test("async schema and foreground read never overlap the same native file", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    local callbacks = 0
    adapter.get_schema_batch_async(url, function() callbacks = callbacks + 1 end)
    assert(vim.wait(2000, c.ready, 1), "metadata child never acquired the fixture")
    vim.defer_fn(c.release, 80)
    local result, err = adapter.query("SELECT value FROM items", url)
    assert(result, err)
    eq(result.rows[1][1], "before")
    eq(c.overlaps(), 0, "live same-file CLI overlap")
    assert(vim.wait(2000, function() return callbacks == 1 end, 1), "schema callback missing")
  end)
end)

test("async schema and foreground write execute once without a lock error", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata child never acquired the fixture")
    vim.defer_fn(c.release, 80)
    local result, err = adapter.execute("UPDATE items SET value = value || 'x' WHERE id = 1", url)
    assert(result, err)
    eq(c.overlaps(), 0, "live same-file CLI overlap")
    local rows = assert(adapter.query("SELECT value FROM items", url))
    eq(rows.rows[1][1], "beforex", "one original write")
  end)
end)

test("symlink aliases share the native file lane", function()
  local path, url = fixture()
  local alias = path .. ".alias"
  assert(vim.uv.fs_symlink(path, alias))
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata child never acquired the fixture")
    vim.defer_fn(c.release, 80)
    local result, err = adapter.query("SELECT id FROM items", "duckdb:" .. alias)
    assert(result, err)
    eq(result.rows[1][1], "1")
    eq(c.overlaps(), 0, "live alias CLI overlap")
  end)
end)

test("independent physical files progress while metadata still owns another file", function()
  local path, url = fixture()
  local _, other = fixture()
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata child never acquired the fixture")
    vim.defer_fn(c.release, 300)
    local result, err = adapter.query("SELECT id FROM items", other)
    assert(result, err)
    eq(c.alive(), true, "unrelated query must finish before held metadata is released")
  end)
end)

test("nested synchronous query proceeds after native exit without waiting for outer Lua return", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    local nested, nested_err, nested_done
    vim.defer_fn(function()
      assert(vim.wait(2000, c.ready, 1), "outer child never acquired the fixture")
      nested, nested_err = adapter.query("SELECT id FROM items", url)
      nested_done = true
    end, 10)
    vim.defer_fn(c.release, 100)
    local outer, err = adapter.query("SELECT value FROM items", url)
    assert(outer, err)
    assert(vim.wait(2000, function() return nested_done end, 1), "nested query deadlocked")
    assert(nested, nested_err)
    eq(c.overlaps(), 0, "nested native CLI overlap")
  end)
end)

test("registered shared attachments are acquired atomically across different main files", function()
  local path, url = fixture()
  local _, other = fixture()
  local shared = fixture()
  adapter._attach_unchecked(url, shared, "shared_a")
  adapter._attach_unchecked(other, shared, "shared_b")
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "attached metadata never acquired its native files")
    vim.defer_fn(c.release, 80)
    local result, err = adapter.query("SELECT value FROM shared_b.items", other)
    assert(result, err)
    eq(result.rows[1][1], "before")
    eq(c.overlaps(), 0, "registered shared-file CLI overlap")
  end)
end)

test("cancelling running metadata does not admit foreground work before actual reap", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    local callbacks = 0
    local handle = adapter.get_schema_batch_async(url, function() callbacks = callbacks + 1 end)
    assert(vim.wait(2000, c.ready, 1), "metadata never acquired its native file")
    assert(handle and handle.cancel(), "metadata cancellation handle missing")
    local result, err = adapter.query("SELECT id FROM items", url)
    assert(result, err)
    eq(result.rows[1][1], "1")
    eq(c.overlaps(), 0, "foreground admitted before cancelled child reaped")
    assert(vim.wait(2000, function() return callbacks == 1 end, 1))
  end)
end)

test("cancelling queued metadata never starts its original statement", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata never acquired its native file")
    local callbacks, got = 0, "not-called"
    local handle = adapter.get_schema_batch_async(url, function(result) callbacks = callbacks + 1; got = result end)
    assert(handle and handle.cancel(), "queued metadata cancellation handle missing")
    assert(vim.wait(1000, function() return callbacks == 1 end, 1))
    eq(got, nil, "cancelled metadata has no successful result")
    eq(c.starts(), 1, "queued metadata must not spawn")
    c.release()
    vim.wait(100, function() return not c.alive() end, 1)
    eq(c.starts(), 1, "cancelled ticket must not be admitted after prior exit")
  end)
end)

test("queued metadata retains read-only options captured before connection context changes", function()
  local path, url = fixture()
  local adapters = require("dadbod-grip.adapters")
  with_held_first(path, function(c)
    local previous = adapters.set_call_readonly(false)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata never acquired its native file")
    adapters.set_call_readonly(true)
    local done = false
    adapter.get_schema_batch_async(url, function() done = true end)
    adapters.set_call_readonly(previous)
    eq(c.starts(), 1, "read-only metadata must queue")
    c.release()
    assert(vim.wait(2000, function() return done end, 1))
    eq(c.starts(), 2)
    eq(vim.tbl_contains(c.calls()[2], "-readonly"), true, "queued argv retains read-only mode")
    eq(c.overlaps(), 0)
  end)
end)

test("native queued timeout never starts or later replays the write", function()
  local path, url = fixture()
  local queue = require("dadbod-grip.duckdb_queue")
  local adapters = require("dadbod-grip.adapters")
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata never acquired its native file")
    local grace, started, settled, refused = adapters._exit_grace_ms, 0, 0, 0
    adapters._exit_grace_ms = 10
    local _, _, code = queue.run(queue.keys({ path }), { "duckdb", "-bail", path }, 10, {
      stdin = "UPDATE items SET value = 'must-not-run' WHERE id = 1;",
      on_start = function() started = started + 1 end,
      on_complete = function() settled = settled + 1 end,
      on_spawn_error = function() refused = refused + 1 end,
    })
    adapters._exit_grace_ms = grace
    eq(code, 124); eq(started, 0); eq(settled, 1); eq(refused, 1); eq(c.starts(), 1)
    c.release()
    assert(vim.wait(2000, function() return not c.alive() end, 1))
    local result, err = adapter.query("SELECT value FROM items", url)
    assert(result, err); eq(result.rows[1][1], "before", "timed-out write cannot run later")
    eq(c.starts(), 2, "only metadata and oracle read started")
  end)
end)

test("controlled Ctrl-C before admission never submits a native write", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    adapter.get_schema_batch_async(url, function() end)
    assert(vim.wait(2000, c.ready, 1), "metadata never acquired its native file")
    local wait = vim.wait
    vim.wait = function() return false, -2 end
    local result, err = adapter.execute("UPDATE items SET value = 'must-not-run' WHERE id = 1", url)
    vim.wait = wait
    eq(result, nil); assert(err:find("before execution", 1, true)); eq(c.starts(), 1)
    c.release()
    assert(vim.wait(2000, function() return not c.alive() end, 1))
    local oracle = assert(adapter.query("SELECT value FROM items", url))
    eq(oracle.rows[1][1], "before"); eq(c.starts(), 2)
  end)
end)

test("controlled active interruption reaps the real writer without replaying its committed SQL", function()
  local path, url = fixture()
  with_held_first(path, function(c)
    local wait, interrupted = vim.wait, false
    vim.wait = function(ms, predicate, interval)
      if not interrupted then
        assert(wait(2000, c.ready, 1), "writer never executed its actual SQL")
        interrupted = true
        return false, -2
      end
      return wait(ms, predicate, interval)
    end
    local result, err = adapter.execute("UPDATE items SET value = value || 'x' WHERE id = 1", url)
    vim.wait = wait
    eq(result, nil); assert(err:find("database outcome unknown", 1, true))
    eq(c.alive(), false, "interrupted writer must be reaped before it returns")
    local oracle = assert(adapter.query("SELECT value FROM items", url))
    eq(oracle.rows[1][1], "beforex", "one actual committed write, no retry")
    eq(c.overlaps(), 0)
  end)
end)

vim.fn.delete(root, "rf")
print(string.format("\nduckdb_coordination_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
