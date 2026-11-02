dofile("tests/minimal_init.lua")
local c, db = require("dadbod-grip.completion"), require("dadbod-grip.db")
local pass, fail = 0, 0
if vim.fn.executable("duckdb") == 0 then
  assert(vim.env.GRIP_REQUIRE_DUCKDB ~= "1", "DuckDB is required")
  print("SKIP completion_functions_live_spec: duckdb unavailable"); return
end
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, "p")
local url = "duckdb:" .. dir .. "/fixture.duckdb"
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function find(items, name, kind)
  for _, item in ipairs(items) do if item.name == name and item.type == kind then return true end end
end
local function fetch()
  local items
  db.get_completion_functions_async(url, function(result) items = result end)
  assert(vim.wait(10000, function() return items ~= nil end, 10), "catalog did not complete")
  return items
end
test("real catalog contains overload-deduplicated scalar and relation functions", function()
  assert(db.execute("CREATE TABLE users(id INTEGER, name VARCHAR)", url))
  local items, seen = fetch(), {}
  assert(find(items, "list_sum", "macro") or find(items, "list_sum", "scalar"))
  assert(find(items, "read_csv", "table") and find(items, "sum", "aggregate"))
  for _, item in ipairs(items) do
    local key = item.name .. ":" .. item.type
    assert(not seen[key], "duplicate overload " .. key); seen[key] = true
  end
end)
test("persisted macros follow real DDL invalidation and stale cache fencing", function()
  c.invalidate(url); c.warm_functions(url)
  assert(vim.wait(10000, function() return #c.get_functions(url) > 0 end, 10))
  assert(not find(c.get_functions(url), "grip_feature_macro", "macro"))
  assert(db.execute("CREATE MACRO grip_feature_macro(x) AS x + 1", url))
  assert(#c.get_functions(url) == 0, "DDL retained stale function cache")
  assert(vim.wait(10000, function() return find(c.get_functions(url), "grip_feature_macro", "macro") end, 10))
  assert(db.execute("DROP MACRO grip_feature_macro", url))
  assert(#c.get_functions(url) == 0)
  assert(vim.wait(10000, function() return #c.get_functions(url) > 0 end, 10))
  assert(not find(c.get_functions(url), "grip_feature_macro", "macro"))
end)
test("another adapter never falls back to query for function discovery", function()
  local queried, saved = false, db.query
  db.query = function() queried = true; error("unexpected query") end
  local result
  db.get_completion_functions_async("sqlite:" .. dir .. "/other.db", function(items) result = items or false end)
  db.query = saved
  assert(result == false and not queried)
end)
c.invalidate(url); vim.fn.delete(dir, "rf")
print(string.format("\ncompletion_functions_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
