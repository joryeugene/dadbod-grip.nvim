-- connections_spec.lua -- characterization tests for M.switch()'s single-pass
-- read/mutate/write behavior (see history.lua's task-8 companion refactor).
-- M.switch() used to read the local connections file up to 4 times and write
-- it up to twice per call; it now reads once (plus the global file, but only
-- when actually needed for type resolution) and writes at most once. These
-- tests pin the observable behavior of that rewrite against real files in an
-- isolated temp directory, since nothing in the suite previously exercised it.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

-- Rebound to a freshly loaded module by every with_real_file() below, because
-- connections.lua keeps per-URL health in a module-local table with no reset
-- hook: without the reload, a switch() in one test leaves its URL marked "ok"
-- for every later case.
local connections = require("dadbod-grip.connections")

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

-- ── real-file harness ────────────────────────────────────────────────────
-- M.switch() is heavily side-effecting: it opens the grid/schema/query pad
-- via vim.schedule(). These tests only care about the synchronous file-write
-- behavior, so UI-facing modules are stubbed to no-ops. Pending vim.schedule
-- callbacks are flushed with vim.wait() *before* teardown (while the stubs
-- and the fake project/home dirs are still live), so nothing fires later
-- against an already-deleted temp directory or a restored real module.
--
-- Isolation notes:
-- - paths.project_root is patched (not paths.grip_dir): connections.lua
--   captures `local grip_dir = paths.grip_dir` at require time, so patching
--   the grip_dir *field* on the module later would not affect that alias.
--   The captured function still calls `M.project_root()` dynamically though,
--   so patching project_root reaches it either way.
-- - vim.fn.expand("~") is patched to a fake home so the global connections
--   file used by tests never touches the real ~/.grip/connections.json.
-- - the module under test is reloaded per call so its module-local state
--   (notably the _health table set_health writes to) starts empty; the
--   file-level `connections` alias is rebound to that instance.
local function with_real_file(fn)
  local project_dir = vim.fn.tempname() .. "_grip_conn_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_opts = grip.get_opts()
  local orig_open = grip.open
  local orig_open_welcome = grip.open_welcome
  local orig_schema = package.loaded["dadbod-grip.schema"]
  local orig_query_pad = package.loaded["dadbod-grip.query_pad"]
  local orig_completion = package.loaded["dadbod-grip.completion"]
  local orig_duckdb = package.loaded["dadbod-grip.adapters.duckdb"]
  local orig_connections = package.loaded["dadbod-grip.connections"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({}) -- deterministic OPTS baseline (connections_path = nil, etc.)
  grip.open = function() end
  grip.open_welcome = function() end
  package.loaded["dadbod-grip.schema"] = {
    is_open = function() return true end,
    refresh = function() end,
    toggle = function() end,
    get_winid = function() return nil end,
  }
  package.loaded["dadbod-grip.query_pad"] = { open = function() end }
  package.loaded["dadbod-grip.completion"] = { invalidate = function() end, warm_schema = function() end }
  package.loaded["dadbod-grip.adapters.duckdb"] = { load_attachments = function() end }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")

  local local_grip = project_dir .. "/.grip"
  local global_grip = fake_home .. "/.grip"
  local ok, err = pcall(fn, local_grip, global_grip)
  vim.wait(50) -- flush any vim.schedule() callbacks queued by switch()

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  grip.setup(orig_opts)
  grip.open = orig_open
  grip.open_welcome = orig_open_welcome
  package.loaded["dadbod-grip.schema"] = orig_schema
  package.loaded["dadbod-grip.query_pad"] = orig_query_pad
  package.loaded["dadbod-grip.completion"] = orig_completion
  package.loaded["dadbod-grip.adapters.duckdb"] = orig_duckdb
  package.loaded["dadbod-grip.connections"] = orig_connections
  connections = orig_connections

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

local function read_connections_json(dir)
  return vim.fn.json_decode(table.concat(vim.fn.readfile(dir .. "/connections.json"), "\n"))
end

-- ── switching to an existing connection (by name, and without one) ────────

test("switch: switching to an existing connection by name upserts + touches, single write", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry, renamed not duplicated")
    eq(data[1].name, "mydb", "renamed")
    eq(data[1].url, "postgresql://u:p@h/db", "url unchanged")
    eq(data[1].type, "postgresql", "type unchanged")
    assert(data[1].last_used > 100, "last_used touched")
  end)
end)

test("switch: switching to an existing connection without a name still touches last_used", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "saved-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")

    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})

    local data = read_connections_json(local_grip)
    eq(#data, 1, "still one entry")
    eq(data[1].name, "saved-name", "name preserved (no rename requested)")
    assert(data[1].last_used > 100, "last_used touched even without a name")
  end)
end)

-- ── write is skipped when nothing changed, happens when it did ────────────

test("switch: write is skipped when nothing changed (unnamed, not-yet-saved URL)", function()
  with_real_file(function(local_grip)
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(vim.fn.filereadable(local_grip .. "/connections.json"), 0,
      "no connections.json created -- nothing to persist for a nameless, unsaved connection")
  end)
end)

