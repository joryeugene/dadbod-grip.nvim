-- discovery_spec.lua: tests for sources/docker_localdb.lua.
-- Stubs vim.fn.systemlist, vim.fn.executable, vim.v.shell_error so the
-- shell-out boundary is fully controlled.
local discovery = require("dadbod-grip.sources.docker_localdb")

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
  assert(
    a == b,
    (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)
  )
end

-- ── Stub harness ──────────────────────────────────────────────────────────

local _orig_systemlist = vim.fn.systemlist
local _orig_executable = vim.fn.executable
local _orig_v = vim.v
local _orig_shell_error = vim.v.shell_error
local _orig_hrtime_uv = vim.uv and vim.uv.hrtime or nil
local _orig_hrtime_loop = vim.loop and vim.loop.hrtime or nil

-- Mutable clock so we can advance through TTL boundaries deterministically.
local _now = 0
local function set_now(ns) _now = ns end
local function fake_hrtime() return _now end

local _systemlist_calls = 0
local function stub_docker(lines, shell_error)
  _systemlist_calls = 0
  vim.fn.executable = function(_) return 1 end
  vim.fn.systemlist = function(_)
    _systemlist_calls = _systemlist_calls + 1
    vim.v = setmetatable({ shell_error = shell_error or 0 }, {
      __index = _orig_shell_error and getmetatable(_orig_shell_error) or {},
    })
    return lines
  end
  -- (Re)install the fake clock. reset_stubs() at the end of each test
  -- restores the real hrtime, so we have to reinstall here for set_now()
  -- to be read by the module under test in the next stub_docker call.
  if vim.uv then vim.uv.hrtime = fake_hrtime end
  if vim.loop then vim.loop.hrtime = fake_hrtime end
end

local function reset_stubs()
  vim.fn.systemlist = _orig_systemlist
  vim.fn.executable = _orig_executable
  vim.v = _orig_v
  if _orig_hrtime_uv and vim.uv then vim.uv.hrtime = _orig_hrtime_uv end
  if _orig_hrtime_loop and vim.loop then vim.loop.hrtime = _orig_hrtime_loop end
  discovery._reset_cache()
end

-- Install fake clock once. Tests advance _now to control the TTL.
if vim.uv then vim.uv.hrtime = fake_hrtime end
if vim.loop then vim.loop.hrtime = fake_hrtime end

-- ── Helpers ───────────────────────────────────────────────────────────────

local function row(name, user, db, password, host_port)
  -- name=nil yields a row missing the name label.
  local labels = { ["dev.localdb.kind"] = "postgres" }
  if name then labels["dev.localdb.name"] = name end
  if user then labels["dev.localdb.user"] = user end
  if db then labels["dev.localdb.database"] = db end
  if password then labels["dev.localdb.password"] = password end
  return vim.json.encode({
    Labels = labels,
    Ports = host_port and (host_port .. "->5432/tcp") or "5432/tcp",
  })
end

-- ── Tests ─────────────────────────────────────────────────────────────────

