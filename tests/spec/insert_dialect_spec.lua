-- Dialect INSERT/REPLACE preview boundaries; DB responses are mocked, not live.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data = require("dadbod-grip.db"), require("dadbod-grip.data")
local pass, fail = 0, 0
local notify, confirm = vim.notify, vim.fn.confirm
local original = {
  query = db.query, execute = db.execute, is_readonly = db.is_readonly,
  get_primary_keys = db.get_primary_keys, get_column_info = db.get_column_info,
}
local queries, writes, notices = {}, {}, {}
db.query = function(sql)
  queries[#queries + 1] = sql
  return { columns = { "id", "value" }, rows = { { "2", "old" } } }
end
db.execute = function(sql) writes[#writes + 1] = sql; error("preview attempted a write") end
db.is_readonly = function() return false end
db.get_primary_keys = function() return { "id" } end
db.get_column_info = function()
  return {
    { column_name = "id", data_type = "integer" },
    { column_name = "value", data_type = "text" },
  }
end
vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
end

local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected),
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function cleanup()
  local buffers = {}
  for buf in pairs(view._sessions) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    view._sessions[buf] = nil
  end
  while #vim.api.nvim_list_wins() > 1 do
    local wins = vim.api.nvim_list_wins()
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end
local function test(name, run)
  cleanup()
  queries, writes, notices = {}, {}, {}
  db.is_readonly = function() return false end
  db.execute = function(sql) writes[#writes + 1] = sql; error("preview attempted a write") end
  vim.fn.confirm = confirm
  local ok, err = pcall(run)
  vim.fn.confirm = confirm
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local cases = {
  {
    name = "SQL Server optional INTO", kind = "sqlserver",
    sql = "INSERT items(id,value) VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "SQL Server OUTPUT before VALUES", kind = "sqlserver",
    sql = "INSERT INTO items(id,value) OUTPUT inserted.id, inserted.value VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "SQL Server OUTPUT INTO destination columns", kind = "sqlserver",
    sql = "INSERT items(id,value) OUTPUT inserted.id, CONCAT(inserted.value,',VALUES')"
      .. " INTO audit_items(new_id,new_value) VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "SQL Server OUTPUT INTO and output to client", kind = "sqlserver",
    sql = "INSERT INTO items(id,value) OUTPUT inserted.id INTO @audit(id)"
      .. " OUTPUT inserted.value VALUES(3,'three'),(4,'four')",
    values = { { id = "3", value = "three" }, { id = "4", value = "four" } },
  },
  {
    name = "SQL Server OUTPUT before SELECT", kind = "sqlserver",
    sql = "INSERT INTO items(id,value) OUTPUT inserted.id SELECT id,value FROM other",
  },
  {
    name = "SQL Server OUTPUT before DEFAULT VALUES", kind = "sqlserver",
    sql = "INSERT INTO items OUTPUT inserted.id DEFAULT VALUES",
  },
  {
    name = "SQL Server quoted OUTPUT-shaped target columns", kind = "sqlserver",
    sql = "INSERT INTO [dbo].[items]([id],[value]) OUTPUT inserted.[VALUES] VALUES(3,'three')",
    table_name = "dbo.items", select = 'SELECT * FROM "dbo"."items"',
    values = { { id = "3", value = "three" } },
  },
  {
    name = "SQL Server OUTPUT Unicode expression values stay unknown", kind = "sqlserver",
    sql = "INSERT items(id,value) OUTPUT inserted.id VALUES(3,N'three')",
  },
  {
    name = "MySQL VALUES row and column aliases", kind = "mysql",
    sql = "INSERT INTO items(id,value) VALUES(3,'three') AS new(nid,nvalue)",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "MySQL row alias in ON DUPLICATE KEY UPDATE", kind = "mysql",
    sql = "INSERT INTO items(id,value) VALUES(2,'changed') AS new(nid,nvalue)"
      .. " ON DUPLICATE KEY UPDATE value=new.nvalue",
  },
  {
    name = "MySQL optional INTO and VALUE spelling", kind = "mysql",
    sql = "INSERT items(id,value) VALUE(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "MySQL VALUES ROW constructors", kind = "mysql",
    sql = "INSERT INTO items(id,value) VALUES ROW(3,'three'),ROW(4,'four')",
    values = { { id = "3", value = "three" }, { id = "4", value = "four" } },
  },
  {
    name = "MySQL priority modifier", kind = "mysql",
    sql = "INSERT LOW_PRIORITY INTO items(id,value) VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "MySQL INSERT SET literals and NULL", kind = "mysql",
    sql = "INSERT INTO items SET id=3,value=NULL",
    values = { { id = "3", value = data.NULL_SENTINEL } },
  },
  {
    name = "MySQL INSERT SET expression", kind = "mysql",
    sql = "INSERT INTO items SET id=3,value=CONCAT('a',',b')",
  },
  {
    name = "MySQL INSERT SET row alias", kind = "mysql",
    sql = "INSERT INTO items SET id=3,value='three' AS new",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "MySQL INSERT IGNORE", kind = "mysql",
    sql = "INSERT IGNORE INTO items(id,value) VALUES(2,'ignored')",
  },
  {
    name = "MySQL REPLACE optional INTO", kind = "mysql",
    sql = "REPLACE items(id,value) VALUES(2,'changed')", verb = "REPLACE",
  },
  {
    name = "MySQL hash comment around VALUES", kind = "mysql",
    sql = "INSERT INTO items(id,value) # VALUES(9,'fake')\n VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "PostgreSQL quoted source case and alias", kind = "postgresql",
    sql = 'INSERT INTO "Mixed"."Items" AS "I"("value","id") VALUES(\'three\',3)',
    table_name = "Mixed.Items", select = 'SELECT * FROM "Mixed"."Items"',
    values = { { id = "3", value = "three" } },
  },
  {
    name = "PostgreSQL dollar strings", kind = "postgresql",
    sql = "INSERT INTO items AS i(id,value) VALUES(3,$v$WHERE, VALUES (x)$v$)",
    values = { { id = "3", value = "WHERE, VALUES (x)" } },
  },
  {
    name = "PostgreSQL nested source comments", kind = "postgresql",
    sql = "INSERT INTO items /* outer /* VALUES(9,'fake') */ end */ AS i(id,value) VALUES(3,'three')",
    values = { { id = "3", value = "three" } },
  },
  {
    name = "PostgreSQL identity override", kind = "postgresql",
    sql = "INSERT INTO items(id,value) OVERRIDING SYSTEM VALUE VALUES(3,'three')",
  },
  {
    name = "PostgreSQL conflict and RETURNING parentheses", kind = "postgresql",
    sql = "INSERT INTO items AS i(id,value) VALUES(2,'changed') ON CONFLICT(id)"
      .. " DO UPDATE SET value=excluded.value WHERE i.id=2 RETURNING coalesce(value,'')",
  },
  {
    name = "DuckDB INSERT OR IGNORE", kind = "duckdb",
    sql = "INSERT OR IGNORE INTO items(id,value) VALUES(2,'ignored')",
  },
  {
    name = "DuckDB INSERT OR REPLACE", kind = "duckdb",
    sql = "INSERT OR REPLACE INTO items(id,value) VALUES(2,'changed')",
  },
  {
    name = "DuckDB BY NAME reorders source columns", kind = "duckdb",
    sql = "INSERT INTO items BY NAME (SELECT 'three' AS value, 3 AS id)",
  },
  {
    name = "DuckDB BY POSITION source query", kind = "duckdb",
    sql = "INSERT INTO items BY POSITION SELECT 3,'three'",
  },
  {
    name = "DuckDB BY POSITION explicit reversed columns", kind = "duckdb",
    sql = "INSERT INTO items BY POSITION (value,id) SELECT 'three',3",
  },
  {
    name = "DuckDB parenthesized VALUES query", kind = "duckdb",
    sql = "INSERT INTO items (VALUES(3,'three'))",
  },
  {
    name = "PostgreSQL parenthesized query without column list", kind = "postgresql",
    sql = "INSERT INTO items ((SELECT 3,'three')) RETURNING id",
  },
  {
    name = "PostgreSQL parenthesized query with column list", kind = "postgresql",
    sql = "INSERT INTO items(value,id) (SELECT 'three',3)",
  },
  {
    name = "MySQL parenthesized INSERT query", kind = "mysql",
    sql = "INSERT INTO items(id,value) (SELECT 3,'three')",
  },
  {
    name = "MySQL parenthesized REPLACE query", kind = "mysql",
    sql = "REPLACE INTO items(id,value) (SELECT 2,'changed')", verb = "REPLACE",
  },
  {
    name = "MySQL empty column list requests defaults", kind = "mysql",
    sql = "INSERT INTO items () VALUES ()",
  },
  {
    name = "MariaDB REPLACE SET with RETURNING", kind = "mysql",
    sql = "REPLACE INTO items SET id=2,value='changed' RETURNING id", verb = "REPLACE",
  },
  {
    name = "MySQL TABLE source", kind = "mysql",
    sql = "INSERT INTO items TABLE source_items",
  },
  {
    name = "DuckDB FROM-first source query", kind = "duckdb",
    sql = "INSERT INTO items FROM source_items",
  },
  {
    name = "DuckDB parenthesized FROM-first query", kind = "duckdb",
    sql = "INSERT INTO items BY NAME (FROM source_items)",
  },
  {
    name = "DuckDB VALUES query limit", kind = "duckdb",
    sql = "INSERT INTO items VALUES(3,'three'),(4,'four') LIMIT 1",
  },
  {
    name = "PostgreSQL VALUES compound query", kind = "postgresql",
    sql = "INSERT INTO items VALUES(3,'three') UNION ALL SELECT 4,'four'",
  },
  {
    name = "PostgreSQL VALUES query ordering and limit", kind = "postgresql",
    sql = "INSERT INTO items VALUES(3,'three'),(4,'four') ORDER BY 1 DESC LIMIT 1",
  },
}
for _, case in ipairs(cases) do
  test(case.name, function()
    if case.kind == "sqlserver" then db.is_readonly = original.is_readonly end
    grip.open(case.sql, case.kind .. "://unused/fixture", { from_pad = true })
    local session = assert(view._sessions[vim.api.nvim_get_current_buf()], table.concat(notices, "; "))
    local pending = assert(session.pending_mutation, "no pending mutation")
    eq(queries, { case.select or 'SELECT * FROM "items"' }, "generated SELECT")
    eq(pending.sql, case.sql, "original mutation retained")
    eq(pending.type, case.verb or "INSERT", "original verb")
    eq(pending.table_name, case.table_name or "items", "base-table metadata")
    local values, indices = {}, {}
    for index in pairs(session.state.inserted) do indices[#indices + 1] = index end
    table.sort(indices)
    for _, index in ipairs(indices) do values[#values + 1] = session.state.inserted[index].values end
    eq(values, case.values or {}, "staged literal tuples")
    if case.values then
      eq(pending.row_count, #case.values, "known input count")
    else
      eq(pending.row_count, nil, "unknown affected count")
      eq(pending.current_state, true, "current-state marker")
    end
    eq(writes, {}, "preview must not execute")
    eq(notices, {}, "no warnings/errors")
    if case.kind == "sqlserver" then
      eq(session.state.readonly, true, "SQL Server grid remains read-only")
      local apply = vim.fn.maparg(require("dadbod-grip.keymaps").get("grid_apply"), "n", false, true).callback
      vim.fn.confirm = function() return 2 end
      apply()
      eq(writes, {}, "declining confirmation must not execute")
      db.execute = function(sql) writes[#writes + 1] = sql; return { affected = 1 } end
      vim.fn.confirm = function() return 1 end
      apply()
      eq(writes, { case.sql }, "confirmed SQL executes exactly once despite read-only grid")
      eq(session.pending_mutation, nil, "confirmed mutation cleared")
      eq(notices, {}, "confirmation warnings/errors")
    end
  end)
end

for _, case in ipairs({
  { kind = "sqlserver", sql = "INSERT INTO items OUTPUT inserted.id VALUES(3,'three'); DELETE FROM items" },
  { kind = "sqlserver", sql = "INSERT INTO items OUTPUT inserted.id" },
  { kind = "sqlserver", sql = "INSERT INTO items OUTPUT VALUES(3,'three')" },
  { kind = "sqlserver", sql = "INSERT INTO items OUTPUT inserted.id INTO audit(id) EXEC proc_name" },
  { kind = "duckdb", sql = "INSERT OR ABORT INTO items VALUES(3,'three')" },
  { kind = "duckdb", sql = "INSERT INTO items BY WRONG SELECT 3,'three'" },
  { kind = "postgresql", sql = "INSERT INTO items (SELECT 3,'three'); DELETE FROM items" },
  { kind = "mysql", sql = "INSERT /*!50000 IGNORE */ INTO items(id,value) VALUES(3,'three')" },
  { kind = "mysql", sql = "REPLACE INTO items VALUES(3,'three'); DELETE FROM items" },
  { kind = "postgresql", sql = "INSERT INTO items(id,value) VALUES(3,'three'); DELETE FROM items" },
}) do
  test("reject ambiguous or multiple statements: " .. case.sql, function()
    grip.open(case.sql, case.kind .. "://unused/fixture", { from_pad = true })
    for _, session in pairs(view._sessions) do
      assert(not session.pending_mutation, "unsafe SQL opened a preview")
    end
    eq(queries, {}, "unsafe statement must not issue a guessed SELECT")
    eq(writes, {}, "unsafe statement must not execute")
    assert(#notices > 0, "rejection must explain the unsupported preview")
  end)
end

cleanup()
for name, fn in pairs(original) do db[name] = fn end
vim.notify = notify
print(string.format("\ninsert_dialect_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