test("switch: write happens when a name is given for a brand-new URL", function()
  with_real_file(function(local_grip)
    -- Note: the persisted `type` field comes from is_file_url(), not the
    -- conn_type parameter -- that's pre-existing M.add() behavior, unchanged
    -- by this refactor. postgresql:// isn't a file url, so type stays nil.
    connections.switch("postgresql://u:p@h/db", "brand-new", "postgresql", {})
    local data = read_connections_json(local_grip)
    eq(#data, 1, "inserted")
    eq(data[1].name, "brand-new", "name")
    eq(data[1].type, nil, "type field derives from is_file_url, not conn_type")
  end)
end)

-- ── module-local health state does not leak between tests ─────────────────
-- Placed after the switch() cases above on purpose: they all switch to this
-- same URL, so without the per-test module reload in with_real_file the first
-- assertion below reads their leftover "ok" instead of a clean slate.

test("switch: health state starts clean in every test, then switch records it", function()
  with_real_file(function()
    eq(connections.get_health("postgresql://u:p@h/db"), "unknown",
      "no health carried in from an earlier test's switch()")
    connections.switch("postgresql://u:p@h/db", nil, "postgresql", {})
    eq(connections.get_health("postgresql://u:p@h/db"), "ok", "switch marks the connection healthy")
  end)
end)

-- ── global file consulted only when the gate allows it ─────────────────────
-- Signal: the only externally-observable trace of resolved_type is the
-- notify message ("opening" for type == "file" vs "connected to" otherwise).
-- customscheme:// is not detected as a file url by the is_file_url()
-- heuristic, so seeding the global file with type = "file" for it makes the
-- notify text a faithful proxy for "was the global file's type honored".

test("switch: global file is consulted when no local match and no configured path", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    assert(#notified > 0 and notified[1]:find("opening", 1, true),
      "type resolved from global file, file-open branch should have run: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when connections_path is configured", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    grip.setup({ connections_path = local_grip .. "/connections.json" })

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "global type must be ignored when connections_path is configured: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when conn_type is already given", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, "postgresql", {})

    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "explicit conn_type param must win over global lookup: " .. vim.inspect(notified))
  end)
end)

test("switch: global file is not consulted when the type is already known locally", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(local_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "local", url = "customscheme://host/db", type = "postgresql", last_used = 1 },
    }) }, local_grip .. "/connections.json")
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "g", url = "customscheme://host/db", type = "file" },
    }) }, global_grip .. "/connections.json")

    local notified = {}
    vim.notify = function(msg) table.insert(notified, msg) end

    connections.switch("customscheme://host/db", nil, nil, {})

    assert(#notified > 0 and notified[1]:find("connected to", 1, true),
      "locally-known type must win over global lookup: " .. vim.inspect(notified))
  end)
end)

-- ── attachments-restore reads the pre-mutation snapshot ────────────────────

test("switch: attachments-restore reads the pre-mutation snapshot (rename doesn't disturb .attachments)", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old", url = "duckdb:/tmp/some.duckdb", type = "duckdb",
        attachments = { "foo.duckdb", "bar.duckdb" }, last_used = 100 },
    }) }, local_grip .. "/connections.json")

    local captured_url, captured_atts
    package.loaded["dadbod-grip.adapters.duckdb"] = {
      load_attachments = function(u, atts) captured_url, captured_atts = u, atts end,
    }

    connections.switch("duckdb:/tmp/some.duckdb", "renamed", "duckdb", {})

    eq(captured_url, "duckdb:/tmp/some.duckdb", "load_attachments called with the right url")
    assert(captured_atts ~= nil, "attachments were restored")
    eq(#captured_atts, 2, "both attachments survived the rename")
    eq(captured_atts[1], "foo.duckdb", "attachment 1")
    eq(captured_atts[2], "bar.duckdb", "attachment 2")

    local data = read_connections_json(local_grip)
    eq(data[1].name, "renamed", "renamed on disk")
    eq(#data[1].attachments, 2, "attachments preserved on disk too")
  end)
end)

-- ── output format matches the pre-refactor multi-pass sequence ─────────────
-- The old M.switch() body was, in effect, M.add(name, url) followed by
-- M.touch(url) -- two separate read+write round trips. M.add()/M.touch()
-- still exist with that exact behavior (now built on the same upsert_conn/
-- touch_conn helpers switch() uses in memory), so running them back-to-back
-- characterizes what the old switch() wrote. os.time() is pinned so both
-- sequences produce the exact same last_used and can be compared byte-for-byte.

test("switch: resulting file is byte-identical to the old add()+touch() sequence for the same inputs", function()
  local orig_os_time = os.time
  -- luacheck: push ignore 122
  os.time = function() return 1700000000 end

  local old_content, new_content
  local seed = { { name = "old-name", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 } }

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.add("mydb", "postgresql://u:p@h/db")
    connections.touch("postgresql://u:p@h/db")
    old_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode(seed) }, local_grip .. "/connections.json")
    connections.switch("postgresql://u:p@h/db", "mydb", "postgresql", {})
    new_content = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
  end)

  os.time = orig_os_time
  -- luacheck: pop

  eq(old_content, new_content, "byte-identical output for the same logical mutation")
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nconnections_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
