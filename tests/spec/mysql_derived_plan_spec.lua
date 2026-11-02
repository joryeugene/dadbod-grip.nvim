-- Static routing/header proof. No database, client or original query executes.
local read = require("dadbod-grip.mysql_read")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a)) end
local function plan(sql)
  local result, err = read.plan(sql)
  assert(result, err)
  return result
end

test("explicit AS count/labels are known without evaluating a function", function()
  local p = plan("SELECT task_tick() AS value FROM tasks ORDER BY id LIMIT 3 OFFSET 1")
  eq(p.route, "derived"); eq(p.columns, { "value" }); eq(p.header_provenance, { "explicit_as" })
  eq(p.source.table, "tasks"); eq(p.has_limit, true)
  eq(p.slots[1].kind, "computed")
end)
test("direct projected labels preserve SQL spelling, source parts and column order", function()
  local p = plan('SELECT q.ID,q.`payload` FROM "sample"."tasks" AS q ORDER BY q.ID')
  eq(p.columns, { "ID", "payload" }); eq(p.source.schema, "sample"); eq(p.source.alias, "q")
  eq(p.slots[1].column, "ID"); eq(p.slots[2].column, "payload")
end)
test("DISTINCT retains original projection and slots", function()
  local p = plan("SELECT DISTINCT category FROM tasks ORDER BY category DESC")
  eq(p.route, "derived"); eq(p.columns, { "category" })
  assert(read.derived_sql(p):find("SELECT DISTINCT category FROM tasks ORDER BY category DESC", 1, true))
end)
test("maximal LIMIT is appended after the complete SELECT and before trailing comments", function()
  local p = plan("SELECT task_tick() AS value FROM tasks ORDER BY id; -- tail")
  local sql = read.derived_sql(p)
  assert(sql:find("ORDER BY id\nLIMIT 18446744073709551615", 1, true), sql)
  assert(sql:find("-- tail", 1, true), sql)
  assert(not sql:find("CREATE", 1, true)); assert(not sql:find("LIMIT 0", 1, true))
end)
test("an existing LIMIT/OFFSET is never duplicated or augmented with a new column", function()
  local sql = read.derived_sql(plan("SELECT id,payload FROM tasks ORDER BY id DESC LIMIT 3 OFFSET 1"))
  local _, count = sql:gsub("LIMIT", ""); eq(count, 1)
  assert(sql:find("SELECT id,payload FROM tasks ORDER BY id DESC LIMIT 3 OFFSET 1", 1, true), sql)
  assert(not sql:find("NULL AS", 1, true), sql)
end)
test("known natural headers are quoted as single identifiers and exposed exactly", function()
  local p = plan('SELECT tick() AS "a.b" FROM tasks ORDER BY id')
  eq(p.columns, { "a.b" })
  local sql = read.derived_sql(p)
  assert(sql:find("raw.`a.b`", 1, true), sql)
  assert(sql:find("AS `a.b`", 1, true), sql)
  assert(not sql:find("AS raw(", 1, true), sql)
end)
test("natural field references retain original projected casing", function()
  local sql = read.derived_sql(plan("SELECT ID,mixed FROM tasks ORDER BY id"))
  assert(sql:find("raw.`ID`", 1, true) and sql:find("AS `ID`", 1, true), sql)
  assert(sql:find("raw.`mixed`", 1, true) and sql:find("AS `mixed`", 1, true), sql)
end)
for _, case in ipairs({
  { '`table with spaces`', '`quoted column`', 'table with spaces', 'quoted column' },
  { '`δοκιμή`', '`имя`', 'δοκιμή', 'имя' },
  { '`literal.table`', '`literal.column`', 'literal.table', 'literal.column' },
  { '`table``name`', '`column``name`', 'table`name', 'column`name' },
  { '"table""name"', '"column""name"', 'table"name', 'column"name' },
}) do
  test("quoted source/header spelling remains certifiable: " .. case[3], function()
    local p = plan('SELECT ' .. case[2] .. ' FROM ' .. case[1])
    eq(p.route, 'derived'); eq(p.source.table, case[3]); eq(p.columns, { case[4] })
    eq(p.slots[1].kind, 'direct'); eq(p.slots[1].column, case[4])
    assert(read.derived_sql(p):find('raw.`' .. case[4]:gsub('`', '``') .. '`', 1, true))
  end)
end
for _, sql in ipairs({ "SELECT tick() AS same,id AS same FROM tasks", "SELECT id,ID FROM tasks",
  "SELECT ROW_COUNT() AS same,1 AS same" }) do
  test("explicit duplicate labels are refused before any route: " .. sql, function()
    local p, err = read.plan(sql); eq(p, nil); assert(err:find("duplicate", 1, true), err)
  end)
end
for _, sql in ipairs({ "SELECT 1; SELECT 2", "SELECT 1 INTO @v", "SELECT id FROM tasks FOR UPDATE",
  "SELECT /*! 1 */ 1", "SELECT /*+ \\d // */ 1", "SELECT 'unterminated", "SELECT 1\\g" }) do
  test("command boundaries cannot be bypassed through legacy routing: " .. sql, function()
    local p, err = read.plan(sql); eq(p, nil); assert(type(err) == "string" and err ~= "")
  end)