test("single labeled postgres yields one connection", function()
  set_now(1e10)
  discovery._reset_cache()
  stub_docker({
    row("nucleus jory-v3", "nucleus", "nucleus", "nucleus_dev_password", "0.0.0.0:6810"),
  })
  local result = discovery.fetch()
  eq(#result.connections, 1, "connection count")
  eq(result.connections[1].name, "nucleus jory-v3", "name")
  eq(
    result.connections[1].url,
    "postgresql://nucleus:nucleus_dev_password@localhost:6810/nucleus",
    "url"
  )
  eq(result.connections[1].source, "docker", "source tag")
  eq(result.error, nil, "no error")
  reset_stubs()
end)

test("three labeled containers yield three sorted entries", function()
  set_now(2e10)
  discovery._reset_cache()
  stub_docker({
    row("nucleus jory-v3", "nucleus", "nucleus", "pw", "0.0.0.0:6810"),
    row("alpha", "u", "d", "pw", "0.0.0.0:6900"),
    row("nucleus main", "nucleus", "nucleus", "pw", "0.0.0.0:6811"),
  })
  local result = discovery.fetch()
  eq(#result.connections, 3, "connection count")
  -- Sorted alphabetically by name.
  eq(result.connections[1].name, "alpha", "first")
  eq(result.connections[2].name, "nucleus jory-v3", "second")
  eq(result.connections[3].name, "nucleus main", "third")
  reset_stubs()
end)

test("missing dev.localdb.user is skipped", function()
  set_now(3e10)
  discovery._reset_cache()
  stub_docker({
    row("good", "nucleus", "nucleus", "pw", "0.0.0.0:6810"),
    row("bad-no-user", nil, "nucleus", "pw", "0.0.0.0:6811"),
  })
  -- Wait, `row()` builds without user when user param is nil. Patch:
  -- We want to drop just user, keep name. Use raw json.
  vim.fn.systemlist = function(_)
    return {
      vim.json.encode({
        Labels = {
          ["dev.localdb.kind"] = "postgres",
          ["dev.localdb.name"] = "good",
          ["dev.localdb.user"] = "nucleus",
          ["dev.localdb.database"] = "nucleus",
          ["dev.localdb.password"] = "pw",
        },
        Ports = "0.0.0.0:6810->5432/tcp",
      }),
      vim.json.encode({
        Labels = {
          ["dev.localdb.kind"] = "postgres",
          ["dev.localdb.name"] = "bad-no-user",
          -- user missing
          ["dev.localdb.database"] = "nucleus",
        },
        Ports = "0.0.0.0:6811->5432/tcp",
      }),
    }
  end
  local result = discovery.fetch()
  eq(#result.connections, 1, "only the labeled-correctly row survives")
  eq(result.connections[1].name, "good", "good row")
  reset_stubs()
end)

test("docker not on PATH yields empty list and no exception", function()
  set_now(4e10)
  discovery._reset_cache()
  vim.fn.executable = function(_) return 0 end
  local result = discovery.fetch()
  eq(#result.connections, 0, "empty")
  assert(result.error ~= nil, "error string set")
  reset_stubs()
end)

test("docker daemon down (shell_error != 0) yields empty list", function()
  set_now(5e10)
  discovery._reset_cache()
  stub_docker({ "Cannot connect to the Docker daemon" }, 1)
  local result = discovery.fetch()
  eq(#result.connections, 0, "empty on daemon failure")
  reset_stubs()
end)

test("ipv6 dual-stack port maps to localhost", function()
  set_now(6e10)
  discovery._reset_cache()
  stub_docker({
    vim.json.encode({
      Labels = {
        ["dev.localdb.kind"] = "postgres",
        ["dev.localdb.name"] = "ipv6",
        ["dev.localdb.user"] = "u",
        ["dev.localdb.database"] = "d",
        ["dev.localdb.password"] = "p",
      },
      -- Both IPv4 and IPv6 published; we should pick the 5432 mapping and
      -- emit "localhost" as the host.
      Ports = "0.0.0.0:6900->5432/tcp, :::6900->5432/tcp",
    }),
  })
  local result = discovery.fetch()
  eq(#result.connections, 1, "one connection")
  eq(result.connections[1].url, "postgresql://u:p@localhost:6900/d", "url uses localhost")
  reset_stubs()
end)

test("multi-port container picks the 5432 mapping", function()
  set_now(7e10)
  discovery._reset_cache()
  stub_docker({
    vim.json.encode({
      Labels = {
        ["dev.localdb.kind"] = "postgres",
        ["dev.localdb.name"] = "multiport",
        ["dev.localdb.user"] = "u",
        ["dev.localdb.database"] = "d",
        ["dev.localdb.password"] = "p",
      },
      -- 5433 listed first; 5432 should still win.
      Ports = "0.0.0.0:7000->5433/tcp, 0.0.0.0:7001->5432/tcp",
    }),
  })
  local result = discovery.fetch()
  eq(result.connections[1].url, "postgresql://u:p@localhost:7001/d", "5432 mapping wins")
  reset_stubs()
end)

test("two calls within TTL yield only one shell-out", function()
  set_now(8e10)
  discovery._reset_cache()
  stub_docker({ row("a", "u", "d", "p", "0.0.0.0:6800") })
  discovery.fetch()
  set_now(8e10 + 1e9)  -- 1s later, well within 2s TTL
  discovery.fetch()
  eq(_systemlist_calls, 1, "only one shell-out under TTL")
  reset_stubs()
end)

test("calls past TTL re-shell", function()
  set_now(9e10)
  discovery._reset_cache()
  stub_docker({ row("a", "u", "d", "p", "0.0.0.0:6800") })
  discovery.fetch()
  set_now(9e10 + 3e9)  -- 3s later, past 2s TTL
  discovery.fetch()
  eq(_systemlist_calls, 2, "re-shell after TTL")
  reset_stubs()
end)

test("two containers with identical names get port suffix", function()
  set_now(1e11)
  discovery._reset_cache()
  stub_docker({
    row("nucleus", "u", "d", "p", "0.0.0.0:6810"),
    row("nucleus", "u", "d", "p", "0.0.0.0:6811"),
  })
  local result = discovery.fetch()
  eq(#result.connections, 2, "two connections")
  -- Names should be disambiguated with the host port.
  assert(result.connections[1].name:find("(6810)", 1, true), "first has port suffix")
  assert(result.connections[2].name:find("(6811)", 1, true), "second has port suffix")
  reset_stubs()
end)

test("unpublished container (no host port) is skipped", function()
  set_now(11e10)
  discovery._reset_cache()
  stub_docker({
    vim.json.encode({
      Labels = {
        ["dev.localdb.kind"] = "postgres",
        ["dev.localdb.name"] = "unpublished",
        ["dev.localdb.user"] = "u",
        ["dev.localdb.database"] = "d",
        ["dev.localdb.password"] = "p",
      },
      Ports = "5432/tcp",  -- not published to host
    }),
  })
  local result = discovery.fetch()
  eq(#result.connections, 0, "unpublished is skipped")
  reset_stubs()
end)

test("malformed JSON line is skipped, valid lines kept", function()
  set_now(12e10)
  discovery._reset_cache()
  vim.fn.executable = function(_) return 1 end
  vim.fn.systemlist = function(_)
    return {
      "{not valid json",
      vim.json.encode({
        Labels = {
          ["dev.localdb.kind"] = "postgres",
          ["dev.localdb.name"] = "good",
          ["dev.localdb.user"] = "u",
          ["dev.localdb.database"] = "d",
          ["dev.localdb.password"] = "p",
        },
        Ports = "0.0.0.0:6810->5432/tcp",
      }),
    }
  end
  local result = discovery.fetch()
  eq(#result.connections, 1, "only valid row survives")
  eq(result.connections[1].name, "good", "valid row")
  reset_stubs()
end)

-- Restore stubs at end of file just in case.
reset_stubs()

-- Summary
print(string.format("\ndiscovery_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
