-- requery_spinner_spec.lua: every grid reload shows the ui.blocking spinner,
-- not just the first query.
--
-- init.open() wrapped its opening query in ui.blocking, but on_requery (sort,
-- filter, pagination -- H/L, [p/]p, X) and on_refresh (R) called db.query
-- straight through. On a slow connection those keys froze the editor with no
-- indicator at all, so the grid looked hung.
--
-- Uses tests/seed_sqlite.db.

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local qmod = require("dadbod-grip.query")
local ui   = require("dadbod-grip.ui")

local url = "sqlite:tests/seed_sqlite.db"

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(type(s) == "string" and s:find(pattern, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

-- ── harness ───────────────────────────────────────────────────────────────

-- Record every spinner message while still running the wrapped work, so the
-- grid ends up in the same state it would in a real session. `depth` tracks
-- whether we are currently inside a float, so a test can assert *where* the db
-- round-trips happen, not just that a spinner appeared at some point.
local spins = {}
local depth = 0
local real_blocking = ui.blocking
local function stub_blocking(msg, fn)
  table.insert(spins, msg)
  depth = depth + 1
  local rets = { pcall(fn) }
  depth = depth - 1
  local ok = table.remove(rets, 1)
  if not ok then error(rets[1], 0) end
  return unpack(rets)
end
ui.blocking = stub_blocking

--- Wrap every db entry point that costs a round-trip, recording the ones that
--- run with no spinner up. Returns the unspinnered call names.
local function db_calls_outside_spinner(fn)
  local db = require("dadbod-grip.db")
  local watched = { "query", "get_primary_keys", "get_column_info", "get_foreign_keys" }
  local real, naked = {}, {}
  for _, name in ipairs(watched) do
    real[name] = db[name]
    db[name] = function(...)
      if depth == 0 then table.insert(naked, name) end
      return real[name](...)
    end
  end
  local ok, err = pcall(fn)
  for _, name in ipairs(watched) do db[name] = real[name] end
  assert(ok, "call under test threw: " .. tostring(err))
  return naked
end

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

--- Open a real grid through the public entry point so the callbacks under test
--- (on_requery / on_refresh) are the ones init.lua actually wires.
local function open_grid(tbl)
  cleanup_grids()
  spins = {}
  grip.open(tbl, url, {})
  local bufnr, session = next(view._sessions)
  if bufnr then return bufnr, session end
  error("no grid session created for " .. tbl)
end

--- Spinner messages recorded since the last reset.
local function take_spins()
  local s = spins
  spins = {}
  return s
end

-- ── the opening query (the path that already worked) ──────────────────────

test("open: opening query shows a spinner", function()
  open_grid("users")
  local s = take_spins()
  truthy(#s >= 1, "expected a spinner during open")
  contains(table.concat(s, "\n"), "users", "spinner names the table")
end)

-- ── pagination: H / L / [p / ]p ───────────────────────────────────────────

test("on_requery: next page shows a spinner", function()
  local bufnr, session = open_grid("users")
  take_spins()
  session.on_requery(bufnr, qmod.next_page(session.query_spec))
  local s = take_spins()
  truthy(#s >= 1, "expected a spinner while loading the next page")
end)

test("on_requery: page change still lands on the requested page", function()
  local bufnr, session = open_grid("users")
  session.on_requery(bufnr, qmod.set_page(session.query_spec, 1))
  assert(view._sessions[bufnr].query_spec.page == 1, "page kept")
end)

-- ── sorting: s / S ────────────────────────────────────────────────────────

test("on_requery: sort shows a spinner", function()
  local bufnr, session = open_grid("users")
  take_spins()
  session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "id"))
  local s = take_spins()
  truthy(#s >= 1, "expected a spinner while sorting")
end)

test("on_requery: sort still reaches the grid", function()
  local bufnr, session = open_grid("users")
  session.on_requery(bufnr, qmod.toggle_sort(session.query_spec, "id"))
  local spec = view._sessions[bufnr].query_spec
  truthy(#spec.sorts == 1, "sort recorded on the session spec")
end)

-- ── refresh: R ────────────────────────────────────────────────────────────

test("on_refresh: manual refresh shows a spinner", function()
  local bufnr, session = open_grid("users")
  take_spins()
  session.on_refresh(bufnr)
  local s = take_spins()
  truthy(#s >= 1, "expected a spinner while refreshing")
end)

-- ── one spinner per reload, not a flicker of two ──────────────────────────

test("on_requery: the count query and the page query share one spinner", function()
  local bufnr, session = open_grid("users")
  take_spins()
  session.on_requery(bufnr, qmod.next_page(session.query_spec))
  local s = take_spins()
  assert(#s == 1, "expected exactly 1 spinner, got " .. #s .. ": " .. table.concat(s, " | "))
end)

-- ── the spinner has to stay up until the grid is ready ────────────────────

-- The opening SELECT was inside the float, but the primary-key lookup and the
-- pagination COUNT were not: on a remote connection the spinner vanished and
-- the editor then sat frozen through two more round-trips before the grid
-- appeared.
test("open: every db round-trip happens inside the spinner", function()
  cleanup_grids()
  local naked = db_calls_outside_spinner(function() grip.open("users", url, {}) end)
  assert(#naked == 0,
    "these db calls ran with no spinner up: " .. table.concat(naked, ", "))
end)

test("open: the grid still knows the row count", function()
  local bufnr = open_grid("users")
  assert(view._sessions[bufnr].total_rows == 15,
    "total_rows: expected 15, got " .. tostring(view._sessions[bufnr].total_rows))
end)

-- ── the spinner must not swallow the error ────────────────────────────────

-- ui.blocking() forwards its fn's returns through table.unpack, which drops
-- everything after a leading nil -- so a `return nil, err` from inside the
-- float would reach the caller as no values at all and the real db error
-- would be replaced by "unknown error". Run this one against the REAL
-- ui.blocking: the stub above forwards returns faithfully and would hide it.
test("on_requery: a failed query still reports the db error", function()
  local bufnr, session = open_grid("users")
  ui.blocking = real_blocking

  local db = require("dadbod-grip.db")
  local real_query  = db.query
  local real_notify = vim.notify
  local notified = {}
  db.query = function() return nil, "boom: connection refused" end
  vim.notify = function(msg) table.insert(notified, tostring(msg)) end

  local ok, err = pcall(session.on_requery, bufnr, qmod.next_page(session.query_spec))

  db.query   = real_query
  vim.notify = real_notify
  ui.blocking = stub_blocking

  assert(ok, "on_requery threw: " .. tostring(err))
  contains(table.concat(notified, "\n"), "boom: connection refused", "db error surfaced")
end)

cleanup_grids()
ui.blocking = real_blocking

print(string.format("requery_spinner_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