end
for _, sql in ipairs({ "SELECT COUNT(*) FROM tasks", "SELECT ROW_COUNT()", "SELECT FOUND_ROWS() AS n",
  "SELECT @@warning_count AS n" }) do
  test("safe single scalar unsupported shape is preclassified legacy: " .. sql, function()
    eq(plan(sql).route, "legacy")
  end)
end
test("multiple unproved headers use native legacy headers without guessing", function()
  local p = plan("SELECT COUNT(*),COUNT(*) FROM tasks")
  eq(p.route, "legacy"); eq(p.columns, nil)
end)
for _, sql in ipairs({ "WITH x AS (SELECT 1 AS id) SELECT * FROM x",
  "WITH RECURSIVE x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x WHERE n<3) SELECT * FROM x",
  "SELECT 1 AS n UNION ALL SELECT 2", "(SELECT 1 AS n) UNION ALL (SELECT 2)",
  "SELECT a.*,b.* FROM a JOIN b ON a.id=b.id" }) do
  test("safe single read preserves access through preclassified legacy: " .. sql, function()
    eq(plan(sql).route, "legacy")
  end)
end
for _, sql in ipairs({ "WITH x AS (SELECT 1) UPDATE tasks SET id=2",
  "WITH x AS (SELECT 1) DELETE FROM tasks", "WITH x AS (SELECT 1) INSERT INTO tasks VALUES(2)",
  "WITH x AS (DELETE FROM tasks) SELECT * FROM x", "WITH x AS (SELECT 1) SELECT 1; UPDATE tasks SET id=2" }) do
  test("WITH cannot bypass final read/batch boundaries: " .. sql, function()
    local p, err = read.plan(sql); eq(p, nil); assert(type(err) == "string" and err ~= "")
  end)
end
test("explicit duplicate final labels still fail before CTE legacy route", function()
  local p, err = read.plan("WITH x AS (SELECT 1 AS id) SELECT id AS same,id AS same FROM x")
  eq(p, nil); assert(err:find("duplicate", 1, true), err)
end)
for _, sql in ipairs({ "SHOW TABLES; SELECT 1", "DESCRIBE tasks; SELECT 1", "EXPLAIN SELECT 1; SELECT 2",
  "PRAGMA table_info(tasks); SELECT 1", "SHOW TABLES\n\\! echo unsafe", "CREATE TABLE t(id INT);\n\\! echo unsafe",
  "CREATE TABLE t(id INT);\nsource /tmp/unsafe.sql", "SET @x=1;\n\\. /tmp/unsafe.sql",
  "CREATE TABLE t(id INT);\nconnect other", "DELIMITER \\!" }) do
  test("whole-input client/batch guard applies to read-like and custom seams: " .. sql, function()
    local p, err = read.plan(sql); eq(p, nil); assert(type(err) == "string" and err ~= "")
  end)
end
for _, sql in ipairs({ "CREATE TABLE t(id INT); /* comment */ source /tmp/unsafe.sql",
  "CREATE TABLE t(id INT);\n/* comment */ connect other",
  "DELIMITER //\nCREATE FUNCTION t() RETURNS INT RETURN 1// source /tmp/unsafe.sql\nDELIMITER ;" }) do
  test("comments/custom delimiters do not hide a new client command", function()
    local p, err = read.plan(sql); eq(p, nil); assert(type(err) == "string" and err ~= "")
  end)
end
for _, sql in ipairs({ "SHOW TABLES", "SHOW CREATE TABLE tasks", "DESCRIBE tasks", "EXPLAIN SELECT 1", "PRAGMA table_info(tasks)" }) do
  test("read-like commands remain validated legacy reads: " .. sql, function()
    eq(plan(sql).route, "legacy")
  end)
end
for _, sql in ipairs({ "SET @x=1; SELECT @x;", "CREATE TABLE t(id INT); INSERT INTO t VALUES(1);",
  "DELIMITER //\nCREATE FUNCTION t() RETURNS INT BEGIN RETURN 1; END//\nDELIMITER ;" }) do
  test("intentional custom/routine batch stays a distinct invocation seam", function()
    eq(plan(sql).route, "custom")
  end)
