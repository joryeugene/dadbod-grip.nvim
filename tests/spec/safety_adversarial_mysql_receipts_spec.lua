-- Direct transaction controls: synthesize typed input ONLY from native server
-- HEX output. This isolates receipts/guards from the pending read helper;
-- passing here does not prove end-to-end grid fetching or RO read support.
if not vim.env.GRIP_SAFETY_MYSQL_URL and not vim.env.GRIP_SAFETY_MARIA_URL then
  print("safety_adversarial_mysql_receipts_spec: SKIP (assigned review fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, data, transaction = require("dadbod-grip.db"), require("dadbod-grip.data"), require("dadbod-grip.transaction")
local function unhex(text)
  assert(text:match("^%x*$") and #text % 2 == 0)
  return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end
for _, key in ipairs({ "GRIP_SAFETY_MYSQL_URL", "GRIP_SAFETY_MARIA_URL" }) do
  local url = vim.env[key]
  if url then
    local parsed = assert(require("dadbod-grip.sql").parse_dadbod_url(url))
    assert(parsed.dbname == "grip_safety_review", "refuse any unassigned fixture database")
    local name = "grip_review_receipts"
    local columns = { "id", "note", "latin", "unicode_text", "native_json", "bytes", "nul_text", "precise", "large", "bits" }
    local oracle = "SELECT HEX(CAST(id AS CHAR)),HEX(CONVERT(note USING utf8mb4)),HEX(CONVERT(latin USING utf8mb4)),"
      .. "HEX(CONVERT(unicode_text USING utf8mb4)),HEX(CAST(native_json AS CHAR CHARACTER SET utf8mb4)),HEX(bytes),"
      .. "HEX(nul_text),HEX(CAST(precise AS CHAR)),HEX(CAST(large AS CHAR)),HEX(bits) FROM " .. name .. " ORDER BY id"
    local function test(id, fn)
      H.test(key .. " " .. id, function(c)
        c.url = url
        c.exec("DROP TABLE IF EXISTS " .. name)
        c.exec("CREATE TABLE " .. name .. "(id INTEGER AUTO_INCREMENT PRIMARY KEY,note TEXT CHARACTER SET utf8mb4,"
          .. "latin VARCHAR(32) CHARACTER SET latin1,unicode_text VARCHAR(32) CHARACTER SET utf8mb4,native_json JSON,"
          .. "bytes BLOB,nul_text TEXT CHARACTER SET utf8mb4,precise DECIMAL(65,30),large BIGINT UNSIGNED,bits BIT(8));"
          .. "INSERT INTO " .. name .. " VALUES(1,'before',CONVERT(X'636166E9' USING latin1),"
          .. "CONVERT(X'F09F9982' USING utf8mb4),CONVERT(X'7B2278223A22F09F9982227D' USING utf8mb4),"
          .. "X'0041FF5CE9',CONCAT('a',CHAR(0),'b'),"
          .. "12345678901234567890123456789012345.123456789012345678901234567890,18446744073709551615,b'10100101')")
        local before = c.rows(oracle)
        local values = {}
        for i, hex in ipairs(before[1]) do values[i] = unhex(hex) end
        local state = data.new({ table_name = name, primary_keys = { "id" }, columns = columns, rows = { values },
          cell_types = { { "number", "text", "text", "text", "text", "blob", "text", "number", "number", "blob" } },
          storage_adapter = "mysql", url = url })
        local function write(changed)
          local info, err = db.get_column_info(name, url)
          assert(info, err)
          local plan, why = transaction.plan(changed, info)
          assert(plan, why)
          local result, failure = db.execute(plan, url)
          assert(result, failure)
          return result
        end
        local ok, err = xpcall(function() fn(c, state, before, write) end, debug.traceback)
        c.exec("DROP TABLE " .. name)
        if not ok then error(err) end
      end)
    end
    test("RCP01 unrelated UPDATE Undo preserves exact native receipts", function(c, state, before, write)
      local result = write(data.add_change(state, 1, "note", "ours"))
      local reverted, err = db.execute(result.undo, url)
      assert(reverted, err)
      H.eq(c.rows(oracle), before)
    end)
    test("RCP02 DELETE Undo restores mixed charset binary numeric JSON and NUL", function(c, state, before, write)
      local result = write(data.toggle_delete(state, 1))
      H.eq(c.scalar("SELECT count(*) FROM " .. name), "0")
      local reverted, err = db.execute(result.undo, url)
      assert(reverted, err)
      H.eq(c.rows(oracle), before)
    end)
    test("RCP03 typed clone preserves values and Undo excludes concurrent row", function(c, state, before, write)
      local result = write(data.clone_row(state, 1))
      local rows = c.rows(oracle)
      H.eq(#rows, 2)
      local expected = vim.deepcopy(before[1]); expected[1] = "32"
      H.eq(rows[2], expected)
      c.exec("INSERT INTO " .. name .. "(id,note) VALUES(42,'concurrent')")
      local reverted, err = db.execute(result.undo, url)
      assert(reverted, err)
      H.eq(c.rows("SELECT id,note FROM " .. name .. " ORDER BY id"), { { "1", "before" }, { "42", "concurrent" } })
    end)
    test("RCP04 byte-only binary conflict cannot pass snapshot guard", function(c, state, _, write)
      local result = write(data.add_change(state, 1, "note", "ours"))
      c.exec("UPDATE " .. name .. " SET bytes=X'0041FE5CE9' WHERE id=1")
      local expected = c.rows(oracle)
      local reverted, err = db.execute(result.undo, url)
      H.eq(reverted, nil)
      assert(err and err ~= "")
      H.eq(c.rows(oracle), expected)
    end)
  end
end
H.finish("safety_adversarial_mysql_receipts_spec")
