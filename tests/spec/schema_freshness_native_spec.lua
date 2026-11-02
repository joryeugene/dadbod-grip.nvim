-- Public SQLite facade and sidebar callbacks against task-owned databases.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, completion, schema = require("dadbod-grip.db"), require("dadbod-grip.completion"), require("dadbod-grip.schema")
local function names(url)
  local result = {}
  for name in pairs(completion.get_schema(url)) do result[name] = true end
  return result
end
local function has_column(url, table_name, column)
  for _, col in ipairs(completion.get_schema(url)[table_name] or {}) do
    if col.column_name == column then return true end
  end
  return false
end
local function external(c, sql)
  local result = vim.system({ "sqlite3", c.url:sub(8) }, { stdin = sql, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function check_exec(c, sql)
  local result, err = db.execute(sql, c.url)
  assert(result, err)
end

H.test("CREATE invalidates warmed completion and hidden sidebar table state", function(c)
  c.exec("CREATE TABLE initial(id INTEGER PRIMARY KEY)")
  assert(names(c.url).initial)
  local state = schema.prefetch(c.url)
  check_exec(c, "CREATE TABLE added(id INTEGER PRIMARY KEY)")
  assert(names(c.url).added, "new table absent from completion")
  assert(state.items == nil, "sidebar table cache was retained")
  assert(#schema.prefetch(c.url).items == 2)
end)

H.test("ALTER refreshes columns and clears PK/FK/sidebar row count caches", function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY)")
  assert(has_column(c.url, "items", "id"))
  local state = schema.prefetch(c.url)
  state.col_cache.items = { { column_name = "id" } }
  state.pk_cache.items, state.fk_cache.items, state.row_count_cache = { id = true }, { old = true }, { items = 2 }
  check_exec(c, "ALTER TABLE items ADD COLUMN fresh TEXT")
  assert(has_column(c.url, "items", "fresh"), "ALTER kept old completion columns")
  assert(not next(state.col_cache) and not next(state.pk_cache) and not next(state.fk_cache)
    and not next(state.row_count_cache), "sidebar metadata caches survived ALTER")
end)

H.test("RENAME and DROP remove old completion names", function(c)
  c.exec("CREATE TABLE old_name(id INTEGER)")
  assert(names(c.url).old_name)
  check_exec(c, "ALTER TABLE old_name RENAME TO new_name")
  local list = names(c.url)
  assert(list.new_name and not list.old_name, "rename kept old table name")
  check_exec(c, "DROP TABLE new_name")
  assert(not names(c.url).new_name, "drop kept removed table name")
end)

H.test("successful query-based DDL also invalidates schema", function(c)
  c.exec("CREATE TABLE initial(id INTEGER)")
  assert(names(c.url).initial)
  local result, err = db.query("CREATE TABLE via_query(id INTEGER)", c.url)
  assert(result, err)
  assert(names(c.url).via_query, "db.query DDL kept old completion")
end)

H.test("failed DDL retains accurate completion contents", function(c)
  c.exec("CREATE TABLE items(id INTEGER)")
  local before = completion.get_schema(c.url)
  local result, err = db.execute("ALTER TABLE missing ADD COLUMN fresh TEXT", c.url)
  assert(not result and err)
  H.eq(completion.get_schema(c.url), before, "failed DDL invented a schema change")
end)

H.test("explicit connection invalidation cannot follow ambient URL changes", function(c)
  c.exec("CREATE TABLE items(id INTEGER)")
  local other = "sqlite:" .. c.root .. "/other.sqlite"
  local result, err = db.execute("CREATE TABLE other_items(id INTEGER)", other)
  assert(result, err)
  local other_cache = completion.get_schema(other)
  assert(names(c.url).items)
  vim.g.db = other
  check_exec(c, "CREATE TABLE correct_target(id INTEGER)")
  assert(names(c.url).correct_target)
  assert(completion.get_schema(other) == other_cache, "ambient database cache was invalidated")
end)

H.test("manual sidebar refresh exposes external DDL to completion", function(c)
  c.exec("CREATE TABLE items(id INTEGER)")
  assert(has_column(c.url, "items", "id"))
  schema.close(); schema._reset_state(); schema.toggle(c.url)
  local buf = vim.api.nvim_win_get_buf(schema.get_winid())
  external(c, "ALTER TABLE items ADD COLUMN external_col TEXT")
  H.key(buf, require("dadbod-grip.keymaps").get("sidebar_refresh"))
  assert(has_column(c.url, "items", "external_col"), "manual sidebar refresh kept old completion")
  schema.close(); schema._reset_state()
end)

H.test("public confirmed DDL invalidates completion but cancellation does not", function(c)
  c.exec("CREATE TABLE initial(id INTEGER)")
  local before = completion.get_schema(c.url)
  local grip = require("dadbod-grip")
  vim.fn.confirm = function() return 2 end
  grip.open("CREATE TABLE cancelled(id INTEGER)", c.url, { from_pad = true })
  assert(completion.get_schema(c.url) == before, "cancel invalidated schema")
  H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='cancelled'"), "0")
  vim.fn.confirm = function() return 1 end
  grip.open("CREATE TABLE confirmed(id INTEGER)", c.url, { from_pad = true })
  assert(names(c.url).confirmed, "confirmed public DDL kept old completion")
end)

H.test("a cache invalidator failure cannot turn committed DDL into refusal", function(c)
  c.exec("CREATE TABLE initial(id INTEGER)")
  completion.get_schema(c.url)
  local invalidate = completion.invalidate
  completion.invalidate = function() error("controlled cache failure") end
  local result, err = db.execute("CREATE TABLE committed(id INTEGER)", c.url)
  completion.invalidate = invalidate
  assert(result and not err, "committed write became a refusal")
  H.eq(c.scalar("SELECT count(*) FROM sqlite_master WHERE name='committed'"), "1")
  vim.wait(5)
  assert(table.concat(c.notices, "\n"):find("cache invalidation failed", 1, true), "cache failure was silent")
  invalidate(c.url)
end)

H.test("implicit URL is captured before a client wait changes ambient connection", function(c)
  c.exec("CREATE TABLE items(id INTEGER)")
  local other = "sqlite:" .. c.root .. "/other.sqlite"
  assert(db.execute("CREATE TABLE other_items(id INTEGER)", other))
  local before_other = completion.get_schema(other)
  assert(names(c.url).items)
  local adapter = require("dadbod-grip.adapters.sqlite")
  local execute = adapter.execute
  adapter.execute = function(...)
    local result, err = execute(...)
    vim.g.db = other
    return result, err
  end
  vim.g.db = c.url
  local result, err = db.execute("CREATE TABLE captured(id INTEGER)")
  adapter.execute = execute
  assert(result, err)
  assert(names(c.url).captured, "completion followed changed ambient URL")
  assert(completion.get_schema(other) == before_other)
end)

H.test("templated and resolved cache keys are invalidated together", function(c)
  c.exec("CREATE TABLE items(id INTEGER)")
  local template, env_file = "${SCHEMA_FRESHNESS_URL}", c.root .. "/schema.env"
  vim.fn.writefile({ "SCHEMA_FRESHNESS_URL=" .. c.url }, env_file)
  vim.fn.writefile({ vim.json.encode({ { name = "schema", url = template, env_file = env_file } }) },
    c.root .. "/project/.grip/connections.json")
  assert(names(template).items and names(c.url).items)
  local result, err = db.execute("CREATE TABLE both_keys(id INTEGER)", template)
  assert(result, err)
  assert(names(template).both_keys and names(c.url).both_keys, "one URL spelling kept old schema")
end)

H.test("native DuckDB CREATE ALTER rename and DROP refresh completion", function(c)
  assert(vim.fn.executable("duckdb") == 1, "native DuckDB is required for this acceptance")
  local url = "duckdb:" .. c.root .. "/schema.duckdb"
  assert(db.execute("CREATE TABLE original(id INTEGER)", url))
  assert(names(url).original)
  assert(db.execute("ALTER TABLE original ADD COLUMN fresh VARCHAR", url))
  assert(has_column(url, "original", "fresh"))
  assert(db.execute("ALTER TABLE original RENAME TO renamed", url))
  assert(names(url).renamed and not names(url).original)
  assert(db.execute("DROP TABLE renamed", url))
  assert(not names(url).renamed)
end)

for _, method in ipairs({ "execute", "query" }) do
  H.test(method .. " partial DDL failure preserves its error and discards stale schema", function(c)
    c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY)")
    assert(not has_column(c.url, "items", "committed"))
    local result, err = db[method]("ALTER TABLE items ADD COLUMN committed TEXT; SELECT * FROM missing_table", c.url)
    assert(not result and err and err:find("missing_table", 1, true), "native later-statement error was changed")
    local native = vim.system({ "sqlite3", c.url:sub(8), "PRAGMA table_info(items)" }, { text = true }):wait()
    assert(native.code == 0 and native.stdout:find("committed", 1, true), "first statement did not actually commit")
    assert(has_column(c.url, "items", "committed"), "partial success retained an obsolete schema")
  end)
end

H.test("invalidated visible sidebar reloads on its next expansion", function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY)")
  schema.close(); schema._reset_state(); schema.toggle(c.url)
  local win, state = schema.get_winid(), schema.get_state(c.url)
  local buf = vim.api.nvim_win_get_buf(win)
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" and node.name == "items" then vim.api.nvim_win_set_cursor(win, { i + 2, 0 }); break end
  end
  assert(db.execute("ALTER TABLE items ADD COLUMN fresh TEXT", c.url))
  H.key(buf, "l")
  local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  schema.close(); schema._reset_state()
  assert(lines:find("items", 1, true) and lines:find("fresh", 1, true), "invalidated sidebar became empty")
end)

