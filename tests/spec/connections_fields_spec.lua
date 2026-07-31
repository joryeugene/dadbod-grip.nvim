-- connections_fields_spec.lua -- env_file/mode/color must round-trip through
-- both connections.lua whitelists (read_json_connections + write_file_connections)
-- and through the G:global promotion action, without disturbing the
-- byte-identical output connections_spec.lua pins for entries that don't use
-- the new fields.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

-- Rebound to a freshly loaded module by every with_real_file() below -- see
-- the comment on the harness itself for why this matters.
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
-- Copied verbatim from tests/spec/connections_spec.lua:53 -- see that file's
-- comments for why every one of these patches exists. In short:
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
  local project_dir = vim.fn.tempname() .. "_grip_conn_fields_test"
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

-- ── read whitelist ─────────────────────────────────────────────────────────

test("env_file, mode and color survive a read", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${DB_URL}", env_file = "~/p/.env",
        mode = "ro", color = "orange" },
    }) }, local_grip .. "/connections.json")
    local list = connections.list()
    local dev
    for _, c in ipairs(list) do if c.name == "dev" then dev = c end end
    assert(dev, "entry loaded")
    eq(dev.env_file, "~/p/.env", "env_file survived read")
    eq(dev.mode, "ro", "mode survived read")
    eq(dev.color, "orange", "color survived read")
  end)
end)

-- ── write whitelist ────────────────────────────────────────────────────────

test("the fields survive a write triggered by an unrelated mutation", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${DB_URL}", env_file = "~/p/.env",
        mode = "ro", color = "orange" },
    }) }, local_grip .. "/connections.json")
    connections.touch("${DB_URL}")
    local raw = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
    local data = vim.fn.json_decode(raw)
    eq(data[1].env_file, "~/p/.env", "env_file not dropped on rewrite")
    eq(data[1].mode, "ro", "mode not dropped on rewrite")
    eq(data[1].color, "orange", "color not dropped on rewrite")
  end)
end)

-- ── backwards compatibility ─────────────────────────────────────────────────
-- An entry with none of the new fields must round-trip exactly as it does
-- today: no new keys should appear in the JSON just because the feature
-- exists now.

test("an entry without the new fields round-trips with no new keys added", function()
  with_real_file(function(local_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "old", url = "postgresql://u:p@h/db", type = "postgresql", last_used = 100 },
    }) }, local_grip .. "/connections.json")
    connections.touch("postgresql://u:p@h/db")
    local raw = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
    local data = vim.fn.json_decode(raw)
    eq(data[1].env_file, nil, "no env_file key materialized")
    eq(data[1].mode, nil, "no mode key materialized")
    eq(data[1].color, nil, "no color key materialized")
    assert(not raw:find('"env_file"', 1, true), "raw JSON has no env_file key")
    assert(not raw:find('"mode"', 1, true), "raw JSON has no mode key")
    assert(not raw:find('"color"', 1, true), "raw JSON has no color key")
  end)
end)

-- ── G:global promotion ──────────────────────────────────────────────────────
-- Promoting a templated entry to ~/.grip/connections.json must carry the new
-- fields, otherwise the promoted connection can't resolve its secret anymore.

test("G:global carries env_file, mode and color when promoting", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${DB_URL}", env_file = "~/p/.env",
        mode = "ro", color = "orange" },
    }) }, local_grip .. "/connections.json")

    local grip_picker = require("dadbod-grip.grip_picker")
    local orig_picker_open = grip_picker.open
    local captured
    grip_picker.open = function(opts) captured = opts end

    connections.pick()

    grip_picker.open = orig_picker_open

    assert(captured and captured.actions, "M.pick() reached grip_picker.open with actions")
    local global_action
    for _, a in ipairs(captured.actions) do
      if a.label == "G:global" then global_action = a end
    end
    assert(global_action, "G:global action present")

    local dev
    for _, item in ipairs(captured.items) do
      if item.name == "dev" then dev = item end
    end
    assert(dev, "dev present among picker items")
    eq(dev.env_file, "~/p/.env", "picker item carries env_file before promotion")

    global_action.fn(dev)

    local raw = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")
    local gdata = vim.fn.json_decode(raw)
    eq(gdata[1].name, "dev", "promoted entry name")
    eq(gdata[1].env_file, "~/p/.env", "env_file promoted to global file")
    eq(gdata[1].mode, "ro", "mode promoted to global file")
    eq(gdata[1].color, "orange", "color promoted to global file")
  end)
end)

-- ── list() rewriting the global file for a new g:dbs entry ────────────────
-- M.list() rewrites ~/.grip/connections.json whenever vim.g.dbs contains a
-- URL not yet in that file, so it can persist it there for cross-project
-- access. That rewrite re-serializes every existing global entry too -- a
-- third, easy-to-miss whitelist beyond read_json_connections/
-- write_file_connections/G:global.

test("list() persisting a new g:dbs entry does not drop fields off existing global entries", function()
  with_real_file(function(local_grip, global_grip)
    paths.ensure_dir(global_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "existing", url = "postgresql://a/b", env_file = "~/p/.env",
        mode = "ro", color = "orange" },
    }) }, global_grip .. "/connections.json")

    vim.g.dbs = { { name = "newdb", url = "postgresql://c/d" } }
    local ok, err = pcall(connections.list)
    vim.g.dbs = nil -- never leak into later specs sharing this nvim process
    assert(ok, err)

    local raw = table.concat(vim.fn.readfile(global_grip .. "/connections.json"), "\n")
    local data = vim.fn.json_decode(raw)
    local existing
    for _, e in ipairs(data) do if e.name == "existing" then existing = e end end
    assert(existing, "existing global entry still present after g:dbs-triggered rewrite")
    eq(existing.env_file, "~/p/.env", "env_file survived g:dbs-triggered global rewrite")
    eq(existing.mode, "ro", "mode survived g:dbs-triggered global rewrite")
    eq(existing.color, "orange", "color survived g:dbs-triggered global rewrite")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nconnections_fields_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