end
test("wildcard stays unresolved until an exact visible ordinal descriptor is supplied", function()
  local p = plan("SELECT * FROM tasks ORDER BY id")
  eq(p.needs_schema, true); eq(p.columns, nil)
  local resolved, err = read.resolve_plan(p)
  eq(resolved, nil); assert(err:find("metadata", 1, true), err)
end)
local descriptor = {
  columns = {
    { column_name = "id", ordinal = 1, visible = true, data_type = "int", kind = "number" },
    { column_name = "hidden", ordinal = 2, visible = false, data_type = "text", kind = "text" },
    { column_name = "payload", ordinal = 3, visible = true, data_type = "blob", kind = "blob" },
  },
  source_schema_proof = { version = 1, source_identity = { instance = "fixture", schema = "sample", table = "tasks" },
    binding = "metadata_only", restorable = false, editable = false },
}
test("wildcard uses visible columns only while retaining complete metadata", function()
  local p = assert(read.resolve_plan(plan("SELECT * FROM tasks"), descriptor))
  eq(p.columns, { "id", "payload" }); eq(#p.source_schema_proof.columns, 3)
  eq(p.readonly, true)
end)
test("wildcard expansion rejects unknown visibility instead of assuming visible", function()
  local d = vim.deepcopy(descriptor); d.columns[2].visible = nil
  local p, err = read.resolve_plan(plan("SELECT * FROM tasks"), d)
  eq(p, nil); assert(err:find("visibility", 1, true), err)
end)
test("expanded duplicates fail before original even when static wildcard count was unknown", function()
  local p, err = read.resolve_plan(plan("SELECT *,id FROM tasks"), descriptor)
  eq(p, nil); assert(err:find("duplicate", 1, true), err)
end)
test("metadata-only descriptors never upgrade binary charset to a physical kind", function()
  local p = assert(read.resolve_plan(plan("SELECT id,payload FROM tasks"), descriptor))
  eq(p.column_info[1].kind, "raw_unknown"); eq(p.column_info[2].kind, "raw_unknown")
  eq(p.column_info[1].restorable, false); eq(p.readonly, true)
end)
test("plain transaction_mdl flags cannot impersonate an admitted source binding", function()
  local d = vim.deepcopy(descriptor)
  d.source_schema_proof.binding, d.source_schema_proof.restorable, d.source_schema_proof.editable = "transaction_mdl", true, true
  local p = assert(read.resolve_plan(plan("SELECT id,payload FROM tasks"), d))
  eq(p.readonly, true); eq(p.column_info[1].kind, "raw_unknown"); eq(p.column_info[2].restorable, false)
end)
for _, keyword in ipairs({ "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "NULL", "CURRENT_USER",
  "CURRENT_ROLE", "LOCALTIME", "LOCALTIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "TRUE", "FALSE" }) do
  test("bare value keyword cannot acquire same-named source admission: " .. keyword, function()
    local p = plan("SELECT " .. keyword .. " AS value FROM tasks")
    eq(p.slots[1].kind, "computed")
    local resolved = assert(read.resolve_plan(p, descriptor))
    eq(resolved.source_columns, { false }); eq(resolved.column_info[1].restorable, false)
    local bare = plan("SELECT " .. keyword .. " FROM tasks")
    eq(bare.route, "legacy")
    local quoted = plan("SELECT `" .. keyword .. "` FROM tasks")
    eq(quoted.slots[1].kind, "direct"); eq(quoted.slots[1].column, keyword)
  end)
end
test("qualified keyword names remain genuine source columns", function()
  local p = plan("SELECT tasks.TRUE FROM tasks")
  eq(p.slots[1].kind, "direct"); eq(p.slots[1].column, "TRUE")
end)
test("computed sources remain positional false even with bound table metadata", function()
  local d = vim.deepcopy(descriptor)
  d.source_schema_proof.binding, d.source_schema_proof.restorable, d.source_schema_proof.editable = "transaction_mdl", true, true
  local p = assert(read.resolve_plan(plan("SELECT id,tick() AS value FROM tasks"), d))
  eq(p.source_columns[2], false); eq(p.readonly, true)
  eq(p.column_info[2].restorable, false)
end)
test("raw binary-charset bytes stay raw_unknown absent physical proof", function()
  local p = assert(read.resolve_plan(plan("SELECT tick() AS value")))
  local r = read.decode_derived({ "X00FF41", "0" }, p)
  eq(r.rows, { { "\0\255A" } }); eq(r.cell_types, { { "raw_unknown" } })
  eq(r.byte_exact, true); eq(r.readonly, true); eq(r.lossless, false)
end)
test("NULL does not upgrade an unproved column, including empty results", function()
  local p = assert(read.resolve_plan(plan("SELECT tick() AS value")))
  local r = read.decode_derived({ "N", "0" }, p)
  eq(r.rows[1][1], vim.NIL); eq(r.column_info[1].restorable, false)
  eq(read.decode_derived({ "0" }, p).column_info[1].kind, "raw_unknown")
end)
test("unproved text proves UTF8 encoding only, never physical restoration", function()
  local p = assert(read.resolve_plan(plan("SELECT 'é' AS value")))
  local r = read.decode_derived({ "TC3A9", "0" }, p)
  eq(r.rows[1][1], "é"); eq(r.readonly, true); eq(r.column_info[1].restorable, false)
  eq(r.column_info[1].kind, "raw_unknown"); eq(r.cell_types[1][1], "raw_unknown")
  eq(r.column_info[1].encoding_proven, true)
  assert(require("dadbod-grip.provenance").export_error(r, "json"))
  assert(require("dadbod-grip.provenance").export_error(r, "sql"))
end)
test("inconsistent column encoding cannot upgrade unknown bytes with a later text tag", function()
  local p = assert(read.resolve_plan(plan("SELECT tick() AS value")))
  assert(not pcall(read.decode_derived, { "XFF", "TC3A9", "0" }, p))
end)
print(string.format("mysql_derived_plan_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