H.test("EXPLAIN ANALYZE DDL invalidates but plain EXPLAIN preserves nonexecution", function(c)
  local url = "duckdb:" .. c.root .. "/explain.duckdb"
  assert(db.execute("CREATE TABLE original(id INTEGER)", url))
  assert(names(url).original)
  local explain, explain_err = db.query("EXPLAIN CREATE TABLE not_created AS SELECT 1 AS id", url)
  assert(explain, explain_err)
  local function exists(name)
    local oracle = vim.system({ "duckdb", url:sub(8), "-csv", "-c",
      "SELECT table_name FROM information_schema.tables WHERE table_name='" .. name .. "'" }, { text = true }):wait()
    assert(oracle.code == 0, oracle.stderr)
    return oracle.stdout:find(name, 1, true) ~= nil
  end
  assert(not exists("not_created"), "plain EXPLAIN executed DDL")
  local analyzed, analyze_err = db.query("EXPLAIN ANALYZE CREATE TABLE created AS SELECT 1 AS id", url)
  assert(analyzed, analyze_err)
  assert(exists("created"), "EXPLAIN ANALYZE did not execute its original")
  assert(names(url).created, "executed EXPLAIN ANALYZE DDL retained old completion")
end)

H.test("file sidebar lazily refreshes once and retains cached file columns between paints", function(c)
  local path = c.root .. "/rows.csv"
  vim.fn.writefile({ "id,value", "1,one" }, path)
  schema.close(); schema._reset_state()
  local query, calls = db.query, 0
  db.query = function(...) calls = calls + 1; return query(...) end
  local ok, err = xpcall(function()
    schema.toggle(path)
    assert(calls == 1, "initial file schema fetch missing")
    schema.redraw(); schema.redraw()
    assert(calls == 1, "cached file schema refetched on every paint")
    vim.fn.writefile({ "id,value,added", "1,one,fresh" }, path)
    assert(db.invalidate_schema(path))
    schema.redraw()
    assert(calls == 2, "invalidated file schema did not refresh exactly once")
    schema.redraw()
    assert(calls == 2)
    local buf = vim.api.nvim_win_get_buf(schema.get_winid())
    assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("added", 1, true))
  end, debug.traceback)
  db.query = query
  schema.close(); schema._reset_state()
  assert(ok, err)
end)

H.finish("schema_freshness_native_spec")
