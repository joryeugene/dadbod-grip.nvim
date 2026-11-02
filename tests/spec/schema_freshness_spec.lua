dofile("tests/minimal_init.lua")
local completion, schema = require("dadbod-grip.completion"), require("dadbod-grip.schema")
local db = require("dadbod-grip.db")
local pass, fail = 0, 0
local function test(name, fn)
  local saved = {}
  for _, key in ipairs({ "get_schema_batch", "get_schema_batch_async", "list_tables", "list_routines",
      "get_column_info", "get_primary_keys", "get_foreign_keys" }) do saved[key] = db[key] end
  local ok, err = xpcall(fn, debug.traceback)
  for key, value in pairs(saved) do db[key] = value end
  schema.close(); schema._reset_state()
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function payload(name) return { [name] = { { column_name = "id", data_type = "integer" } } } end
local URL = "sqlite:/synthetic/schema-freshness.sqlite"

test("invalidated async warm cannot repopulate the old schema", function()
  local callback
  completion.invalidate(URL)
  db.get_schema_batch_async = function(_, cb) callback = cb end
  db.get_schema_batch = function() return payload("fresh") end
  completion.warm_schema(URL)
  completion.invalidate(URL)
  callback(payload("old"))
  assert(completion.get_schema(URL).fresh, "old warm overwrote invalidation")
end)

test("newer async warm owns cache even when old callback arrives last", function()
  local callbacks = {}
  completion.invalidate(URL)
  db.get_schema_batch_async = function(_, cb) callbacks[#callbacks + 1] = cb end
  completion.warm_schema(URL); completion.warm_schema(URL)
  callbacks[2](payload("fresh")); callbacks[1](payload("old"))
  assert(completion.get_schema(URL).fresh, "older request replaced newer completion")
end)

test("synchronous schema fetch cannot store or return an invalidated snapshot", function()
  completion.invalidate(URL)
  local calls = 0
  db.get_schema_batch = function()
    calls = calls + 1
    if calls == 1 then completion.invalidate(URL); return payload("old") end
    return payload("fresh")
  end
  assert(not completion.get_schema(URL).old, "invalidated sync fetch returned old suggestions")
  assert(completion.get_schema(URL).fresh, "invalidated sync fetch populated the cache")
end)

test("a synchronous fetch supersedes an earlier warm", function()
  local callback
  completion.invalidate(URL)
  db.get_schema_batch_async = function(_, cb) callback = cb end
  db.get_schema_batch = function() return payload("fresh") end
  completion.warm_schema(URL)
  assert(completion.get_schema(URL).fresh)
  callback(payload("old"))
  assert(completion.get_schema(URL).fresh, "old warm replaced newer synchronous schema")
end)

test("connection invalidation also fences federated warm keys", function()
  local callback
  local fed = URL .. "::warehouse"
  completion.invalidate(fed)
  db.get_schema_batch_async = function(_, cb) callback = cb end
  db.get_schema_batch = function() return payload("fresh") end
  completion.warm_schema(fed)
  completion.invalidate(URL)
  callback(payload("old"))
  assert(completion.get_schema(fed).fresh, "federated request survived parent invalidation")
end)

test("invalidation does not discard another connection's completed warm", function()
  local other = URL .. ".other"
  db.get_schema_batch_async = function(_, cb) cb(payload("other")) end
  completion.warm_schema(other); completion.invalidate(URL)
  assert(completion.get_schema(other).other, "unrelated URL was invalidated")
end)

test("schema table fetch invalidated while waiting cannot repopulate sidebar", function()
  local calls = 0
  db.list_tables = function()
    calls = calls + 1
    if calls == 1 then schema.refresh(URL); return { { name = "old", type = "table" } } end
    return { { name = "fresh", type = "table" } }
  end
  db.list_routines = function() return {} end
  local state = schema.prefetch(URL)
  assert(state.items == nil, "old in-flight table list repopulated invalidated sidebar")
  assert(schema.prefetch(URL).items[1].name == "fresh")
end)

test("refreshing hidden URL cannot paint it into the visible connection", function()
  local a, b = URL .. "a", URL .. "b"
  db.list_tables = function(url) return { { name = url == a and "only_a" or "only_b", type = "table" } } end
  db.list_routines = function() return {} end
  schema.toggle(b)
  local buf = vim.api.nvim_win_get_buf(schema.get_winid())
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  schema.refresh(a)
  assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)),
    "refresh painted an unrelated connection")
  assert(vim.b[buf].db == b)
