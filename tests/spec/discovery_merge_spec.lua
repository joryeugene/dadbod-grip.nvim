-- discovery_merge_spec.lua: a discovered container and a connections.json
-- entry that share a URL must yield one entry carrying the container's
-- identity and the file's settings.
--
-- Before the merge landed, M.list() dropped the file entry whole and its
-- mode/color went with it -- a `mode: "ro"` seatbelt that silently unfastened
-- whenever the matching Docker stack happened to be up.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

-- Rebound to a freshly loaded module by every with_real_file() below.
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

local DOCKER_URL = "postgresql://postgres:postgres@localhost:6810/app"

-- ── harness ───────────────────────────────────────────────────────────────
-- The file/home patching is the one from connections_fields_spec.lua:43 --
-- see that file for why each patch exists. Added here: the discovery source
-- is stubbed, since M.list() consults it before anything else and the real
-- one shells out to `docker ps`.
local function with_real_file(discovered, fn)
  local project_dir = vim.fn.tempname() .. "_grip_disc_merge_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_opts = grip.get_opts()
  local orig_connections = package.loaded["dadbod-grip.connections"]
  local orig_docker = package.loaded["dadbod-grip.sources.docker_localdb"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({}) -- deterministic OPTS baseline (discovery on, connections_path nil)
  package.loaded["dadbod-grip.sources.docker_localdb"] = {
    fetch = function() return { connections = discovered } end,
  }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")

  local ok, err = pcall(fn, project_dir .. "/.grip")

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  grip.setup(orig_opts)
  package.loaded["dadbod-grip.connections"] = orig_connections
  package.loaded["dadbod-grip.sources.docker_localdb"] = orig_docker
  connections = orig_connections

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

local function write_conns(dir, entries)
  paths.ensure_dir(dir)
  vim.fn.writefile({ vim.fn.json_encode(entries) }, dir .. "/connections.json")
end

local function find(list, url)
  for _, c in ipairs(list) do
    if c.url == url then return c end
  end
end

local function container(name, url)
  return { name = name, url = url, source = "docker" }
end

-- ── the defect ────────────────────────────────────────────────────────────

test("a collision keeps the file entry's mode and color", function()
  with_real_file({ container("app (docker)", DOCKER_URL) }, function(dir)
    write_conns(dir, { { name = "app", url = DOCKER_URL, mode = "ro", color = "red" } })
    local c = find(connections.list(), DOCKER_URL)
    assert(c, "entry present")
    eq(c.mode, "ro", "mode merged from the file entry")
    eq(c.color, "red", "color merged from the file entry")
  end)
end)

test("a collision keeps env_file and type", function()
  with_real_file({ container("app (docker)", DOCKER_URL) }, function(dir)
    write_conns(dir, {
      { name = "app", url = DOCKER_URL, env_file = "~/p/.env", type = "postgresql" },
    })
    local c = find(connections.list(), DOCKER_URL)
    assert(c, "entry present")
    eq(c.env_file, "~/p/.env", "env_file merged")
    eq(c.type, "postgresql", "type merged")
  end)
end)

-- ── what must not change ──────────────────────────────────────────────────

test("a collision keeps the container's name", function()
  with_real_file({ container("app (docker)", DOCKER_URL) }, function(dir)
    write_conns(dir, { { name = "app", url = DOCKER_URL, mode = "ro", color = "red" } })
    local c = find(connections.list(), DOCKER_URL)
    assert(c, "entry present")
    eq(c.name, "app (docker)", "the live container names the entry")
  end)
end)

test("a discovered entry with no file counterpart is unchanged", function()
  local solo = "postgresql://u:p@localhost:6811/solo"
  with_real_file({ container("solo (docker)", solo) }, function(dir)
    write_conns(dir, { { name = "other", url = "postgresql://u:p@localhost:9999/other" } })
    local c = find(connections.list(), solo)
    assert(c, "discovered entry present")
    eq(c.mode, nil, "no mode invented")
    eq(c.color, nil, "no color invented")
  end)
end)

test("a file entry with no container is unchanged", function()
  local filed = "postgresql://u:p@localhost:7000/db"
  with_real_file({}, function(dir)
    write_conns(dir, { { name = "filed", url = filed, mode = "ro", color = "green" } })
    local c = find(connections.list(), filed)
    assert(c, "file entry present")
    eq(c.mode, "ro", "mode intact")
    eq(c.color, "green", "color intact")
  end)
end)

-- ── summary ───────────────────────────────────────────────────────────────

print(string.format("\ndiscovery_merge_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
