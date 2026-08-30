local connections = require("dadbod-grip.connections")
local grip = require("dadbod-grip")
local paths = require("dadbod-grip.paths")
local saved = require("dadbod-grip.saved")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, msg)
  assert(actual == expected,
    (msg or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function write_json(path, value)
  paths.ensure_dir(vim.fn.fnamemodify(path, ":h"))
  vim.fn.writefile({ vim.fn.json_encode(value) }, path)
end

local function read_json(path)
  return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function with_storage(fn, opts)
  local root = vim.fn.tempname() .. "_grip_saved"
  local fake_home = root .. "_home"
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(fake_home, "p")

  local project_root = paths.project_root
  local expand = vim.fn.expand
  local notify = vim.notify
  local current_db = vim.g.db
  local old_opts = grip.get_opts()
  local notices = {}

  paths.project_root = function() return root end
  vim.fn.expand = function(value, ...)
    if value == "~" then return fake_home end
    return expand(value, ...)
  end
  vim.notify = function(message) table.insert(notices, tostring(message)) end
  grip.setup(opts or {})

  local ok, err = pcall(fn, {
    root = root,
    local_file = root .. "/.grip/connections.json",
    global_file = fake_home .. "/.grip/connections.json",
    query_dir = root .. "/.grip/queries",
    notices = notices,
  })

  paths.project_root = project_root
  vim.fn.expand = expand
  vim.notify = notify
  vim.g.db = current_db
  grip.setup(old_opts)
  vim.fn.delete(root, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

local function with_switch_spy(fn)
  local switch = connections.switch
  local calls = {}
  connections.switch = function(...)
    table.insert(calls, { ... })
    return true
  end
  local ok, err = pcall(fn, calls)
  connections.switch = switch
  if not ok then error(err) end
end

test("save binds SQL to an opaque stable ID without copying credentials", function()
  with_storage(function(ctx)
    local url = "postgresql://user:supersecret@db.internal/app"
    write_json(ctx.local_file, { { name = "app", url = url } })

    saved.save("daily", "SELECT 1", url)
    local first = table.concat(vim.fn.readfile(ctx.query_dir .. "/daily.sql"), "\n")
    local persisted = read_json(ctx.local_file)[1]
    assert(first:match("^%-%- grip:connection=conn_[0-9a-f]+\nSELECT 1$"), first)
    assert(not first:find("supersecret", 1, true), "password reached saved SQL")
    assert(not first:find("db.internal", 1, true), "URL reached saved SQL")
    assert(persisted.id and first:find(persisted.id, 1, true), "header uses persisted ID")

    saved.save("daily", first, url)
    eq(read_json(ctx.local_file)[1].id, persisted.id, "ID is stable across saves")
    local second = table.concat(vim.fn.readfile(ctx.query_dir .. "/daily.sql"), "\n")
    eq(select(2, second:gsub("grip:connection=", "")), 1, "metadata is not duplicated")
  end)
end)

test("save leaves an unsaved connection unbound and strips legacy metadata", function()
  with_storage(function(ctx)
    local url = "postgresql://user:secret@db/app"
    saved.save("adhoc", "-- grip:url=" .. url .. "\nSELECT 2", url)
    eq(table.concat(vim.fn.readfile(ctx.query_dir .. "/adhoc.sql"), "\n"), "SELECT 2")
    assert(table.concat(ctx.notices, "\n"):find("without a connection", 1, true))
    assert(not table.concat(ctx.notices, "\n"):find("secret", 1, true), "notice leaked password")
  end)
end)

test("load resolves an ID without renaming the connection", function()
  with_storage(function(ctx)
    local url = "sqlite:/tmp/app.db"
    write_json(ctx.local_file, {
      { id = "conn_saved", name = "production", url = url, type = "sqlite" },
    })
    paths.ensure_dir(ctx.query_dir)
    vim.fn.writefile({ "-- grip:connection=conn_saved", "SELECT 3" }, ctx.query_dir .. "/bound.sql")
    vim.g.db = "sqlite:/tmp/other.db"

    with_switch_spy(function(calls)
      eq(saved.load("bound"), "SELECT 3", "metadata stripped")
      eq(#calls, 1, "connection switched")
      eq(calls[1][1], url, "resolved URL")
      eq(calls[1][2], nil, "saved query name is never used as connection name")
      eq(calls[1][3], "sqlite", "stored type forwarded")
    end)
    eq(read_json(ctx.local_file)[1].name, "production", "persisted name unchanged")
  end)
end)

test("IDs survive rename, touch, attachment edits, and URL dedupe", function()
  with_storage(function(ctx)
    local url = "duckdb::memory:"
    write_json(ctx.local_file, {
      { id = "conn_keep", name = "old", url = url, last_used = 1 },
      { name = "newer duplicate", url = url, last_used = 2 },
    })
    connections.add("renamed", url)
    connections.touch(url)
    connections.save_attachments(url, { { alias = "side", dsn = "sqlite:/tmp/side.db" } })
    local rows = read_json(ctx.local_file)
    eq(#rows, 1, "deduped by URL")
    eq(rows[1].id, "conn_keep", "ID preserved")
    eq(rows[1].name, "renamed", "rename applied")
    eq(rows[1].attachments[1].alias, "side", "attachment update preserved ID")
  end)
end)

test("global and custom connection files receive and resolve IDs", function()
  with_storage(function(ctx)
    local global_url = "sqlite:/tmp/global.db"
    write_json(ctx.global_file, { { name = "global", url = global_url } })
    local global_id = connections.ensure_id(global_url)
    assert(global_id and read_json(ctx.global_file)[1].id == global_id, "global ID persisted")
    eq(connections.find_by_id(global_id).url, global_url, "global ID resolved")
  end)

  local custom = vim.fn.tempname() .. "_custom_connections.json"
  with_storage(function()
    local url = "sqlite:/tmp/custom.db"
    write_json(custom, { { name = "custom", url = url } })
    local id = connections.ensure_id(url)
    assert(id and read_json(custom)[1].id == id, "custom-file ID persisted")
    eq(connections.find_by_id(id).url, url, "custom-file ID resolved")
  end, { connections_path = custom })
  vim.fn.delete(custom)
end)

test("missing and ambiguous IDs keep the current connection", function()
  with_storage(function(ctx)
    write_json(ctx.local_file, { { id = "conn_clash", name = "one", url = "sqlite:/tmp/one.db" } })
    write_json(ctx.global_file, { { id = "conn_clash", name = "two", url = "sqlite:/tmp/two.db" } })
    paths.ensure_dir(ctx.query_dir)
    vim.fn.writefile({ "-- grip:connection=conn_clash", "SELECT 4" }, ctx.query_dir .. "/ambiguous.sql")
    vim.fn.writefile({ "-- grip:connection=conn_missing", "SELECT 5" }, ctx.query_dir .. "/missing.sql")

    with_switch_spy(function(calls)
      eq(saved.load("ambiguous"), "SELECT 4")
      eq(saved.load("missing"), "SELECT 5")
      eq(#calls, 0, "neither metadata failure guessed a connection")
    end)
    local notices = table.concat(ctx.notices, "\n")
    assert(notices:find("ambiguous", 1, true), notices)
    assert(notices:find("no longer exists", 1, true), notices)
  end)
end)

test("legacy safe URLs switch unnamed and credentialed URLs never switch", function()
  with_storage(function(ctx)
    paths.ensure_dir(ctx.query_dir)
    vim.fn.writefile({ "-- grip:url=sqlite:/tmp/legacy.db", "SELECT 6" },
      ctx.query_dir .. "/safe.sql")
    vim.fn.writefile({ "-- grip:url=postgresql://user:${DB_PASSWORD}@db/app", "SELECT 6.5" },
      ctx.query_dir .. "/templated.sql")
    local password = "legacy_password_must_not_leak"
    vim.fn.writefile({ "-- grip:url=postgresql://user:" .. password .. "@db/app", "SELECT 7" },
      ctx.query_dir .. "/credentialed.sql")

    with_switch_spy(function(calls)
      eq(saved.load("safe"), "SELECT 6")
      eq(saved.load("templated"), "SELECT 6.5")
      eq(saved.load("credentialed"), "SELECT 7")
      eq(#calls, 2, "credential-free and templated URLs switched")
      eq(calls[1][1], "sqlite:/tmp/legacy.db")
      eq(calls[1][2], nil, "legacy load cannot rename")
      eq(calls[2][1], "postgresql://user:${DB_PASSWORD}@db/app")
      eq(calls[2][2], nil, "templated legacy load cannot rename")
    end)
    local notices = table.concat(ctx.notices, "\n")
    assert(notices:find("migrate", 1, true), notices)
    assert(notices:find("contains credentials", 1, true), notices)
    assert(not notices:find(password, 1, true), "credential warning leaked password")
    assert(table.concat(vim.fn.readfile(ctx.query_dir .. "/credentialed.sql"), "\n")
      :find(password, 1, true), "load must not silently rewrite the user's file")
  end)
end)

print(string.format("saved_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
