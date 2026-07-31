-- readonly_mode_spec.lua -- a connection saved with "mode": "ro" puts the
-- database CLI itself in read-only mode and makes the schema-modifying
-- commands decline before they prompt.
--
-- The adapter cases call the argv/env builders directly with an explicit opts
-- table rather than going through a connection, because the load-bearing part
-- is *which flags are produced*: `duckdb -readonly` on :memory: aborts with
-- "Cannot launch in-memory database in read-only mode!", and both sqlite3 and
-- duckdb refuse to open a not-yet-existing file read-only instead of creating
-- it. All four builders are pure, so the assertions can be exact.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

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

-- ── adapter argv / env builders ───────────────────────────────────────────

test("postgres ro sets PGOPTIONS", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local env = pg._psql_env("postgresql://u:p@h/db", { readonly = true })
  assert(env.PGOPTIONS and env.PGOPTIONS:find("default_transaction_read_only=on", 1, true),
    "PGOPTIONS set, got: " .. tostring(env.PGOPTIONS))
end)

test("postgres rw does not set PGOPTIONS", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  eq(pg._psql_env("postgresql://u:p@h/db", {}).PGOPTIONS, nil, "absent in rw")
end)

test("postgres ro still delivers the password out of band", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local env = pg._psql_env("postgresql://u:s3cr3t@h/db", { readonly = true })
  eq(env.PGPASSWORD, "s3cr3t", "PGPASSWORD survives alongside PGOPTIONS")
end)

test("mysql merges rather than duplicates --init-command", function()
  local my = require("dadbod-grip.adapters.mysql")
  local args = my._mysql_args({ host = "h" }, "select 1", { readonly = true })
  local n = 0
  for _, a in ipairs(args) do
    if tostring(a):match("^%-%-init%-command=") then n = n + 1 end
  end
  eq(n, 1, "exactly one --init-command (a second one would overwrite the first)")
  local found = false
  for _, a in ipairs(args) do
    if tostring(a):find("TRANSACTION READ ONLY", 1, true)
       and tostring(a):find("ANSI_QUOTES", 1, true) then found = true end
  end
  assert(found, "both the sql_mode and the read-only statement survive the merge")
end)

test("mysql rw leaves the init-command alone", function()
  local my = require("dadbod-grip.adapters.mysql")
  local args = my._mysql_args({ host = "h" }, "select 1", {})
  for _, a in ipairs(args) do
    assert(not tostring(a):find("TRANSACTION READ ONLY", 1, true),
      "no read-only statement in rw, got: " .. tostring(a))
  end
  eq(args[3], "--init-command=SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES'",
    "rw argv is byte-identical to what it was before read-only mode existed")
end)

test("duckdb never passes -readonly for :memory:", function()
  local dd = require("dadbod-grip.adapters.duckdb")
  local args = dd._args("duckdb::memory:", { readonly = true })
  for _, a in ipairs(args) do
    assert(a ~= "-readonly", "-readonly on :memory: aborts duckdb entirely")
  end
end)

test("duckdb passes -readonly for an existing file", function()
  local dd = require("dadbod-grip.adapters.duckdb")
  local f = vim.fn.tempname() .. ".duckdb"
  vim.fn.writefile({ "" }, f)
  local args = dd._args("duckdb:" .. f, { readonly = true })
  local found = false
  for _, a in ipairs(args) do if a == "-readonly" then found = true end end
  assert(found, "-readonly applied to an existing file")
  vim.fn.delete(f)
end)

test("duckdb never passes -readonly for a missing file", function()
  local dd = require("dadbod-grip.adapters.duckdb")
  local f = vim.fn.tempname() .. ".duckdb"
  local args = dd._args("duckdb:" .. f, { readonly = true })
  for _, a in ipairs(args) do
    assert(a ~= "-readonly", "-readonly would turn create-on-open into an error")
  end
end)

test("duckdb rw argv is unchanged", function()
  local dd = require("dadbod-grip.adapters.duckdb")
  local f = vim.fn.tempname() .. ".duckdb"
  vim.fn.writefile({ "" }, f)
  eq(table.concat(dd._args("duckdb:" .. f, {}, { "-csv", "-header" }), " "),
    "duckdb -csv -header " .. f, "rw file-backed argv")
  eq(table.concat(dd._args("duckdb::memory:", {}, { "-csv", "-header" }), " "),
    "duckdb -csv -header", "rw :memory: argv carries no path")
  vim.fn.delete(f)
end)

test("sqlite never passes -readonly for a missing file", function()
  local sq = require("dadbod-grip.adapters.sqlite")
  local args = sq._sqlite3_args("/nonexistent/db.sqlite", "select 1", { readonly = true })
  for _, a in ipairs(args) do
    assert(a ~= "-readonly", "-readonly would turn create-on-open into an error")
  end
end)