end)

test("explicit connection switch rebinds visible schema and redraw ownership", function()
  local a, b = URL .. "a", URL .. "b"
  db.list_tables = function(url) return { { name = url == a and "only_a" or "only_b", type = "table" } } end
  db.list_routines = function() return {} end
  schema.toggle(a)
  schema.refresh(b, { switch = true })
  local buf = vim.api.nvim_win_get_buf(schema.get_winid())
  assert(vim.b[buf].db == b, "switch left old buffer connection")
  schema.redraw()
  local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(lines:find("only_b", 1, true) and not lines:find("only_a", 1, true), "redraw restored old schema")
end)

test("refresh completion cannot redraw a closed sidebar", function()
  db.list_tables = function() return { { name = "initial", type = "table" } } end
  db.list_routines = function() return {} end
  schema.toggle(URL)
  db.list_tables = function() schema.close(); return { { name = "fresh", type = "table" } } end
  schema.refresh(URL)
  assert(not schema.is_open(), "refresh reopened a cancelled sidebar")
end)

local function with_adapter(fn)
  local adapters = require("dadbod-grip.adapters")
  local resolve = adapters.resolve
  local adapter = { query = function() return { columns = {}, rows = {} } end,
    execute = function() return { affected = 0 } end }
  adapters.resolve = function() return adapter end
  local ok, err = xpcall(function() fn(adapter) end, debug.traceback)
  adapters.resolve = resolve
  assert(ok, err)
end

test("query invalidation scans tokenized statement heads without rewriting SQL", function()
  with_adapter(function(adapter)
    db.get_schema_batch = function() return payload("fresh") end
    local read_sql = "SELECT 'CREATE TABLE a(x);' AS value /* DROP TABLE b; */"
    completion.invalidate(URL)
    local before = completion.get_schema(URL)
    local sent
    adapter.query = function(sql) sent = sql; return { columns = {}, rows = {} } end
    assert(db.query(read_sql, URL)); assert(sent == read_sql)
    assert(completion.get_schema(URL) == before, "read text was mistaken for DDL")
    local batch = "SELECT 1; /* admitted custom batch */ CREATE TABLE added(id INTEGER)"
    assert(db.query(batch, URL)); assert(sent == batch)
    assert(completion.get_schema(URL) ~= before, "later DDL statement was missed")
  end)
end)

test("optional adapter invalidation is clear-only and uses the original connection", function()
  with_adapter(function(adapter)
    local calls = {}
    adapter.invalidate_schema = function(url) calls[#calls + 1] = url end
    assert(db.invalidate_schema(URL))
    assert(vim.deep_equal(calls, { URL }))
  end)
end)

test("failed execution cannot clear metadata or call adapter invalidation", function()
  with_adapter(function(adapter)
    db.get_schema_batch = function() return payload("fresh") end
    completion.invalidate(URL)
    local before, calls = completion.get_schema(URL), 0
    adapter.execute = function() return nil, "controlled SQL rejection" end
    adapter.invalidate_schema = function() calls = calls + 1 end
    local result, err = db.execute("CREATE TABLE bad(id INTEGER)", URL)
    assert(not result and err)
    assert(calls == 0 and completion.get_schema(URL) == before)
  end)
end)

print(string.format("schema_freshness_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
