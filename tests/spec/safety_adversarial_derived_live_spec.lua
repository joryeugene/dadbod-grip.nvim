-- Gated INTERNAL read-path evidence only. No native MDL/source-binding claim;
-- no stand-in for frozen public T02/T05 or for consumer admission testing.
if not vim.env.GRIP_SAFETY_MYSQL_URL and not vim.env.GRIP_SAFETY_MARIA_URL then
  print("safety_adversarial_derived_live_spec: SKIP (assigned fixtures unavailable)"); return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local read, mysql, adapters = require("dadbod-grip.mysql_read"), require("dadbod-grip.adapters.mysql"), require("dadbod-grip.adapters")
local sql, db = require("dadbod-grip.sql"), require("dadbod-grip.db")
assert(type(read.derived_query) == "function", "gated internal path unavailable")
local source, counter, value_fn, ro_fn = "grip_review_derived_source", "grip_review_derived_counter",
  "grip_review_derived_value", "grip_review_derived_ro"
local function unhex(value) return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)) end
for _, key in ipairs({ "GRIP_SAFETY_MYSQL_URL", "GRIP_SAFETY_MARIA_URL" }) do
  local url = vim.env[key]
  if url then
    local parsed = assert(sql.parse_dadbod_url(url))
    assert(parsed.dbname == "grip_safety_review", "unassigned fixture")
    local function raw(statement)
      local args = mysql._mysql_args(parsed)
      vim.list_extend(args, { "--default-character-set=utf8mb4", "--skip-force", "--skip-reconnect" })
      local out, err, code = adapters.run_cmd(args, 10000,
        { stdin = mysql._mysql_stdin(statement, {}), env = mysql._mysql_env(parsed), raw_output = true })
      assert(code == 0, err)
      return assert(db.parse_batch(out))
    end
    local function internal(statement, ro)
      return read.derived_query(statement, { args = mysql._mysql_args(parsed), env = mysql._mysql_env(parsed),
        setup = mysql._mysql_stdin("", { readonly = ro == true }), timeout = 10000 })
    end
    local function test(id, fn)
      H.test(key .. " " .. id, function(c)
        c.url = url
        local function cleanup()
          raw("DROP FUNCTION IF EXISTS " .. value_fn .. ";DROP FUNCTION IF EXISTS " .. ro_fn
            .. ";DROP TABLE IF EXISTS " .. source .. "," .. counter .. ";")
        end
        cleanup()
        local ok, err = xpcall(fn, debug.traceback)
        cleanup()
        if not ok then error(err) end
      end)
    end
    test("D05 internal original modifying function runs exactly once", function()
      raw("CREATE TABLE " .. counter .. "(n INTEGER);INSERT INTO " .. counter .. " VALUES(0);"
        .. "CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY);INSERT INTO " .. source .. " VALUES(1),(2),(3);\n"
        .. "DELIMITER //\nCREATE FUNCTION " .. value_fn .. "() RETURNS INTEGER DETERMINISTIC MODIFIES SQL DATA "
        .. "BEGIN UPDATE " .. counter .. " SET n=n+1;RETURN (SELECT n FROM " .. counter .. ");END//\nDELIMITER ;\n")
      local original = raw("SELECT " .. value_fn .. "() AS value FROM " .. source .. " ORDER BY id;")
      H.eq(raw("SELECT n FROM " .. counter).rows, { { "3" } })
      raw("UPDATE " .. counter .. " SET n=0;")
      local result, err = internal("SELECT " .. value_fn .. "() AS value FROM " .. source .. " ORDER BY id")
      assert(result, err)
      H.eq(result.columns, original.columns)
      H.eq(result.rows, original.rows)
      H.eq(raw("SELECT n FROM " .. counter).rows, { { "3" } }, "original projection repeated during metadata/codec")
      H.eq(result.readonly, true, "no source admission was provided for computed values")
      H.eq(result.lossless, false, "byte transport is not restoration/provenance evidence")
      H.eq(result.byte_exact, true)
    end)
    test("D06 internal RO exact bytes preserves actual session RO mode", function()
      raw("CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY,payload TEXT CHARACTER SET utf8mb4);"
        .. "INSERT INTO " .. source .. " VALUES(1,CONCAT('a',CHAR(0),'b'));")
      local variable = key == "GRIP_SAFETY_MYSQL_URL" and "@@session.transaction_read_only" or "@@session.tx_read_only"
      raw("CREATE FUNCTION " .. ro_fn .. "() RETURNS INTEGER DETERMINISTIC READS SQL DATA RETURN " .. variable .. ";")
      local result, err = internal("SELECT payload," .. ro_fn .. "() AS ro_mode FROM " .. source .. " ORDER BY id", true)
      assert(result, err)
      H.eq(result.rows, { { "a\0b", "1" } }, "mode weakened or NUL normalized")
      H.eq(result.readonly, true)
      H.eq(result.byte_exact, true)
      H.eq(result.cell_types[1], { "raw_unknown", "raw_unknown" }, "no physical type may be inferred from encoding tag")
    end)
    test("D07 internal mixed-byte/header/order fidelity without physical admission", function()
      raw("CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY,latin VARCHAR(16) CHARACTER SET latin1,"
        .. "bytes BLOB,n BIGINT UNSIGNED);INSERT INTO " .. source
        .. " VALUES(1,CONVERT(X'636166E9' USING latin1),X'0041FF',18446744073709551615),"
        .. "(2,CONVERT(X'E9' USING latin1),X'00FE',9007199254740993);")
      local oracle = raw("SELECT id,HEX(CONVERT(latin USING utf8mb4)),HEX(bytes),CAST(n AS CHAR) FROM " .. source .. " ORDER BY id DESC;")
      local result, err = internal("SELECT ID,latin,bytes,n FROM " .. source .. " ORDER BY id DESC")
      assert(result, err)
      local expected = {}
      for i, row in ipairs(oracle.rows) do expected[i] = { row[1], unhex(row[2]), unhex(row[3]), row[4] } end
      H.eq(result.columns, { "ID", "latin", "bytes", "n" })
      H.eq(result.rows, expected)
      H.eq(result.readonly, true)
      H.eq(result.lossless, false)
      for _, row in ipairs(result.cell_types) do H.eq(row, { "raw_unknown", "raw_unknown", "raw_unknown", "raw_unknown" }) end
    end)
    test("D08 native keyword expression differs from quoted source column", function()
      raw("CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY,`TRUE` INTEGER,`CURRENT_DATE` DATE);"
        .. "INSERT INTO " .. source .. " VALUES(1,7,'2001-01-01');")
      local result = raw("SELECT TRUE AS literal_true,`TRUE` AS source_true,CURRENT_DATE AS literal_date,"
        .. "`CURRENT_DATE` AS source_date FROM " .. source .. ";")
      H.eq(result.rows[1][1], "1")
      H.eq(result.rows[1][2], "7")
      assert(result.rows[1][3] ~= result.rows[1][4], "native current date unexpectedly equals fixed stored fixture")
    end)
  end
end
H.finish("safety_adversarial_derived_live_spec")
