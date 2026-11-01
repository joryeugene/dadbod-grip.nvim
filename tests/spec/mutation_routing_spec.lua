-- Statement routing must protect writes before any query/count request.
-- Database boundaries are mocked: these are not live-server dialect tests.
local grip, db = require("dadbod-grip"), require("dadbod-grip.db")
local history = require("dadbod-grip.history")
local original = {
  query = db.query, execute = db.execute, confirm = vim.fn.confirm,
  notify = vim.notify, record = history.record,
}
local pass, fail = 0, 0
local writes, queries, prompts, notices
local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected),
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function test(name, run)
  writes, queries, prompts, notices = {}, {}, 0, {}
  db.query = function(sql) queries[#queries + 1] = sql; return nil, "unexpected query" end
  db.execute = function(sql) writes[#writes + 1] = sql; return { affected = 1 } end
  vim.notify = function(message, level)
    if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
  end
  history.record = function() end
  local ok, err = pcall(run)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local mutations = {
  { kind = "mysql", sql = "WITH src AS (SELECT 2 AS id) DELETE LOW_PRIORITY FROM items"
      .. " WHERE id IN (SELECT id FROM src)" },
  { kind = "mysql", sql = "WITH src AS (SELECT 2 AS id) DELETE QUICK IGNORE FROM items"
      .. " WHERE id IN (SELECT id FROM src)" },
  { kind = "mysql", sql = "WITH src AS (SELECT 2 AS id) DELETE i FROM items i JOIN src ON i.id=src.id" },
  { kind = "mysql", sql = "WITH src AS (SELECT 2 AS id) DELETE LOW_PRIORITY i.*"
      .. " FROM items i JOIN src ON i.id=src.id" },
  { kind = "mysql", url = "mariadb://unused/fixture",
    sql = "WITH src AS (SELECT 2 AS id) DELETE IGNORE FROM items WHERE id IN (SELECT id FROM src)" },
  { kind = "mysql", sql = "-- start\nWITH src AS (SELECT 2 AS id)"
      .. " delete /* modifier */ low_priority from items WHERE id IN (SELECT id FROM src);" },
  { kind = "postgresql", sql = "WITH changed AS (DELETE FROM items WHERE id=2 RETURNING *)"
      .. " SELECT * FROM changed" },
  { kind = "postgresql", sql = "WITH changed AS (UPDATE items SET value='new' RETURNING *)"
      .. " SELECT * FROM changed" },
  { kind = "postgresql", sql = "WITH changed AS (INSERT INTO items VALUES (3,'new') RETURNING *)"
      .. " SELECT * FROM changed" },
  { kind = "sqlite", sql = "WITH src AS (SELECT 3 AS id,'new' AS value)"
      .. " INSERT OR IGNORE INTO items SELECT * FROM src" },
  { kind = "sqlite", sql = "WITH src AS (SELECT 3 AS id,'new' AS value)"
      .. " REPLACE INTO items SELECT * FROM src" },
  { kind = "duckdb", sql = "WITH src AS (SELECT 3 AS id,'new' AS value)"
      .. " INSERT INTO items BY NAME SELECT * FROM src" },
}
for _, kind in ipairs({ "postgresql", "duckdb", "sqlserver" }) do
  for _, action in ipairs({
    "WHEN MATCHED THEN DELETE",
    "WHEN MATCHED THEN UPDATE SET value=s.value",
    "WHEN NOT MATCHED THEN INSERT (id,value) VALUES (s.id,s.value)",
  }) do
    local sql = "MERGE INTO items AS t USING source_items AS s ON t.id=s.id " .. action .. ";"
    mutations[#mutations + 1] = { kind = kind, sql = sql }
    mutations[#mutations + 1] = {
      kind = kind, sql = "WITH src AS (SELECT * FROM source_items) "
        .. sql:gsub("USING source_items AS s", "USING src AS s"),
    }
  end
end
for _, target in ipairs({ "items", "[dbo].[items]", "TOP (1) items", "@items" }) do
  local sql = "MERGE " .. target .. " AS t USING source_items AS s ON t.id=s.id WHEN MATCHED THEN DELETE;"
  mutations[#mutations + 1] = { kind = "sqlserver", sql = sql }
  mutations[#mutations + 1] = { kind = "sqlserver",
    sql = "WITH src(id) AS (SELECT id FROM source_items), picked AS (SELECT * FROM src) " .. sql }
end
-- Command positions, including nested WITH bodies, remain write boundaries.
for _, sql in ipairs({
  "WITH src AS (SELECT 1 AS id), changed AS (DELETE FROM items RETURNING *) SELECT * FROM changed",
  "WITH changed AS (WITH src AS (SELECT 1 AS id) UPDATE items SET value='new' RETURNING *) SELECT * FROM changed",
  "WITH src AS MATERIALIZED (SELECT 1 AS id) DELETE FROM items WHERE id IN (SELECT id FROM src)",
  "WITH RECURSIVE src(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
    .. " SEARCH DEPTH FIRST BY id SET update DELETE FROM items WHERE id IN (SELECT id FROM src)",
  "WITH RECURSIVE src(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
    .. " CYCLE id SET delete USING path UPDATE items SET value='new' WHERE id IN (SELECT id FROM src)",
}) do
  mutations[#mutations + 1] = { kind = "postgresql", sql = sql }
end
for _, kind in ipairs({ "sqlite", "duckdb", "postgresql", "mysql", "sqlserver" }) do
  mutations[#mutations + 1] = { kind = kind,
    sql = "WITH src AS (SELECT 1 AS id) SELECT * FROM src; DELETE FROM items WHERE id=1" }
end
mutations[#mutations + 1] = { kind = "sqlserver",
  sql = "WITH src AS (SELECT 1 AS id) SELECT * FROM src UPDATE items SET value='new' WHERE id=1" }
mutations[#mutations + 1] = { kind = "sqlserver",
  sql = "WITH CHANGE_TRACKING_CONTEXT (0x01) UPDATE items SET value='new' WHERE id=1" }
for _, sql in ipairs({
  "WITH RECURSIVE src(set) AS (SELECT 1 UNION ALL SELECT set+1 FROM src WHERE set<2)"
    .. " SEARCH DEPTH FIRST BY set SET seq, changed AS (DELETE FROM items RETURNING *) SELECT * FROM changed",
  "WITH src AS (SELECT 1 AS id) SELECT * FROM src; EXPLAIN ANALYZE UPDATE items SET value='new'",
  "WITH src AS (SELECT 1 AS id) SELECT * FROM src; EXPLAIN (ANALYZE true, VERBOSE true)"
    .. " WITH changed AS (DELETE FROM items RETURNING *) SELECT * FROM changed",
  "WITH src AS (SELECT 1 AS id) SELECT * FROM src;"
    .. " (WITH changed AS (DELETE FROM items RETURNING *) SELECT * FROM changed)",
}) do
  mutations[#mutations + 1] = { kind = "postgresql", sql = sql }
end
for _, case in ipairs(mutations) do
  test("confirmed original statement: " .. case.kind .. " " .. case.sql, function()
    local spec, _, _, mutation = grip._resolve_query(case.sql, 100, case.kind)
    eq(spec, nil, "write must not become a raw query")
    eq(mutation, case.sql, "original SQL retained")
    local url = case.url or case.kind .. "://unused/fixture"
    vim.fn.confirm = function(_, _, default)
      prompts = prompts + 1
      eq(default, 2, "default is cancel")
      return 2
    end
    grip.open(case.sql, url, { from_pad = true })
    eq(prompts, 1, "cancel confirmation")
    eq(writes, {}, "cancel has zero writes")
    eq(queries, {}, "cancel has zero queries or counts")
    vim.fn.confirm = function() prompts = prompts + 1; return 1 end
    grip.open(case.sql, url, { from_pad = true })
    eq(prompts, 2, "execution confirmation")
    eq(writes, { case.sql }, "original SQL executes exactly once")
    eq(queries, {}, "write never enters query/count")
    eq(notices, {}, "no warning/error")
  end)
end

local reads = {
  { kind = "mysql", sql = "WITH src AS (SELECT 1 AS id) SELECT @update AS value FROM src" },
  { kind = "mysql", sql = "WITH src AS (SELECT 1 AS id) SELECT @delete FROM src" },
  { kind = "sqlite", sql = "WITH src AS (SELECT 1 AS id) SELECT @update AS value FROM src" },
  { kind = "sqlite", sql = "WITH src AS (SELECT 1 AS id) SELECT :update AS value FROM src" },
  { kind = "sqlite", sql = "WITH src AS (SELECT 1 AS id) SELECT :delete FROM src" },
  { kind = "mysql", sql = "WITH src AS (SELECT 1 AS id) SELECT * FROM items FOR UPDATE SKIP LOCKED" },
  { kind = "postgresql", sql = "WITH src AS (SELECT 1 AS id) SELECT * FROM items FOR UPDATE OF items NOWAIT" },
  { kind = "postgresql", sql = "WITH src AS (SELECT 1 AS id) SELECT * FROM items FOR NO KEY UPDATE OF items" },
}
for _, kind in ipairs({ "sqlite", "duckdb", "postgresql", "mysql", "sqlserver" }) do
  for _, sql in ipairs({
    "WITH src AS (SELECT 'MERGE INTO x DELETE IGNORE FROM y' AS value) SELECT * FROM src",
    "WITH src AS (SELECT 1 AS id /* MERGE INTO x */) SELECT * FROM src -- DELETE i FROM items i",
    "WITH src AS (SELECT REPLACE('MERGE','M','m') AS value) SELECT * FROM src",
    'WITH "merge" AS (SELECT 1 AS id) SELECT * FROM "merge"',
    "WITH src AS (SELECT 1 AS id) SELECT src.merge AS value FROM src",
    "WITH src AS (SELECT 1 AS id) SELECT (id) AS merge FROM src",
    "WITH src AS (SELECT 1 AS id) SELECT * FROM (SELECT * FROM src) AS merge",
  }) do
    reads[#reads + 1] = { kind = kind, sql = sql }
  end
end
-- PostgreSQL UPDATE/DELETE/INSERT are non-reserved identifiers. Their position,
-- not a following keyword, decides whether they are commands.
for _, keyword in ipairs({ "update", "delete", "insert", "merge" }) do
  for _, sql in ipairs({
    "WITH src AS (SELECT 1 AS id) SELECT id AS " .. keyword .. " FROM src",
    "WITH src AS (SELECT 1 AS " .. keyword .. ") SELECT " .. keyword .. " FROM src",
    "WITH " .. keyword .. " AS (SELECT 1 AS id) SELECT * FROM " .. keyword .. " u",
    "WITH " .. keyword .. "(id) AS NOT MATERIALIZED (SELECT 1) SELECT * FROM " .. keyword,
    "WITH RECURSIVE src(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
      .. " SEARCH DEPTH FIRST BY id SET " .. keyword .. " SELECT * FROM src",
    "WITH RECURSIVE src(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
      .. " CYCLE id SET " .. keyword .. " USING path SELECT * FROM src",
  }) do
    reads[#reads + 1] = { kind = "postgresql", sql = sql }
  end
end
reads[#reads + 1] = { kind = "duckdb",
  sql = "WITH RECURSIVE src(id) USING KEY (id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
    .. " SELECT * FROM src" }
reads[#reads + 1] = { kind = "sqlserver",
  sql = "WITH XMLNAMESPACES ('urn:example' AS ns), src AS (SELECT 1 AS id) SELECT * FROM src" }
reads[#reads + 1] = { kind = "mysql",
  sql = "WITH RECURSIVE src(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM src WHERE id<2)"
    .. " CYCLE id RESTRICT SELECT * FROM src" }
for _, sql in ipairs({
  "WITH RECURSIVE src(set) AS (SELECT 1 UNION ALL SELECT set+1 FROM src WHERE set<2)"
    .. " SEARCH DEPTH FIRST BY set SET update SELECT * FROM src",
  "WITH RECURSIVE src(set,id) AS (SELECT 1,1 UNION ALL SELECT set+1,id+1 FROM src WHERE set<2)"
    .. " SEARCH BREADTH FIRST BY set,id SET update SELECT * FROM src",
  "WITH src AS (SELECT 1 AS id) SELECT * FROM src; EXPLAIN ANALYZE SELECT 1 AS update",
  "WITH src AS (SELECT 1 AS id) SELECT * FROM src; (WITH update AS (SELECT 1 AS id) SELECT * FROM update)",
}) do
  reads[#reads + 1] = { kind = "postgresql", sql = sql }
end
for _, case in ipairs(reads) do
  test("query lexical boundary: " .. case.kind .. " " .. case.sql, function()
    local spec, _, _, mutation = grip._resolve_query(case.sql, 100, case.kind)
    assert(spec and spec.is_raw, "CTE SELECT remains a query")
    eq(mutation, nil, "query must not become a write")
  end)
end
for _, kind in ipairs({ "sqlite", "duckdb", "postgresql", "mysql", "sqlserver" }) do
  test("bare merge table: " .. kind, function()
    local spec, table_name, _, mutation = grip._resolve_query("merge", 100, kind)
    assert(spec and not spec.is_raw, "bare table remains a table query")
    eq(table_name, "merge", "table metadata")
    eq(mutation, nil, "bare table is not a command")
  end)
end

for _, kind in ipairs({ "sqlite", "duckdb", "postgresql", "mysql", "sqlserver" }) do
  test("keyword prefixes are complete table identifiers: " .. kind, function()
    for _, table_name in ipairs({
      "select_items", "update_log", "delete_queue", "insert_jobs", "replace_log",
      "merge_items", "with_cache", "begin_notes", "commit_log", "rollback_log",
      "select1", "select$items", "select_数据",
    }) do
      local spec, target, _, mutation = grip._resolve_query(table_name, 100, kind)
      assert(spec and not spec.is_raw, table_name .. " remains a table query")
      eq(target, table_name, "table metadata")
      eq(mutation, nil, "identifier prefix is not a command")
    end
  end)
end
test("SQL Server SELECT can precede a variable without whitespace", function()
  local spec, _, _, mutation = grip._resolve_query("SELECT@value", 100, "sqlserver")
  assert(spec and spec.is_raw, "keyword-adjacent variable remains a query")
  eq(mutation, nil, "variable suffix is not a table")
end)
test("MySQL hash still starts a keyword-adjacent comment", function()
  local sql = "WITH# comment\nsrc AS (SELECT 1 AS id) SELECT * FROM src"
  local spec, _, _, mutation = grip._resolve_query(sql, 100, "mysql")
  assert(spec and spec.is_raw, "WITH hash comment retains query routing")
  eq(mutation, nil, "comment does not change command")
end)

db.query, db.execute = original.query, original.execute
vim.fn.confirm, vim.notify, history.record = original.confirm, original.notify, original.record
print(string.format("\nmutation_routing_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
