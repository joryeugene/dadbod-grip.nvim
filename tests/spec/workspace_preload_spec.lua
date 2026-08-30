-- workspace_preload_spec.lua: the workspace must not be assembled on screen.
--
-- Opening a connection used to paint three times: an empty sidebar while the
-- table list was still being fetched, then an empty content area, then the
-- query pad dropping in. Every step here exists to keep that from coming back.
dofile("tests/minimal_init.lua")

local schema = require("dadbod-grip.schema")
local db     = require("dadbod-grip.db")

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

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

--- Is a schema sidebar window on screen right now?
local function sidebar_on_screen()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "grip_schema" then
      return true
    end
  end
  return false
end

--- Run fn() with db.list_tables/list_routines stubbed out, then restore.
--- `on_fetch` is called at the moment the table list is asked for -- the
--- point where a real connection blocks on a round-trip.
local function with_stubbed_db(on_fetch, fn)
  local real_tables, real_routines = db.list_tables, db.list_routines
  db.list_tables = function()
    if on_fetch then on_fetch() end
    return { { type = "table", name = "users" }, { type = "table", name = "orders" } }
  end
  db.list_routines = function() return {} end
  local ok, err = pcall(fn)
  db.list_tables, db.list_routines = real_tables, real_routines
  if not ok then error(err, 0) end
end

test("toggle: schema is fetched before the sidebar window exists", function()
  schema.close()
  schema._reset_state()
  local sidebar_during_fetch
  with_stubbed_db(
    function() sidebar_during_fetch = sidebar_on_screen() end,
    function() schema.toggle("sqlite:tests/seed_sqlite.db") end)
  schema.close()
  eq(sidebar_during_fetch, false, "no empty sidebar on screen while fetching")
end)

test("toggle: the sidebar is populated the moment it opens", function()
  schema.close()
  schema._reset_state()
  with_stubbed_db(nil, function() schema.toggle("sqlite:tests/seed_sqlite.db") end)
  local buf = vim.fn.bufnr("grip://schema")
  assert(buf ~= -1, "sidebar buffer exists")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local joined = table.concat(lines, "\n")
  schema.close()
  assert(joined:find("users", 1, true), "table list rendered on open, not after")
end)

test("prefetch: fills state without opening any window", function()
  schema.close()
  schema._reset_state()
  local before = #vim.api.nvim_list_wins()
  with_stubbed_db(nil, function() schema.prefetch("sqlite:tests/seed_sqlite.db") end)
  eq(#vim.api.nvim_list_wins(), before, "prefetch opened no window")
  eq(sidebar_on_screen(), false, "prefetch showed no sidebar")
end)

test("prefetch: a second call does not re-query", function()
  schema.close()
  schema._reset_state()
  local calls = 0
  with_stubbed_db(function() calls = calls + 1 end, function()
    schema.prefetch("sqlite:tests/seed_sqlite.db")
    schema.prefetch("sqlite:tests/seed_sqlite.db")
  end)
  eq(calls, 1, "cached schema is reused")
end)

test("switch: a real connection opens the complete prefetched workspace", function()
  local result = vim.system({
    vim.g.grip_test_progpath,
    "--headless",
    "-u", "tests/minimal_init.lua",
    "-l", "tests/fixtures/workspace_preload_integration.lua",
  }, { text = true }):wait()
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
end)

test("switch: open_sidebar=false opens the main workspace without a sidebar", function()
  local result = vim.system({
    vim.g.grip_test_progpath,
    "--headless",
    "-u", "tests/minimal_init.lua",
    "-l", "tests/fixtures/workspace_no_sidebar_integration.lua",
  }, { text = true }):wait()
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
end)

test("workspace layout remains usable at the natural headless width", function()
  local result = vim.system({
    vim.g.grip_test_progpath,
    "--headless",
    "-u", "tests/minimal_init.lua",
    "-l", "tests/fixtures/workspace_layout_integration.lua",
  }, { text = true }):wait()
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
end)

print(string.format("workspace_preload_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
