dofile("tests/minimal_init.lua")
local c, db = require("dadbod-grip.completion"), require("dadbod-grip.db")
local pass, fail = 0, 0
local original = db.get_completion_functions_async
local schema = db.get_schema_batch
local URL = "duckdb:/synthetic/completion-functions.duckdb"
local callbacks, calls = {}, 0
db.get_completion_functions_async = function(url, callback)
  calls = calls + 1; callbacks[#callbacks + 1] = { url = url, callback = callback }
end
db.get_schema_batch = function() return { users = { { column_name = "name", data_type = "TEXT" } } } end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function has(items, word, menu)
  for _, item in ipairs(items) do
    if item.word == word and (not menu or item.menu == menu) then return item end
  end
end
local catalog = {
  { name = "list_sum", type = "scalar" }, { name = "read_csv", type = "table" },
  { name = "range", type = "table" }, { name = "sum", type = "aggregate" },
  { name = "my_macro", type = "macro" }, { name = "my_rows", type = "table_macro" },
}
test("cold function cache returns immediately and deduplicates requests", function()
  c.invalidate(URL)
  assert(#c.get_functions(URL) == 0)
  c.get_functions(URL); c.warm_functions(URL)
  assert(calls == 1, "cold requests flooded catalog")
  callbacks[1].callback(catalog)
  assert(#c.get_functions(URL) == #catalog)
end)
test("expression functions use proper item kinds without changing keywords", function()
  assert(has(c.complete("SELECT li", URL), "list_sum(", "[function]").kind == "function")
  assert(has(c.complete("SELECT su", URL), "sum("))
  assert(has(c.complete("SELECT my_", URL), "my_macro("))
  assert(not has(c.complete("SELECT ra", URL), "range("))
  assert(has(c.complete("sel", URL), "SELECT"))
end)
test("only FROM and JOIN offer relation functions", function()
  assert(has(c.complete("SELECT * FROM re", URL), "read_csv(", "[table function]"))
  assert(has(c.complete("SELECT * FROM users JOIN my_", URL), "my_rows("))
  assert(not has(c.complete("UPDATE ra", URL), "range("))
  assert(not has(c.complete("INSERT INTO ra", URL), "range("))
end)
test("invalidation rejects old callback and cannot clear the new pending owner", function()
  c.invalidate(URL); c.get_functions(URL)
  local old = callbacks[#callbacks]
  c.invalidate(URL); c.get_functions(URL)
  local fresh, count = callbacks[#callbacks], calls
  old.callback({ { name = "stale", type = "scalar" } })
  c.get_functions(URL)
  assert(calls == count, "stale callback cleared newer in-flight request")
  fresh.callback({ { name = "fresh", type = "scalar" } })
  assert(c.get_functions(URL)[1].name == "fresh")
end)
test("failure is bounded and retryable after invalidation", function()
  c.invalidate(URL); c.get_functions(URL)
  callbacks[#callbacks].callback(nil)
  local count = calls
  c.get_functions(URL); c.get_functions(URL)
  assert(calls == count, "failed request floods on typing")
  c.invalidate(URL); c.get_functions(URL)
  assert(calls == count + 1)
  callbacks[#callbacks].callback(catalog)
  assert(has(c.complete("SELECT li", URL), "list_sum("))
end)
db.get_completion_functions_async = original
db.get_schema_batch = schema
print(string.format("\ncompletion_functions_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
