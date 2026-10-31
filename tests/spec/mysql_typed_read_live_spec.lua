-- Typed read acceptance uses only the explicitly assigned synthetic database.
local url = vim.env.GRIP_TEST_MYSQL_URL
if not url or url == "" then
  print("SKIP: mysql_typed_read_live_spec (GRIP_TEST_MYSQL_URL not set)")
  print("mysql_typed_read_live_spec: 0 passed, 0 failed (skipped)")
  return
end
local mysql = require("dadbod-grip.adapters.mysql")
local adapters = require("dadbod-grip.adapters")
local pass, fail = 0, 0
local table_name = "grip_typed_read_" .. vim.uv.os_getpid()
local counter_table, counter_function = table_name .. "_counter", table_name .. "_tick"
local readonly_function = table_name .. "_readonly"
local ordinary, ambiguous = table_name .. "_ordinary", table_name .. "_ambiguous"
local collision, fixed_token = table_name .. "_collision", "0123456789abcdef"
local function query(sql)
  local result, err = mysql.query(sql, url)
  assert(result, err)
  return result
end
local function eq(a, b)
  assert(a == b, "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local setup, setup_error = pcall(function()
  query("CREATE TABLE " .. table_name .. " (id INT PRIMARY KEY, "
    .. "v TEXT CHARACTER SET utf8mb4, latin VARCHAR(20) CHARACTER SET latin1, "
    .. "b BLOB, j JSON, n DECIMAL(65,30), big BIGINT UNSIGNED)")
  query("INSERT INTO " .. table_name .. " VALUES "
    .. "(1,CONCAT('a',CHAR(0),'b'),'é',X'00FF41','{\"z\":12345678901234567890,\"a\":1.2300}',"
    .. "12345678901234567890123456789012345.123456789012345678901234567890,18446744073709551615),"
    .. "(2,'','café',X'','\"0x4142\"',0,0),"
    .. "(3,'NULL',NULL,NULL,'null',NULL,NULL),"
    .. "(4,'0x4142',NULL,NULL,NULL,NULL,NULL),"
    .. "(5,NULL,NULL,NULL,NULL,NULL,NULL)")
  query("CREATE TABLE " .. counter_table .. "(n INT); INSERT INTO " .. counter_table .. " VALUES(0)")
  -- Fixture declaration permits creation under the existing binary-log policy;
  -- the body deliberately records every invocation in the task-owned counter.
  query("DELIMITER //\nCREATE FUNCTION " .. counter_function .. "() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN "
    .. "UPDATE " .. counter_table .. " SET n=n+1; RETURN (SELECT n FROM " .. counter_table .. "); END//\nDELIMITER ;")
  local readonly_variable = "transaction_read_only"
  if #query("SHOW VARIABLES LIKE 'transaction_read_only'").rows == 0 then
    readonly_variable = "tx_read_only"
    assert(#query("SHOW VARIABLES LIKE 'tx_read_only'").rows == 1, "native RO status variable unavailable")
  end
  query("CREATE FUNCTION " .. readonly_function .. "() RETURNS INT DETERMINISTIC READS SQL DATA RETURN @@session." .. readonly_variable)
  query("CREATE TABLE " .. ordinary .. "(id INT,e ENUM('new','done'),s SET('read','write')); "
    .. "INSERT INTO " .. ordinary .. " VALUES(1,'new','read'),(2,'done',''),(3,'new','read,write'),(4,NULL,NULL)")
  -- Intentional invalid ENUM-zero fixture; exact fixed session is nonstrict.
  query("INSERT INTO " .. ordinary .. " VALUES(5,0,0)")
  query("CREATE TABLE " .. ambiguous .. "(e ENUM('','a'),s SET('','a')); INSERT INTO " .. ambiguous .. " VALUES(1,1)")
  query("CREATE TABLE " .. collision .. "(`__grip_read_" .. fixed_token .. "_ord` INT); INSERT INTO " .. collision .. " VALUES(99)")

  test("stored TEXT NUL, empty, literal NULL/hex, and SQL NULL stay distinct", function()
    local r = query("SELECT id,v FROM " .. table_name .. " ORDER BY id")
    eq(r.rows[1][2], "a\0b"); eq(r.rows[2][2], ""); eq(r.rows[3][2], "NULL")
    eq(r.rows[4][2], "0x4142"); eq(r.rows[5][2], vim.NIL)
    eq(r.cell_types[1][2], "text"); eq(r.cell_types[5][2], "null")
    eq(r.storage_adapter, "mysql")
  end)
  test("mixed source character sets return actual UTF8 text", function()
    local r = query("SELECT latin, v FROM " .. table_name .. " WHERE id=1")
    eq(r.rows[1][1], "é"); eq(r.cell_types[1][1], "text")
    eq(r.column_info[1].character_set, "latin1")
    eq(r.column_info[2].character_set, "utf8mb4")
  end)
  test("binary bytes have exact blob receipts, including an empty BLOB", function()
    local r = query("SELECT b FROM " .. table_name .. " ORDER BY id LIMIT 2")
    eq(r.rows[1][1], "\0\255A"); eq(r.rows[2][1], "")
    eq(r.cell_types[1][1], "blob"); eq(r.cell_types[2][1], "blob")
  end)
  test("native JSON server spelling is preserved without Lua decoding", function()
    local expected = query("SELECT HEX(j) AS h FROM " .. table_name .. " ORDER BY id LIMIT 3")
    local actual = query("SELECT j FROM " .. table_name .. " ORDER BY id LIMIT 3")
    for i = 1, 3 do
      eq(require("dadbod-grip.transport").hex(actual.rows[i][1]), expected.rows[i][1])
      eq(actual.cell_types[i][1], "text")
    end
  end)
  test("maximum precision DECIMAL and unsigned BIGINT remain strings", function()
    local r = query("SELECT n,big FROM " .. table_name .. " WHERE id=1")
    eq(r.rows[1][1], "12345678901234567890123456789012345.123456789012345678901234567890")
    eq(r.rows[1][2], "18446744073709551615")
    eq(type(r.rows[1][1]), "string"); eq(r.cell_types[1][1], "number")
  end)
  test("explicit ORDER and LIMIT survive the single original derived read", function()
    local r = query("SELECT id FROM " .. table_name .. " ORDER BY id DESC LIMIT 3 OFFSET 1")
    eq(#r.rows, 3); eq(r.rows[1][1], "4"); eq(r.rows[2][1], "3"); eq(r.rows[3][1], "2")
  end)
  test("DISTINCT semantics retain the original projection", function()
    local r = query("SELECT DISTINCT v FROM " .. table_name .. " WHERE id IN (2,3) ORDER BY v")
    eq(#r.rows, 2); eq(r.rows[1][1], ""); eq(r.rows[2][1], "NULL")
  end)
  test("volatile projection is evaluated once in the native session", function()
    local r = query("SELECT " .. counter_function .. "() AS seen FROM " .. table_name .. " ORDER BY id")
    eq(#r.rows, 5); eq(r.rows[1][1], "1"); eq(r.rows[5][1], "5")
    eq(query("SELECT n FROM " .. counter_table).rows[1][1], "5")
  end)
  test("successful VIEW capability preserves one native read without physical upgrades", function()
    query("UPDATE " .. counter_table .. " SET n=0")
    local view = table_name .. "_view"
    query("CREATE VIEW " .. view .. " AS SELECT " .. counter_function .. "() AS value FROM " .. table_name)
    local ok, result = pcall(query, "SELECT value FROM " .. view)
    local dropped, drop_error = mysql.query("DROP VIEW " .. view, url)
    assert(dropped, drop_error); assert(ok, result)
    eq(#result.rows, 5); eq(query("SELECT n FROM " .. counter_table).rows[1][1], "5")
    eq(result.cell_types[1][1], "raw_unknown"); eq(result.readonly, true)
    eq(result.lossless, false); eq(result.restorable, false)
  end)
  test("duplicate output labels fail instead of conflating row identities", function()
    query("UPDATE " .. counter_table .. " SET n=0")
    local r, err = mysql.query("SELECT " .. counter_function .. "() AS duplicate_name,2 AS duplicate_name", url)
    eq(r, nil); assert(type(err) == "string" and err ~= "", tostring(err))
    eq(query("SELECT n FROM " .. counter_table).rows[1][1], "0")
    local plain, duplicate_error = mysql.query("SELECT 1 AS duplicate_name,2 AS duplicate_name", url)
    eq(plain, nil); assert(duplicate_error:find("duplicate", 1, true), duplicate_error)
  end)
  test("empty results retain positional typed column metadata", function()
    local r = query("SELECT id,v,b FROM " .. table_name .. " WHERE id=999")
    eq(#r.rows, 0); eq(#r.columns, 3); eq(r.columns[2], "v")
    eq(r.column_info[3].binary, true)
  end)
  test("read-only transport returns exact bytes and preserves actual session enforcement", function()
    local previous = adapters.set_call_readonly(true)
    local ok, result, err = pcall(mysql.query, "SELECT v," .. readonly_function .. "() AS ro_mode FROM " .. table_name .. " WHERE id=1", url)
    adapters.set_call_readonly(previous)
    assert(ok, result); assert(result, err)
    eq(result.rows[1][1], "a\0b"); eq(result.rows[1][2], "1")
  end)
  test("unclassified SHOW keeps one-execution custom read-only result semantics", function()
    local r = query("SHOW FULL COLUMNS FROM " .. table_name)
    eq(r.readonly, true); eq(r.lossless, false)
  end)
  test("ordinary ENUM/SET display text matches the original server HEX oracle", function()
    local expected = query("SELECT HEX(e) AS e,HEX(s) AS s FROM " .. ordinary .. " ORDER BY id")
    local actual = query("SELECT e,s FROM " .. ordinary .. " ORDER BY id")
    for ri, row in ipairs(actual.rows) do
      for ci, value in ipairs(row) do
        if value == vim.NIL then eq(expected.rows[ri][ci], vim.NIL)
        else eq(require("dadbod-grip.transport").hex(value), expected.rows[ri][ci]) end
      end
    end
    eq(actual.rows[2][2], ""); eq(actual.rows[3][2], "read,write")
    eq(actual.rows[5][1], ""); eq(actual.rows[5][2], "")
  end)
  test("ambiguous ENUM/SET definitions are withheld without a lossy fallback", function()
    local result, err = mysql.query("SELECT e,s FROM " .. ambiguous, url)
    eq(result, nil); assert(err:find("definition", 1, true) and err:find("result withheld", 1, true), err)
  end)
  test("old private-ordinal-shaped aliases remain ordinary unique labels", function()
    local r = query("SELECT 1 AS `__grip_read_" .. fixed_token .. "_ord`")
    eq(r.columns[1], "__grip_read_" .. fixed_token .. "_ord"); eq(r.rows[1][1], "1")
  end)
  test("fixed tokens add no ordinal and cannot collide with real source columns", function()
    local read = require("dadbod-grip.mysql_read")
    local previous = read._token
    read._token = function() return fixed_token end
    local ok, result, err = pcall(mysql.query, "SELECT q.*, " .. counter_function .. "() AS tick FROM " .. collision .. " q", url)
    local plain_ok, plain, plain_error = pcall(mysql.query, "SELECT q.* FROM " .. collision .. " q", url)
    read._token = previous
    assert(ok, result); assert(result, err); eq(result.rows[1][1], "99"); eq(result.rows[1][2], "1")
    assert(plain_ok, plain); assert(plain, plain_error); eq(plain.rows[1][1], "99")
    eq(query("SELECT n FROM " .. counter_table).rows[1][1], "1")
  end)
  test("expanded duplicates are refused before any original side effect", function()
    query("UPDATE " .. counter_table .. " SET n=0")
    local result, err = mysql.query("SELECT q.*, q.id, " .. counter_function .. "() AS tick FROM " .. table_name .. " q", url)
    eq(result, nil); assert(err:find("duplicate", 1, true), err)
    eq(query("SELECT n FROM " .. counter_table).rows[1][1], "0")
  end)
  for index, names in ipairs({
    { "table with spaces", "quoted column" }, { "δοκιμή", "имя" },
    { "literal.table", "literal.column" }, { "table`name", "column`name" },
    { 'table"name', 'column"name' },
  }) do
    test("quoted source/header names preserve writable direct metadata: " .. index, function()
      local function quote(value) return "`" .. value:gsub("`", "``") .. "`" end
      local name = quote(table_name .. "_" .. names[1])
      local field = quote(names[2])
      query("CREATE TABLE " .. name .. "(" .. field .. " TEXT); INSERT INTO " .. name .. " VALUES(CONCAT('a',CHAR(0),'b'))")
      local ok, result = pcall(query, "SELECT " .. field .. " FROM " .. name)
      local dropped, drop_error = mysql.query("DROP TABLE " .. name, url)
      assert(dropped, drop_error); assert(ok, result)
      eq(result.columns[1], names[2]); eq(result.rows[1][1], "a\0b")
      eq(result.cell_types[1][1], "text"); eq(result.restorable, true); eq(result.readonly, false)
    end)
  end
end)
local cleanup, cleanup_error = mysql.query("DROP TABLE IF EXISTS " .. table_name, url)
local cleanup_counter, counter_error = mysql.query("DROP FUNCTION IF EXISTS " .. counter_function
  .. "; DROP FUNCTION IF EXISTS " .. readonly_function
  .. "; DROP TABLE IF EXISTS " .. counter_table .. "," .. ordinary .. "," .. ambiguous .. "," .. collision, url)
if not setup then fail = fail + 1; print("FAIL: fixture setup: " .. tostring(setup_error)) end
if not cleanup then fail = fail + 1; print("FAIL: fixture cleanup: " .. tostring(cleanup_error)) end
if not cleanup_counter then fail = fail + 1; print("FAIL: counter cleanup: " .. tostring(counter_error)) end
print(string.format("mysql_typed_read_live_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
