-- Forward route acceptance on the assigned fixture. This exercises the new
-- internal implementation directly; default public routing is gated separately.
local url = vim.env.GRIP_DERIVED_TEST_URL
if not url or url == "" then
  print("mysql_derived_live_spec: 0 passed, 0 failed (skipped: GRIP_DERIVED_TEST_URL unavailable)")
  return
end
local read, mysql = require("dadbod-grip.mysql_read"), require("dadbod-grip.adapters.mysql")
local adapters, sql = require("dadbod-grip.adapters"), require("dadbod-grip.sql")
local parsed = assert(sql.parse_dadbod_url(url))
assert(parsed.dbname == "grip_safety_rewrite", "refuse an unassigned live database")
local prefix = "grip_derived_live_" .. vim.uv.os_getpid()
local source, audit, tick = prefix .. "_source", prefix .. "_audit", prefix .. "_tick"
local pass, fail = 0, 0
local function eq(a, b) assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a)) end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function custom(statement)
  local result, err = mysql.query(statement, url)
  assert(result, err)
  return result
end
local function query(statement, ro)
  local cfg = { args = mysql._mysql_args(parsed), env = mysql._mysql_env(parsed),
    setup = mysql._mysql_stdin("", { readonly = ro }), timeout = 10000 }
  local result, err = read.derived_query(statement, cfg)
  assert(result, err)
  return result
end
local function scalar(statement) return query(statement).rows[1][1] end
local ok, setup_error = xpcall(function()
  custom("CREATE TABLE " .. source .. "(id INT PRIMARY KEY,v TEXT CHARACTER SET utf8mb4,b BLOB,latin VARCHAR(20) CHARACTER SET latin1);"
    .. "INSERT INTO " .. source .. " VALUES(1,CONCAT('a',CHAR(0),'b'),X'00FF41','é'),(2,'',X'','café'),(3,'NULL',NULL,NULL);")
  custom("CREATE TABLE " .. audit .. "(n INT); INSERT INTO " .. audit .. " VALUES(0);\nDELIMITER //\nCREATE FUNCTION "
    .. tick .. "() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN UPDATE " .. audit
    .. " SET n=n+1; RETURN (SELECT n FROM " .. audit .. "); END//\nDELIMITER ;")
  test("modifying original projection runs once per returned row without CTAS", function()
    local result = query("SELECT " .. tick .. "() AS value FROM " .. source .. " ORDER BY id")
    eq(result.rows, { { "1" }, { "2" }, { "3" } }); eq(scalar("SELECT n FROM " .. audit), "3")
    eq(result.cell_types[1][1], "raw_unknown"); eq(result.readonly, true)
  end)
  test("explicit duplicate labels refuse before original modifying function", function()
    custom("UPDATE " .. audit .. " SET n=0")
    local cfg = { args = mysql._mysql_args(parsed), env = mysql._mysql_env(parsed), setup = mysql._mysql_stdin("", {}), timeout = 10000 }
    local result, err = read.derived_query("SELECT " .. tick .. "() AS same,id AS same FROM " .. source, cfg)
    eq(result, nil); assert(err:find("duplicate", 1, true), err)
    eq(scalar("SELECT n FROM " .. audit), "0")
  end)
  test("enforced read-only returns exact NUL/empty/literal text without TEMP", function()
    local result = query("SELECT v FROM " .. source .. " ORDER BY id", true)
    eq(result.rows, { { "a\0b" }, { "" }, { "NULL" } }); eq(result.byte_exact, true)
  end)
  test("binary-charset output is exact raw_unknown and never guessed BLOB", function()
    local result = query("SELECT b FROM " .. source .. " ORDER BY id", true)
    eq(result.rows, { { "\0\255A" }, { "" }, { vim.NIL } })
    eq(result.cell_types[1][1], "raw_unknown"); eq(result.column_info[1].restorable, false)
  end)
  test("Latin1 converts to UTF8 using actual expression charset", function()
    eq(query("SELECT latin FROM " .. source .. " ORDER BY id", true).rows, { { "é" }, { "café" }, { vim.NIL } })
  end)
  test("ORDER LIMIT and DISTINCT preserve original result sequence", function()
    eq(query("SELECT id FROM " .. source .. " ORDER BY id DESC LIMIT 2 OFFSET 1").rows, { { "2" }, { "1" } })
    eq(query("SELECT DISTINCT v FROM " .. source .. " WHERE id IN (2,3) ORDER BY v").rows, { { "" }, { "NULL" } })
  end)
  test("safe preclassified scalar legacy executes original native session semantics", function()
    local result = query("SELECT ROW_COUNT()")
    eq(result.rows, { { "0" } }); eq(result.readonly, true); eq(result.lossless, false)
  end)
  test("CTE final SELECT preserves read access and one modifying invocation per row", function()
    custom("UPDATE " .. audit .. " SET n=0")
    local result = query("WITH c AS (SELECT id FROM " .. source .. ") SELECT " .. tick .. "() AS n FROM c ORDER BY id")
    eq(result.rows, { { "1" }, { "2" }, { "3" } }); eq(scalar("SELECT n FROM " .. audit), "3")
    eq(result.cell_types[1][1], "raw_unknown"); eq(result.restorable, false); eq(result.byte_exact, false)
  end)
  test("set operation and multiple native output captions stay single legacy reads", function()
    local result = query("SELECT 1 AS n UNION ALL SELECT 2")
    eq(result.columns, { "n" }); eq(result.rows, { { "1" }, { "2" } }); eq(result.lossless, false)
    local aggregate = query("SELECT COUNT(*),SUM(id) FROM " .. source)
    eq(aggregate.columns, { "COUNT(*)", "SUM(id)" }); eq(aggregate.rows, { { "3", "6" } })
    eq(aggregate.cell_types[1], { "raw_unknown", "raw_unknown" })
  end)
  test("ordinal ordering still refers to original columns without added projections", function()
    local result = query("SELECT id,v FROM " .. source .. " ORDER BY 1 DESC LIMIT 2")
    eq(result.rows, { { "3", "NULL" }, { "2", "" } })
  end)
  test("wildcard joins keep actual native duplicate headers as unproven read-only results", function()
    local result = query("SELECT a.*,b.* FROM " .. source .. " a JOIN " .. source .. " b ON a.id=b.id WHERE a.id=2")
    eq(result.columns, { "id", "v", "b", "latin", "id", "v", "b", "latin" })
    eq(#result.rows, 1); eq(result.readonly, true); eq(result.lossless, false)
    for ci = 1, #result.columns do eq(result.column_info[ci].kind, "raw_unknown") end
  end)
end, debug.traceback)
local cleaned, cleanup_error = pcall(custom, "DROP FUNCTION IF EXISTS " .. tick .. "; DROP TABLE IF EXISTS " .. source .. "," .. audit)
if not ok then fail = fail + 1; print("FAIL: setup/runtime: " .. tostring(setup_error)) end
if not cleaned then fail = fail + 1; print("FAIL: cleanup: " .. tostring(cleanup_error)) end
-- No inherited per-call read-only state may escape a fixture.
adapters.set_call_readonly(false)
print(string.format("mysql_derived_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
