-- Cross-adapter release scenario: real schema, CRUD, filter/sort/pagination,
-- requery, and export. CI assigns one live URL and makes skipping fatal.

local URL = vim.env.GRIP_TEST_LIVE_URL
local REQUIRED = vim.env.GRIP_REQUIRE_LIVE == "1"

local function unavailable(reason)
  if REQUIRED then error("live_workflow_spec: " .. reason .. " while GRIP_REQUIRE_LIVE=1") end
  print("SKIP: live_workflow_spec (" .. reason .. ")")
  print("\nlive_workflow_spec: 0 passed, 0 failed (skipped)")
end

if not URL or URL == "" then
  unavailable("GRIP_TEST_LIVE_URL not set")
  return
end

local db = require("dadbod-grip.db")
local query = require("dadbod-grip.query")
local view = require("dadbod-grip.view")

if not db.ping(URL) then
  unavailable("database is unreachable")
  return
end

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

local function eq(actual, expected, message)
  assert(actual == expected,
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

test("schema exposes seeded tables and primary keys", function()
  local tables, err = db.list_tables(URL)
  assert(tables, err)
  local found = false
  for _, item in ipairs(tables) do
    if item.name == "orders" or item.name == "dbo.orders" then found = true end
  end
  assert(found, "orders table missing: " .. vim.inspect(tables))
  local cols = assert(db.get_column_info("orders", URL))
  eq(cols[1].column_name, "id", "first column")
  eq(db.get_primary_keys("orders", URL)[1], "id", "primary key")
end)

test("CRUD round-trip changes only the probe table", function()
  db.execute("DROP TABLE IF EXISTS grip_live_probe", URL)
  local ok, err = pcall(function()
    assert(db.execute(
      "CREATE TABLE grip_live_probe (id INTEGER PRIMARY KEY, probe_value VARCHAR(40) NOT NULL)", URL))
    assert(db.execute(
      "INSERT INTO grip_live_probe (id, probe_value) VALUES (1, 'first'), (2, 'second')", URL))
    assert(db.execute("UPDATE grip_live_probe SET probe_value = 'updated' WHERE id = 2", URL))
    local result = assert(db.query("SELECT id, probe_value FROM grip_live_probe ORDER BY id", URL))
    eq(#result.rows, 2, "inserted rows")
    eq(result.rows[2][2], "updated", "updated value")
    assert(db.execute("DELETE FROM grip_live_probe WHERE id = 1", URL))
    eq(#assert(db.query("SELECT id FROM grip_live_probe", URL)).rows, 1, "deleted row")
  end)
  db.execute("DROP TABLE IF EXISTS grip_live_probe", URL)
  if not ok then error(err) end
end)

test("filter, sort, pagination, and requery preserve their contract", function()
  local spec = query.new_table("orders", 25)
  spec = query.add_filter(spec, '"id" > 25')
  spec = query.toggle_sort(spec, "id")
  spec = query.set_page(spec, 2)

  local page = assert(db.query(query.build_sql(spec), URL))
  eq(#page.rows, 25, "second page size")
  eq(tonumber(page.rows[1][1]), 51, "filter + offset")

  local count = assert(db.query(query.build_count_sql(spec), URL))
  eq(tonumber(count.rows[1][1]), 125, "matching count")

  local requery = query.set_page(query.toggle_sort(spec, "id"), 1)
  local reversed = assert(db.query(query.build_sql(requery), URL))
  eq(tonumber(reversed.rows[1][1]), 150, "requery applies descending sort")
end)

test("all-row export is complete and atomically written", function()
  local spec = query.add_filter(query.new_table("orders", 25), '"id" > 25')
  spec = query.toggle_sort(spec, "id")
  local result = assert(db.query(query.build_sql(spec, { paginate = false }), URL))
  eq(#result.rows, 125, "all matching rows fetched")

  local path = vim.fn.tempname() .. ".csv"
  local ok, err = view._write_export_file(result.rows, result.columns, "csv", "orders", path)
  assert(ok, err)
  eq(#vim.fn.readfile(path), 126, "header plus every matching row")
  eq(#vim.fn.glob(path .. ".grip-tmp-*", false, true), 0, "no partial file remains")
  vim.fn.delete(path)
end)

print(string.format("\nlive_workflow_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