test("sqlite passes -readonly for an existing file", function()
  local sq = require("dadbod-grip.adapters.sqlite")
  local f = vim.fn.tempname() .. ".sqlite"
  vim.fn.writefile({ "" }, f)
  local args = sq._sqlite3_args(f, "select 1", { readonly = true })
  local found = false
  for i, a in ipairs(args) do
    if a == "-readonly" then
      found = true
      -- sqlite3 takes its options before the database file.
      assert(i < #args - 1, "-readonly must precede the db path and the statement")
    end
  end
  assert(found, "-readonly applied to an existing file")
  eq(args[#args - 1], f, "db path still second-to-last")
  eq(args[#args], "select 1", "statement still last")
  vim.fn.delete(f)
end)

test("sqlite rw argv is unchanged", function()
  local sq = require("dadbod-grip.adapters.sqlite")
  local f = vim.fn.tempname() .. ".sqlite"
  vim.fn.writefile({ "" }, f)
  eq(table.concat(sq._sqlite3_args(f, "select 1", {}), "|"),
    table.concat({ "sqlite3", "-init", "", "-csv", "-header", f, "select 1" }, "|"),
    "rw argv is byte-identical to what it was before read-only mode existed")
  vim.fn.delete(f)
end)

-- ── the grid state ────────────────────────────────────────────────────────

test("data.new honors an explicit readonly flag", function()
  local data = require("dadbod-grip.data")
  local base = { rows = { { "1" } }, columns = { "id" }, primary_keys = { "id" },
                 table_name = "users", url = "sqlite:/tmp/x.db", sql = "select 1" }
  eq(data.new(base).readonly, false, "a table with a PK is editable by default")
  base.readonly = true
  eq(data.new(base).readonly, true, "an explicit readonly wins over having a PK")
end)

-- ── connections.current_mode ──────────────────────────────────────────────
-- Isolation follows connections_spec.lua: paths.project_root and the fake
-- home are patched so the real ~/.grip and the repo's own .grip are never
-- read, and grip.setup({}) pins connections_path = nil.

local RO_URL = "postgresql://u:p@h/ro_db"
local RW_URL = "postgresql://u:p@h/rw_db"
local BARE_URL = "postgresql://u:p@h/bare_db"
-- A ro entry whose secret cannot resolve, for the failed-switch case, and a
-- ro entry with a production-length name and host, for the picker row.
local UNRESOLVABLE_URL = "postgresql://u:${GRIP_NO_SUCH_VAR_FOR_TESTS}@h/locked_db"
-- Same shape, but the variable is one the test sets and then removes.
local TEMPLATED_URL = "postgresql://u:${GRIP_TEST_PW}@h/tpl_db"
local LONG_RO_URL =
  "postgresql://warehouse_reader:hunter2@db-prod-analytics.eu-central-1.example.com:5432/warehouse"
local LONG_RO_NAME = "prod-warehouse-readonly"

--- Run fn with a connections.json holding one ro, one rw and one entry with
--- no mode field at all (what every file written before this option looks
--- like), and vim.g.db pointing at `initial_url`.
---
--- Two sqlite entries, one ro and one rw, back the end-to-end argv tests: they
--- need a URL whose adapter actually reaches an argv builder, and a database
--- file that exists (the `-readonly` flag is withheld for a missing one). The
--- files are empty -- run_cmd is stubbed in those tests, so sqlite3 never runs
--- against them. fn receives their two URLs.
local function with_connections(initial_url, fn)
  local project_dir = vim.fn.tempname() .. "_grip_ro_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir .. "/.grip", "p")
  vim.fn.mkdir(fake_home .. "/.grip", "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_b_db = vim.b.db
  local orig_opts = grip.get_opts()

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  grip.setup({})
  local ro_sqlite = "sqlite:" .. project_dir .. "/ro.sqlite"
  local rw_sqlite = "sqlite:" .. project_dir .. "/rw.sqlite"
  vim.fn.writefile({ "" }, project_dir .. "/ro.sqlite")
  vim.fn.writefile({ "" }, project_dir .. "/rw.sqlite")
  vim.fn.writefile({ vim.fn.json_encode({
    { name = "ro-db",     url = RO_URL,   type = "postgresql", mode = "ro" },
    { name = "rw-db",     url = RW_URL,   type = "postgresql", mode = "rw" },
    { name = "bare-db",   url = BARE_URL, type = "postgresql" },
    { name = "ro-sqlite", url = ro_sqlite, type = "sqlite", mode = "ro" },
    { name = "rw-sqlite", url = rw_sqlite, type = "sqlite", mode = "rw" },
    { name = "locked-db", url = UNRESOLVABLE_URL, type = "postgresql", mode = "ro" },
    { name = "templated-db", url = TEMPLATED_URL, type = "postgresql", mode = "ro" },
    { name = LONG_RO_NAME, url = LONG_RO_URL, type = "postgresql", mode = "ro" },
  }) }, project_dir .. "/.grip/connections.json")
  vim.g.db = initial_url
  vim.b.db = nil

  local ok, err = pcall(fn, ro_sqlite, rw_sqlite)

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  vim.b.db = orig_b_db
  grip.setup(orig_opts)
  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

test("current_mode reads the entry of the connected URL", function()
  with_connections(RO_URL, function()
    local connections = require("dadbod-grip.connections")
    eq(connections.current_mode(), "ro", "vim.g.db is the ro entry")
    eq(connections.current_mode(RW_URL), "rw", "explicit url wins over vim.g.db")
    eq(connections.current_mode(BARE_URL), "rw", "an entry with no mode field is rw")
    eq(connections.current_mode("postgresql://u:p@h/unsaved"), "rw", "an unsaved url is rw")
  end)
end)

test("current_mode is rw with no connection at all", function()
  with_connections(nil, function()
    eq(require("dadbod-grip.connections").current_mode(), "rw", "never nil")
  end)
end)

test("current_mode prefers vim.b.db over vim.g.db", function()
  with_connections(RW_URL, function()
    vim.b.db = RO_URL
    eq(require("dadbod-grip.connections").current_mode(), "ro", "buffer-local connection wins")
  end)
end)

test("db.is_readonly is true on a ro connection and false on a rw one", function()
  with_connections(RO_URL, function()
    local db = require("dadbod-grip.db")
    eq(db.is_readonly(RO_URL), true, "ro entry")
    eq(db.is_readonly(RW_URL), false, "rw entry")
    eq(db.is_readonly(BARE_URL), false, "entry with no mode field")
  end)
end)

test("adapters.session_opts follows the connection mode", function()
  with_connections(RO_URL, function()
    eq(require("dadbod-grip.adapters").session_opts().readonly, true, "ro")
    vim.g.db = RW_URL
    eq(require("dadbod-grip.adapters").session_opts().readonly, false, "rw")
  end)
end)

-- ── end to end: db.query(sql, url) → argv ─────────────────────────────────
-- The assertions above call the builders directly, which cannot see how the
-- mode reaches them. That is the gap I1 shipped through: the adapters read the
-- *ambient* connection while db.is_readonly read the URL it was given, so the
-- two disagreed the moment a grid or sidebar outlived a :GripConnect. These
-- drive the whole path -- db.query → resolve → adapter → argv -- with the URL
-- and the ambient connection deliberately different.

--- The argv of the one CLI spawn db.query(url) makes. run_cmd is stubbed, so
--- no process runs; a spawn that never happens is an error, not a skip.
local function argv_for_query(url)
  local adapters_mod = require("dadbod-grip.adapters")
  local orig = adapters_mod.run_cmd
  local seen
  adapters_mod.run_cmd = function(args) seen = args; return "", "", 0 end
  local _, err = require("dadbod-grip.db").query("SELECT 1", url)
  adapters_mod.run_cmd = orig
  assert(seen, "no CLI spawn happened; db.query said: " .. tostring(err))
  return seen
end

local function has_readonly(args)
  for _, a in ipairs(args) do
    if a == "-readonly" then return true end
  end
  return false
end

test("db.query reads the mode of the URL it is given, not the ambient one", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = rw_sqlite
    assert(has_readonly(argv_for_query(ro_sqlite)),
      "a ro URL must spawn read-only even while the ambient connection is rw: "
      .. table.concat(argv_for_query(ro_sqlite), " "))
  end)
end)

test("db.query leaves a rw URL writable while the ambient connection is ro", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = ro_sqlite
    assert(not has_readonly(argv_for_query(rw_sqlite)),
      "a rw connection must not be spawned read-only because another one is ro: "
      .. table.concat(argv_for_query(rw_sqlite), " "))
  end)
end)

test("db.query treats an unsaved URL as rw whatever the ambient connection is", function()
  with_connections(nil, function(ro_sqlite)
    vim.g.db = ro_sqlite
    local unsaved = "sqlite:" .. vim.fn.tempname() .. ".sqlite"
    vim.fn.writefile({ "" }, unsaved:sub(#"sqlite:" + 1))
    assert(not has_readonly(argv_for_query(unsaved)), "an unsaved URL has no mode, so rw")
    vim.fn.delete(unsaved:sub(#"sqlite:" + 1))
  end)
end)

test("db.query with no URL still follows the ambient connection", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = ro_sqlite
    assert(has_readonly(argv_for_query(nil)), "ambient ro")
    vim.g.db = rw_sqlite
    assert(not has_readonly(argv_for_query(nil)), "ambient rw")
  end)
end)

test("the published mode is unpublished again when the db call returns", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    local adapters_mod = require("dadbod-grip.adapters")
    vim.g.db = rw_sqlite
    argv_for_query(ro_sqlite)  -- publishes readonly = true for its duration
    eq(adapters_mod.session_opts().readonly, false,
      "outside a db.* call session_opts must be back on the ambient connection")
  end)
end)

test("vim.b.db wins over vim.g.db end to end", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = rw_sqlite
    vim.b.db = ro_sqlite
    local args = argv_for_query(nil)
    vim.b.db = nil
    assert(has_readonly(args), "the buffer-local connection is the one being queried")
  end)
end)

-- ── the three ways the published mode can be lost ─────────────────────────
-- via_adapter publishes the mode for the duration of one db.* call. Three
-- things can strip it before the argv is built, and none of them was covered
-- until a reviewer reproduced two of them by hand.

test("the async path builds its argv while the mode is still published", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = rw_sqlite  -- ambient rw: -readonly can only come from the URL
    local adapters_mod = require("dadbod-grip.adapters")
    local orig = adapters_mod.run_cmd_async
    local seen
    adapters_mod.run_cmd_async = function(args, _, cb)
      seen = args
      vim.schedule(function() cb("", "", 1) end)
    end
    local done = false
    require("dadbod-grip.db").get_schema_batch_async(ro_sqlite, function() done = true end)
    vim.wait(1000, function() return done end, 1)
    adapters_mod.run_cmd_async = orig

    assert(seen, "no async spawn happened")
    assert(has_readonly(seen),
      "the async argv is built after the callback is registered but before the call returns, "
      .. "so it must still see the mode: " .. table.concat(seen, " "))
  end)
end)

test("a db.* call landing inside a blocking spawn leaves the outer call's mode alone", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = rw_sqlite
    -- Real databases and real spawns: run_cmd has to actually block in
    -- vim.wait, which pumps the main loop, for the scheduled call below to
    -- land in the middle of the outer one. That is the whole mechanism.
    local ro_path = ro_sqlite:sub(#"sqlite:" + 1)
    local rw_path = rw_sqlite:sub(#"sqlite:" + 1)
    vim.fn.system({ "sqlite3", ro_path, "create table t(id integer); insert into t values (1);" })
    vim.fn.system({ "sqlite3", rw_path, "create table t(id integer);" })

    local adapters_mod = require("dadbod-grip.adapters")
    local db = require("dadbod-grip.db")
    local spawns = {}
    local orig = adapters_mod.run_cmd
    adapters_mod.run_cmd = function(args, timeout_ms, opts)
      local ro = false
      for _, a in ipairs(args) do
        if a == "-readonly" then ro = true end
      end
      table.insert(spawns, { ro = ro, file = (args[#args - 1] or ""):match("([^/]+)$") or "?" })
      return orig(args, timeout_ms, opts)
    end

    -- The shape of init.lua's scheduled column-info fetch, on the other
    -- connection. get_table_stats is the outer call: it spawns twice.
    vim.schedule(function() db.get_column_info("t", rw_sqlite) end)
    db.get_table_stats("t", ro_sqlite)
    adapters_mod.run_cmd = orig

    local first_nested, last_outer, outer_n, lost = nil, nil, 0, 0
    for i, s in ipairs(spawns) do
      if s.file == "rw.sqlite" then
        first_nested = first_nested or i
      elseif s.file == "ro.sqlite" then
        last_outer = i
        outer_n = outer_n + 1
        if not s.ro then lost = lost + 1 end
      end
    end
    eq(outer_n, 2, "the outer call spawned twice")
    -- Both comparisons are load-bearing. Without them the test could pass
    -- while proving nothing: `< last_outer` alone still goes green for a
    -- nested call that ran to completion *before* the outer one started, so
    -- `> 1` is what actually pins the interleaving.
    assert(first_nested and last_outer and first_nested > 1 and first_nested < last_outer,
      "the scheduled call must land between the outer call's two spawns")
    eq(lost, 0, "every spawn of the outer call kept the mode of its own connection")
  end)
end)

test("a throw inside an adapter restores the published mode and is re-raised", function()
  with_connections(nil, function(ro_sqlite, rw_sqlite)
    vim.g.db = rw_sqlite
    local adapters_mod = require("dadbod-grip.adapters")
    local sq = require("dadbod-grip.adapters.sqlite")
    local orig = sq.query
    sq.query = function() error("boom from the adapter") end
    local ok, err = pcall(require("dadbod-grip.db").query, "SELECT 1", ro_sqlite)
    sq.query = orig

    eq(ok, false, "the error propagates rather than being swallowed")
    assert(tostring(err):find("boom from the adapter", 1, true),
      "re-raised unchanged, got: " .. tostring(err))
    eq(adapters_mod.session_opts().readonly, false,
      "the published mode was restored on the error path, not stranded")
  end)
end)

-- ── DDL commands decline ──────────────────────────────────────────────────

--- Run `action` with the ddl module and db.execute stubbed out, and return
--- (notified_messages, ddl_calls). A recorded call means the refusal did not
--- happen: ddl.create_table / drop_table open the interactive form, and
--- :GripRename old new goes straight to db.execute with an ALTER TABLE.
---
--- A grip session is installed on the current buffer unless opts.no_session:
--- :GripRename and :GripFill bail out early without one, so a spec that
--- skipped this would "pass" against a build with no read-only guard at all.
local function capture(action, opts)
  opts = opts or {}
  local msgs = {}
  local ddl_calls = {}
  local orig_ddl = package.loaded["dadbod-grip.ddl"]
  local orig_notify = vim.notify
  local orig_execute = require("dadbod-grip.db").execute
  local view = require("dadbod-grip.view")
  local bufnr = vim.api.nvim_get_current_buf()
  local orig_session = view._sessions[bufnr]
  if not opts.no_session then
    -- opts.session_url models the ordinary drift this feature has to survive:
    -- a grid opened on one connection, then a :GripConnect to another.
    local surl = opts.session_url or vim.g.db
    view._sessions[bufnr] = {
      url = surl,
      state = { table_name = "users", url = surl, pks = { "id" }, rows = {}, columns = { "id" } },
    }
  else
    view._sessions[bufnr] = nil
  end

  package.loaded["dadbod-grip.ddl"] = {
    create_table  = function() table.insert(ddl_calls, "create_table") end,
    drop_table    = function() table.insert(ddl_calls, "drop_table") end,
    rename_column = function() table.insert(ddl_calls, "rename_column") end,
    add_column    = function() table.insert(ddl_calls, "add_column") end,
  }
  require("dadbod-grip.db").execute = function()
    table.insert(ddl_calls, "execute")
    return { affected = 0 }, nil
  end
  vim.notify = function(m) table.insert(msgs, tostring(m)) end

  local ok, err = pcall(action)

  vim.notify = orig_notify
  require("dadbod-grip.db").execute = orig_execute
  package.loaded["dadbod-grip.ddl"] = orig_ddl
  view._sessions[bufnr] = orig_session
  if not ok then error(err) end
  return msgs, ddl_calls
end

local function run_command(cmd, opts)
  return capture(function() vim.cmd(cmd) end, opts)
end

test("DDL commands decline on a read-only connection", function()
  with_connections(RO_URL, function()
    grip.setup({})  -- registers the user commands against the patched paths
    for _, case in ipairs({
      { cmd = "GripDrop users",        name = "GripDrop" },
      { cmd = "GripCreate",            name = "GripCreate" },
      { cmd = "GripRename a b",        name = "GripRename" },
      { cmd = "GripFill 1",            name = "GripFill" },
    }) do
      local msgs, ddl_calls = run_command(case.cmd)
      eq(#ddl_calls, 0, case.name .. " reached no DDL/execute path")
      eq(#msgs, 1, case.name .. " notified exactly once")
      eq(msgs[1], case.name .. ": Connection is read-only (mode = ro)",
        case.name .. " names the mode")
      assert(not msgs[1]:find("postgresql://", 1, true),
        case.name .. " message must not carry a URL: " .. msgs[1])
    end
  end)
end)

test("DDL commands are not blocked on a rw connection", function()
  with_connections(RW_URL, function()
    grip.setup({})
    local msgs, ddl_calls = run_command("GripDrop users")
    eq(#ddl_calls, 1, "GripDrop reached the ddl module")
    eq(ddl_calls[1], "drop_table", "and it is the drop it was asked for")
    eq(#msgs, 0, "no refusal on rw: " .. table.concat(msgs, " / "))

    -- :GripRename runs its ALTER TABLE through db.execute directly, so this
    -- is the case that proves the ro run above stopped a real statement.
    local rn_msgs, rn_calls = run_command("GripRename a b")
    eq(rn_calls[1], "execute", "GripRename executed the ALTER TABLE on rw")
    assert(not (rn_msgs[1] or ""):find("read-only", 1, true),
      "no read-only refusal on rw: " .. tostring(rn_msgs[1]))
  end)
end)

-- ── the guard and the action must read the same connection ────────────────
-- :GripRename is the one command whose action runs against session.url rather
-- than the ambient connection, and it used to guard the ambient one. With a
-- grid still open on a ro connection after a :GripConnect to a rw one, the
-- ALTER went through unrefused.

test("GripRename guards the session's connection, not the ambient one", function()
  with_connections(RW_URL, function()
    grip.setup({})
    local msgs, calls = run_command("GripRename a b", { session_url = RO_URL })
    eq(#calls, 0, "no ALTER reached db.execute")
    eq(msgs[1], "GripRename: Connection is read-only (mode = ro)", "names the mode")
  end)
end)

test("GripRename still renames when the session's connection is rw", function()
  with_connections(RO_URL, function()
    grip.setup({})
    local msgs, calls = run_command("GripRename a b", { session_url = RW_URL })
    eq(calls[1], "execute", "the ALTER ran: a ro *ambient* connection must not block a rw session")
    assert(not (msgs[1] or ""):find("read-only", 1, true),
      "no refusal: " .. tostring(msgs[1]))
  end)
end)

test("GripFill guards the session's connection, not the ambient one", function()
  with_connections(RO_URL, function(_, rw_sqlite)
    grip.setup({})
    -- Ambient ro, session rw: neither GripFill guard may refuse. The AI module
    -- and the CLI are stubbed out -- reaching generate_rows is the assertion,
    -- and letting the real one run would put a request on the network.
    local adapters_mod = require("dadbod-grip.adapters")
    local orig_run, orig_ai = adapters_mod.run_cmd, package.loaded["dadbod-grip.ai"]
    local reached_ai = false
    adapters_mod.run_cmd = function() return "", "", 0 end
    package.loaded["dadbod-grip.ai"] = {
      _format_ddl_line = function() return "users(id integer)" end,
      generate_rows = function(_, _, _, _, _, cb) reached_ai = true; cb(nil, "stubbed") end,
    }

    local msgs = run_command("GripFill 1", { session_url = rw_sqlite })

    adapters_mod.run_cmd = orig_run
    package.loaded["dadbod-grip.ai"] = orig_ai
    assert(reached_ai,
      "a rw session must not be refused because the ambient connection is ro; got: "
      .. tostring(msgs[1]))
  end)
end)

-- ── GripFill's two guards, one test each ──────────────────────────────────
-- :GripFill and the AI keymap are separate entry points into the same work,
-- and each has its own guard. The pair is not redundant, but only because the
-- command guard runs before do_fill_rows' session checks; these two tests pin
-- exactly that, so neither guard can be deleted as dead code.

test("the :GripFill guard answers before the session checks do", function()
  with_connections(RO_URL, function()
    grip.setup({})
    local msgs = run_command("GripFill 1", { no_session = true })
    eq(msgs[1], "GripFill: Connection is read-only (mode = ro)",
      "the mode is the reason, not the missing session")
  end)
end)

test("the do_fill_rows guard covers the AI keymap path", function()
  with_connections(RO_URL, function()
    grip.setup({})
    -- keymaps_ai.lua calls this directly, never going through :GripFill.
    local msgs, calls = capture(function() grip.do_fill_rows(1) end)
    eq(#calls, 0, "no DDL/execute reached")
    eq(msgs[1], "GripFill: Connection is read-only (mode = ro)",
      "the mode is the reason, not the adapter")
  end)
end)

-- ── the properties float's DDL keymaps ────────────────────────────────────
-- One of the six non-command DDL entry points, driven for real: the float is
-- opened against a ro connection and "+" (add column) is pressed. The others
-- (the schema sidebar's drop/create, the float's R/T/D, the grid's gN) take
-- the identical one-line guard but are covered by inspection only.

--- Open the properties float against `url` with the metadata queries mocked,
--- press `lhs`, and return (messages, ddl_calls). Closes the float again.
local function press_properties_key(url, lhs)
  local properties = require("dadbod-grip.properties")
  local db = require("dadbod-grip.db")
  local orig = {}
  for _, k in ipairs({ "get_column_info", "get_primary_keys", "get_foreign_keys",
                       "get_indexes", "get_table_stats" }) do
    orig[k] = db[k]
  end
  db.get_column_info = function()
    return { { column_name = "id", data_type = "integer", is_nullable = "NO", column_default = "" } }
  end
  db.get_primary_keys = function() return {} end
  db.get_foreign_keys = function() return {} end
  db.get_indexes      = function() return {} end
  db.get_table_stats  = function() return { row_estimate = 0, size_bytes = 0 } end

  local win, buf = properties.open("users", url)
  local pressed = false
  local msgs, calls = capture(function()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == lhs and m.callback then
        pressed = true
        m.callback()
        break
      end
    end
  end)

  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  for k, v in pairs(orig) do db[k] = v end
  assert(pressed, lhs .. " keymap must be registered on the properties float")
  return msgs, calls
end

test("the properties float declines + (add column) on a read-only connection", function()
  with_connections(RO_URL, function()
    local msgs, calls = press_properties_key(RO_URL, "+")
    eq(#calls, 0, "ddl.add_column not reached")
    eq(msgs[1], "Add column: Connection is read-only (mode = ro)", "names the action and the mode")
    assert(not msgs[1]:find("postgresql://", 1, true), "message must not carry a URL")
  end)
end)

test("the properties float reports the real problem before the mode", function()
  with_connections(RO_URL, function()
    -- Cursor on the header line, not a column row. The guard sits after each
    -- keymap's own precondition, so "read-only" must not shadow the reason the
    -- keypress could not have worked anyway.
    local msgs = press_properties_key(RO_URL, "R")
    eq(msgs[1], "Move cursor to a column row", "the cursor problem wins")
  end)
end)

test("the properties float still adds a column on a rw connection", function()
  with_connections(RW_URL, function()
    local msgs, calls = press_properties_key(RW_URL, "+")
    eq(calls[1], "add_column", "ddl.add_column reached")
    eq(#msgs, 0, "no refusal on rw: " .. table.concat(msgs, " / "))
  end)
end)

-- ── the winbar RO badge ───────────────────────────────────────────────────
-- The badge answers "how is this grid connected right now", so it reads the
-- session's own URL through current_mode -- which is also what makes it
-- follow a session override rather than only the stored field.

--- Render the winbar for a throwaway grid session on `url` and return it.
local function winbar_for(url)
  local view = require("dadbod-grip.view")
  local bufnr = vim.api.nvim_create_buf(false, true)
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  view._sessions[bufnr] = { url = url, state = { table_name = "users", url = url } }
  view._update_winbar(bufnr)
  local bar = vim.wo[vim.api.nvim_get_current_win()].winbar
  view._sessions[bufnr] = nil
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.wo[vim.api.nvim_get_current_win()].winbar = nil
  return bar or ""
end

test("the winbar shows RO on a read-only session and nothing on a rw one", function()
  with_connections(RW_URL, function()
    -- Ambient rw throughout: the badge must come from the session's own URL.
    assert(winbar_for(RO_URL):find("RO", 1, true), "ro session badged")
    assert(not winbar_for(RW_URL):find("RO", 1, true),
      "rw session unbadged, got: " .. winbar_for(RW_URL))
    assert(not winbar_for(BARE_URL):find("RO", 1, true),
      "an entry with no mode field is rw, so unbadged")
  end)
end)

test("the RO badge is highlighted rather than plain text", function()
  with_connections(RO_URL, function()
    assert(winbar_for(RO_URL):find("%#GripReadonly#RO", 1, true),
      "badge carries its highlight group: " .. winbar_for(RO_URL))
  end)
end)

--- A grid session on `url` that stays alive across calls, so its winbar cache
--- is warm -- which winbar_for's throwaway session can never be. fn gets a
--- bar() that re-renders the winbar the way a CursorMoved does and returns it.
local function with_live_session(url, fn)
  local view = require("dadbod-grip.view")
  local bufnr = vim.api.nvim_create_buf(false, true)
  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)
  local win = vim.api.nvim_get_current_win()
  view._sessions[bufnr] = { url = url, state = { table_name = "users", url = url } }
  -- bar() re-renders the way a CursorMoved does; raw() reads the option as it
  -- stands, which is what the user is looking at until they move the cursor.
  local ok, err = pcall(fn, function()
    view._update_winbar(bufnr)
    return vim.wo[win].winbar or ""
  end, function() return vim.wo[win].winbar or "" end)
  view._sessions[bufnr] = nil
  vim.api.nvim_set_current_buf(orig_buf)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.wo[win].winbar = nil
  if not ok then error(err) end
end

-- ── the picker's r:ro/rw action ───────────────────────────────────────────
-- A one-shot session override: the entry on disk keeps saying what it said,
-- and reconnecting the ordinary way puts the connection back on it.

--- with_connections plus the stubs M.switch() needs to be callable headless,
--- and a freshly required connections module so the module-local override
--- table starts empty -- a test inheriting another test's override would
--- prove nothing. fn receives that module instance.
---
--- getcwd is pointed at the temp project too: the picker lists the data files
--- it finds in the working directory and pads every row to the longest name
--- among them, so from the repo root the row layout would depend on whatever
--- .json/.csv files happen to sit there. Patched rather than :lcd'd -- Lua's
--- package.path is cwd-relative under the test runner, and a real chdir stops
--- `require("dadbod-grip.…")` from resolving at all.
local function with_switchable(initial_url, fn)
  with_connections(initial_url, function(ro_sqlite, rw_sqlite)
    local orig_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function() return paths.project_root() end
    local saved = {
      schema     = package.loaded["dadbod-grip.schema"],
      query_pad  = package.loaded["dadbod-grip.query_pad"],
      completion = package.loaded["dadbod-grip.completion"],
      conns      = package.loaded["dadbod-grip.connections"],
      open       = grip.open,
      welcome    = grip.open_welcome,
    }
    package.loaded["dadbod-grip.schema"] = {
      is_open = function() return true end, refresh = function() end,
      toggle = function() end, get_winid = function() return nil end,
    }
    package.loaded["dadbod-grip.query_pad"]  = { open = function() end }
    package.loaded["dadbod-grip.completion"] = {
      invalidate = function() end, warm_schema = function() end,
    }
    grip.open, grip.open_welcome = function() end, function() end
    vim.notify = function() end  -- with_connections restores the original
    package.loaded["dadbod-grip.connections"] = nil
    local connections = require("dadbod-grip.connections")

    local ok, err = pcall(fn, connections, ro_sqlite, rw_sqlite)
    vim.wait(50)  -- flush the vim.schedule() callbacks switch() queues

    package.loaded["dadbod-grip.schema"]      = saved.schema
    package.loaded["dadbod-grip.query_pad"]   = saved.query_pad
    package.loaded["dadbod-grip.completion"]  = saved.completion
    package.loaded["dadbod-grip.connections"] = saved.conns
    grip.open, grip.open_welcome = saved.open, saved.welcome
    vim.fn.getcwd = orig_getcwd
    if not ok then error(err) end
  end)
end

--- The opts grip_picker.open() would have been called with, plus the action
--- with `key`, plus the picker item named `name`.
local function picker_action(connections, key, name)
  local grip_picker = require("dadbod-grip.grip_picker")
  local orig = grip_picker.open
  local captured
  grip_picker.open = function(o) captured = o end
  connections.pick()
  grip_picker.open = orig
  assert(captured and captured.actions, "M.pick() reached grip_picker.open with actions")
  local action
  for _, a in ipairs(captured.actions) do
    if a.key == key then action = a end
  end
  assert(action, key .. " action present in the connections picker")
  local item
  for _, c in ipairs(captured.items) do
    if c.name == name then item = c end
  end
  assert(item, "picker item '" .. tostring(name) .. "' present")
  return captured, action, item
end

test("the picker row shows RO for an entry defaulting to read-only", function()
  with_switchable(nil, function(connections)
    local captured, _, ro_item = picker_action(connections, "r", "ro-db")
    assert(captured.display(ro_item):find("RO", 1, true),
      "ro entry marked: " .. captured.display(ro_item))
    for _, c in ipairs(captured.items) do
      if c.name == "rw-db" or c.name == "bare-db" then
        assert(not captured.display(c):find("RO", 1, true),
          c.name .. " must not be marked: " .. captured.display(c))
      end
    end
  end)
end)

-- ── the row as it is actually rendered ────────────────────────────────────
-- display() is not the whole story: grip_picker cuts any row wider than the
-- float (width - 6, the float capping at 70 columns) and appends "…". A
-- marker that trails the URL is the first thing cut, and the rows most likely
-- to be read-only -- long production names, long hosts -- are exactly the
-- ones that overrun. So this drives the real picker and reads its buffer.

--- Open the connections picker for real and return (lines, popup_buf).
local function open_real_picker(connections)
  local before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do before[b] = true end
  connections.pick()
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before[b] and vim.api.nvim_buf_is_valid(b) then buf = b; break end
  end
  assert(buf, "the picker opened a buffer")
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf
end

local function close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
  end
end

--- The rendered row containing `frag`, or nil.
local function row_with(lines, frag)
  for _, l in ipairs(lines) do
    if l:find(frag, 1, true) then return l end
  end
end

--- Press a buffer-local normal-mode map, as tests/spec/grip_picker_spec.lua does.
local function press(buf, key)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == key and m.callback then m.callback(); return true end
  end
  return false
end

test("the rendered row keeps RO on a production-length name and url", function()
  with_switchable(nil, function(connections)
    local orig_columns = vim.o.columns
    vim.o.columns = 80  -- the float caps at 70, so rows are cut at 64 bytes
    local ok, err = pcall(function()
      local lines, buf = open_real_picker(connections)
      local row = row_with(lines, LONG_RO_NAME)
      assert(row, "the long entry is rendered: " .. table.concat(lines, "\n"))
      assert(row:find("RO", 1, true),
        "RO survives truncation of a long row: [" .. row .. "]")
      assert(row:find("…", 1, true),
        "and this row really is being truncated, or the case proves nothing: [" .. row .. "]")

      -- M:mask reveals the full URL, lengthening the row further -- the case
      -- that lost the marker unconditionally when it trailed the URL.
      for _ = 1, #lines do
        local cur = row_with(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "▶")
        if cur and cur:find(LONG_RO_NAME, 1, true) then break end
        assert(press(buf, "j"), "j is mapped")
      end
      assert(press(buf, "M"), "M is mapped")
      local unmasked = row_with(vim.api.nvim_buf_get_lines(buf, 0, -1, false), LONG_RO_NAME)
      assert(unmasked and unmasked:find("RO postg", 1, true),
        "RO survives with the password revealed -- and the raw url really is "
        .. "showing (short_url drops the scheme, the unmasked one keeps it), "
        .. "or M never landed on this row: [" .. tostring(unmasked) .. "]")
    end)
    close_floats()
    vim.o.columns = orig_columns
    if not ok then error(err) end
  end)
end)

test("the RO column costs nothing when no entry is read-only", function()
  with_switchable(nil, function(connections)
    -- With a ro entry in the file every row reserves the column, so the
    -- non-ro rows are indented by it.
    local with_ro, _, rw_item = picker_action(connections, "r", "rw-db")
    local url_at_with = with_ro.display(rw_item):find("h/rw_db", 1, true)
    assert(url_at_with, "the url is on the row at all: [" .. with_ro.display(rw_item) .. "]")

    -- Rewrite the file with every mode flipped to rw and nothing else
    -- touched -- same names, so the name column is unchanged and the only
    -- difference left is the marker's own column.
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "rw-db",      url = RW_URL,      type = "postgresql", mode = "rw" },
      { name = "bare-db",    url = BARE_URL,    type = "postgresql" },
      { name = LONG_RO_NAME, url = LONG_RO_URL, type = "postgresql", mode = "rw" },
    }) }, paths.project_root() .. "/.grip/connections.json")
    local without, _, rw_again = picker_action(connections, "r", "rw-db")
    eq(#with_ro.display(rw_item) - #without.display(rw_again), 3,
      "no ro entry, no column: [" .. with_ro.display(rw_item) .. "] vs ["
      .. without.display(rw_again) .. "]")
    -- Where the url *starts*, not just how long the row is: the name column
    -- pads to the same width in both renders, so a run of blanks before the
    -- url proves nothing on its own -- only the shift does.
    local url_at_without = without.display(rw_again):find("h/rw_db", 1, true)
    eq(url_at_with - url_at_without, 3,
      "the url sits exactly three columns later while the marker column exists")
  end)
end)

test("r:ro/rw is labelled and closes the picker", function()
  with_switchable(nil, function(connections)
    local _, action = picker_action(connections, "r", "ro-db")
    eq(action.label, "r:ro/rw", "footer label")
    eq(action.close_on_select, true, "connecting closes the picker, like <CR>")
  end)
end)

test("r:ro/rw is offered on a database connection and withheld elsewhere", function()
  with_switchable(nil, function(connections, ro_sqlite)
    local _, action, ro_item = picker_action(connections, "r", "ro-db")
    eq(action.when(ro_item), true, "offered on a saved database connection")
    -- A file-backed *database* is not a "local file": sqlite3/duckdb take
    -- -readonly on one, so the toggle means something there.
    eq(action.when({ name = "ro-sqlite", url = ro_sqlite, type = "sqlite" }), true,
      "offered on a sqlite database")
    for _, item in ipairs({
      { name = "global",  url = "", _section_header = true },
      { name = "+ New",   url = "", _new = true },
      { name = "~ Once",  url = "", _temp = true },
      { name = "d.csv",   url = "/tmp/d.csv", _local_file = true },
      { name = "sales",   url = "/tmp/sales.parquet", type = "file" },
      { name = "web",     url = "https://example.com/x.csv" },
      { name = "mssql",   url = "sqlserver://u:p@h/db", type = "sqlserver" },
    }) do
      eq(action.when(item), false, "withheld on " .. item.name)
    end
  end)
end)

test("r:ro/rw connects a rw entry read-only without touching the file", function()
  with_switchable(nil, function(connections)
    local _, action, bare = picker_action(connections, "r", "bare-db")
    eq(connections.current_mode(BARE_URL), "rw", "the entry's own default")
    action.fn(bare)
    eq(connections.current_mode(BARE_URL), "ro", "the session override wins")
    eq(connections.entry_for(BARE_URL).mode, nil,
      "the saved entry is untouched: an override is never written to connections.json")
    eq(require("dadbod-grip.db").is_readonly(BARE_URL), true,
      "the override reaches the grid/adapter gate, not just the badge")
  end)
end)

test("r:ro/rw declines the rows it is withheld from, not just hides itself", function()
  with_switchable(nil, function(connections)
    -- grip_picker fires fn regardless of the `when` predicate, so `when`
    -- returning false is not on its own a guarantee that nothing happens:
    -- fn has to refuse too, or a keypress on a hidden action sets an
    -- override on an entry that can never honour it.
    local _, action = picker_action(connections, "r", "ro-db")
    for _, item in ipairs({
      { name = "mssql", url = "sqlserver://u:p@h/db", type = "sqlserver" },
      { name = "sales", url = "/tmp/sales.parquet",   type = "file" },
      { name = "d.csv", url = "/tmp/d.csv",           _local_file = true },
    }) do
      action.fn(item)
      eq(connections.current_mode(item.url), "rw",
        "no override taken on " .. item.name .. ", where the action is withheld")
    end
  end)
end)

test("r:ro/rw connects a ro entry writable", function()
  with_switchable(nil, function(connections)
    local _, action, ro_item = picker_action(connections, "r", "ro-db")
    action.fn(ro_item)
    eq(connections.current_mode(RO_URL), "rw", "opened writable for this session")
    eq(connections.entry_for(RO_URL).mode, "ro", "the saved entry still says ro")
  end)
end)

test("an override applies to that connection only", function()
  with_switchable(nil, function(connections)
    -- bare-db is the one overridden, and it is overridden *to* ro: a test
    -- that overrode a connection to rw could not tell an override keyed by
    -- URL from one that leaked onto every rw connection in the file.
    local _, action, bare = picker_action(connections, "r", "bare-db")
    action.fn(bare)
    eq(connections.current_mode(BARE_URL), "ro", "the overridden connection")
    eq(connections.current_mode(RW_URL), "rw", "another connection is unaffected")
    eq(connections.current_mode("postgresql://u:p@h/unsaved"), "rw", "and so is an unsaved URL")
  end)
end)

test("reconnecting the ordinary way drops the override", function()
  with_switchable(nil, function(connections)
    local _, action, ro_item = picker_action(connections, "r", "ro-db")
    action.fn(ro_item)
    eq(connections.current_mode(RO_URL), "rw", "override in force")
    connections.switch(RO_URL, "ro-db", "postgresql")
    eq(connections.current_mode(RO_URL), "ro", "back on the entry's own mode")
  end)
end)

test("the winbar badge follows a session override", function()
  with_switchable(nil, function(connections)
    local _, action, ro_item = picker_action(connections, "r", "ro-db")
    action.fn(ro_item)
    assert(not winbar_for(RO_URL):find("RO", 1, true),
      "a ro entry opened writable must not keep the badge: " .. winbar_for(RO_URL))
    local _, _, bare = picker_action(connections, "r", "bare-db")
    action.fn(bare)
    assert(winbar_for(BARE_URL):find("RO", 1, true),
      "a rw entry opened read-only gets it")
  end)
end)

-- ── the badge of a grid that is still open when the mode changes ──────────
-- The badge is cached per session because the winbar is rebuilt on every
-- cursor move. A switch is the other thing that changes the answer, and the
-- grid it applies to is not always the one being replaced: switch() ends in
-- open_welcome, which only touches the *current* window, so a grid in the
-- sidebar's neighbour window, or a pinned one, lives on with its cache.

test("a switch refreshes the badge of a grid that is still open", function()
  with_switchable(nil, function(connections)
    with_live_session(BARE_URL, function(bar, raw)
      assert(not bar():find("RO", 1, true), "rw to begin with (warms the cache)")
      local _, action, bare = picker_action(connections, "r", "bare-db")
      action.fn(bare)
      eq(connections.current_mode(BARE_URL), "ro", "the override took")
      assert(raw():find("RO", 1, true),
        "the badge must be on screen already, not on the next cursor move: " .. raw())
      assert(bar():find("RO", 1, true), "and it stays there on the next redraw")
    end)
  end)
end)

test("a reconnect drops the badge the override put there", function()
  with_switchable(nil, function(connections)
    local _, action, bare = picker_action(connections, "r", "bare-db")
    action.fn(bare)
    with_live_session(BARE_URL, function(bar, raw)
      assert(bar():find("RO", 1, true), "badged while overridden (warms the cache)")
      connections.switch(BARE_URL, "bare-db", "postgresql")
      eq(connections.current_mode(BARE_URL), "rw", "the override is gone")
      assert(not raw():find("RO", 1, true),
        "a badge claiming read-only on a writable connection is the worse lie: " .. raw())
      assert(not bar():find("RO", 1, true), "and the next redraw must not bring it back")
    end)
  end)
end)

-- ── a switch that never happened ──────────────────────────────────────────

test("an r whose secret does not resolve leaves the mode exactly as it was", function()
  with_switchable(UNRESOLVABLE_URL, function(connections)
    local msgs = {}
    vim.notify = function(m) table.insert(msgs, tostring(m)) end
    local _, action, locked = picker_action(connections, "r", "locked-db")
    eq(connections.current_mode(UNRESOLVABLE_URL), "ro", "the entry's own mode before")

    action.fn(locked)

    assert(#msgs >= 1 and msgs[1]:find("unresolved variable", 1, true),
      "the switch reported the failure: " .. table.concat(msgs, " / "))
    for _, m in ipairs(msgs) do
      assert(not m:find("for this session", 1, true),
        "and must not also claim the override took: " .. m)
    end
    eq(connections.current_mode(UNRESOLVABLE_URL), "ro",
      "a switch that aborted must not flip the connection the user is still on")
    eq(require("dadbod-grip.db").is_readonly(UNRESOLVABLE_URL), true,
      "so the read-only guard is still in force")
  end)
end)

test("a failed ordinary reconnect does not clear an override either", function()
  with_switchable(nil, function(connections)
    -- The same ordering bug in the other direction: the override is cleared
    -- at the top of switch(), so a reconnect that aborts would drop an
    -- override the user is relying on. The variable resolves while the
    -- override is taken and is gone by the reconnect, which is exactly the
    -- git-crypt / re-exported-.env case this feature has to survive.
    vim.fn.setenv("GRIP_TEST_PW", "s3cr3t")
    local ok, err = pcall(function()
      local _, action, tpl = picker_action(connections, "r", "templated-db")
      action.fn(tpl)
      eq(connections.current_mode(TEMPLATED_URL), "rw", "a ro entry opened writable")

      vim.fn.setenv("GRIP_TEST_PW", vim.NIL)
      eq(connections.switch(TEMPLATED_URL, "templated-db", "postgresql"), false,
        "the reconnect aborted")
      eq(connections.current_mode(TEMPLATED_URL), "rw",
        "a switch that never happened must not silently re-lock the connection")
    end)
    vim.fn.setenv("GRIP_TEST_PW", vim.NIL)  -- never leak into a later spec
    if not ok then error(err) end
  end)
end)

-- ── the connection whose read-only session is not read-only ───────────────
-- libpq prefers a URL's own `options` keyword over PGOPTIONS instead of
-- merging them, so exactly one shape of postgres URL takes the ro flag and
-- opens writable anyway. Verified against a live server: a URL with
-- `?options=-c%20statement_timeout%3D5s` reports
-- `default_transaction_read_only = off` with PGOPTIONS set. The badge and the
-- DDL refusals read the entry, not the server, so this connection looks the
-- most protected of all -- hence a warning rather than a comment in the docs.

test("readonly_caveat names the options= that beats PGOPTIONS", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  assert(pg.readonly_caveat("postgresql://u:p@h/db?options=-c%20statement_timeout%3D5s"),
    "the case reproduced live is caught")
  assert(pg.readonly_caveat("postgresql://u:p@h/db?sslmode=require&options=-cx"),
    "and when it is not the first parameter")
  assert(pg.readonly_caveat("postgresql://u:p@h/db?options="),
    "an empty options= counts: libpq falls back to PGOPTIONS only when the keyword is absent")
  assert(pg.readonly_caveat("postgresql://u:p@h/db?options"),
    "as does the valueless form, which parses to the same empty value")
end)

test("readonly_caveat is silent for a URL the guard does hold on", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  eq(pg.readonly_caveat("postgresql://u:p@h/db"), nil, "no query string at all")
  eq(pg.readonly_caveat("postgresql://u:p@h/db?sslmode=require"), nil, "an unrelated parameter")
  -- The naive check -- find("options=") -- fires on all three of these, and
  -- crying wolf on an ordinary connection is how a warning gets ignored on
  -- the one that matters.
  eq(pg.readonly_caveat("postgresql://u:p@h/db?myoptions=x"), nil,
    "a parameter merely ending in options")
  eq(pg.readonly_caveat("postgresql://u:p@h/options=db"), nil,
    "the text appearing in the path rather than the query")
  eq(pg.readonly_caveat("postgresql://u:p@h/db#options=x"), nil,
    "or in a fragment, which libpq never reads as a parameter")
end)

test("the caveat can be shown to the user without leaking the password", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local caveat = pg.readonly_caveat("postgresql://u:s3cr3t@h/db?options=-cx")
  assert(caveat, "there is a caveat to show")
  assert(not caveat:find("s3cr3t", 1, true), "and it does not carry the password: " .. caveat)
  assert(not caveat:find("postgresql://", 1, true), "nor the URL: " .. caveat)
end)

test("the caveat dispatch only answers for adapters that declare one", function()
  local adapters = require("dadbod-grip.adapters")
  assert(adapters.readonly_caveat("postgresql://u:p@h/db?options=-cx"),
    "postgres declares one and it reaches the dispatcher")
  eq(adapters.readonly_caveat("mysql://u:p@h/db?options=-cx"), nil,
    "mysql sets its mode through --init-command, which no URL parameter displaces")
  eq(adapters.readonly_caveat("sqlite:/tmp/x.sqlite?options=-cx"), nil,
    "sqlite takes -readonly in argv, likewise undisplaceable")
  eq(adapters.readonly_caveat("nosuchscheme://h/db?options=-cx"), nil,
    "an unknown scheme resolves to no adapter and must not throw")
  eq(adapters.readonly_caveat(nil), nil, "nor must a nil URL")
end)

test("connecting read-only to such a URL says so once", function()
  with_switchable(nil, function(connections)
    local url = "postgresql://u:p@h/opts_db?options=-c%20statement_timeout%3D5s"
    local msgs = {}
    vim.notify = function(m) table.insert(msgs, tostring(m)) end

    eq(connections.switch(url, "opts-db", "postgresql", { mode = "ro" }), true,
      "the switch committed")

    local warned = 0
    for _, m in ipairs(msgs) do
      if m:find("read%-only is not enforced") then warned = warned + 1 end
    end
    eq(warned, 1, "warned exactly once: " .. table.concat(msgs, " / "))
    for _, m in ipairs(msgs) do
      assert(not m:find("opts_db", 1, true) or not m:find("read%-only is not enforced"),
        "and the warning names no URL: " .. m)
    end
  end)
end)

test("it stays quiet when the promise is one the connection can keep", function()
  with_switchable(nil, function(connections)
    local opts_url  = "postgresql://u:p@h/opts_db?options=-cx"
    local plain_url = "postgresql://u:p@h/plain_db"
    local function switch_and_collect(url, name, mode)
      local msgs = {}
      vim.notify = function(m) table.insert(msgs, tostring(m)) end
      connections.switch(url, name, "postgresql", mode and { mode = mode } or nil)
      for _, m in ipairs(msgs) do
        if m:find("read%-only is not enforced") then return true end
      end
      return false
    end

    eq(switch_and_collect(opts_url, "opts-db", "rw"), false,
      "a writable connection was never promised anything to break")
    eq(switch_and_collect(plain_url, "plain-db", "ro"), false,
      "and a ro connection whose PGOPTIONS does take must not be second-guessed")
    -- The r:ro/rw action routes through the same switch(), so the toggle into
    -- read-only is the other way a user meets this and has to warn too.
    eq(switch_and_collect(opts_url, "opts-db", "ro"), true,
      "toggling that same connection into ro does warn")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nreadonly_mode_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
