-- Native SQL/client positive controls. No account, grant, or global changes.
-- Only an explicitly assigned disposable review database may be used.
local urls = { vim.env.GRIP_SAFETY_MYSQL_URL, vim.env.GRIP_SAFETY_MARIA_URL }
if not urls[1] and not urls[2] then
  print("safety_adversarial_mysql_read_live_spec: SKIP (assigned review fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, adapters = require("dadbod-grip.db"), require("dadbod-grip.adapters")
local mysql, sql = require("dadbod-grip.adapters.mysql"), require("dadbod-grip.sql")
local counter, source, func, mixed = "grip_review_read_counter", "grip_review_read_source",
  "grip_review_read_value", "grip_review_read_mixed"
local function raw(url, statement)
  local parsed = assert(sql.parse_dadbod_url(url))
  assert(parsed.dbname == "grip_safety_review", "refuse any unassigned database")
  local out, err, code = adapters.run_cmd(mysql._mysql_args(parsed), 10000,
    { stdin = mysql._mysql_stdin(statement, {}), env = mysql._mysql_env(parsed), raw_output = true })
  assert(code == 0, err)
  return out
end
local function unhex(text)
  assert(text:match("^%x*$") and #text % 2 == 0)
  return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end
for i, url in ipairs(urls) do
  local flavor = i == 1 and "mysql" or "mariadb"
  local function test(id, fn)
    H.test(flavor .. " " .. id, function(c)
      c.url = url
      local function cleanup()
        raw(url, "DROP FUNCTION IF EXISTS " .. func .. ";DROP TABLE IF EXISTS " .. counter .. "," .. source .. "," .. mixed .. ";")
      end
      cleanup()
      local ok, err = xpcall(function() fn(c) end, debug.traceback)
      cleanup()
      if not ok then error(err) end
    end)
  end
  local function seed_counter()
    raw(url, "CREATE TABLE " .. counter .. "(n BIGINT); INSERT INTO " .. counter .. " VALUES(0);"
      .. "CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY); INSERT INTO " .. source .. " VALUES(1),(2),(3);\n"
      .. "DELIMITER //\nCREATE FUNCTION " .. func .. "() RETURNS BIGINT DETERMINISTIC MODIFIES SQL DATA\n"
      .. "BEGIN UPDATE " .. counter .. " SET n=n+1; RETURN (SELECT n FROM " .. counter .. "); END//\nDELIMITER ;\n")
  end
  test("T02 original volatile projection runs exactly once per result row", function(c)
    seed_counter()
    local result, err = db.query("SELECT " .. func .. "() AS value FROM " .. source .. " ORDER BY id", url)
    assert(result, err)
    H.eq(result.rows, { { "1" }, { "2" }, { "3" } })
    H.eq(c.scalar("SELECT n FROM " .. counter), "3", "metadata or encoding re-evaluated the original read")
  end)
  test("T03 duplicate labels fail before original evaluation", function(c)
    seed_counter()
    local result, err = db.query("SELECT " .. func .. "() AS same, id AS same FROM " .. source, url)
    H.eq(result, nil, "ambiguous labels must not become editable positional guesses")
    assert(type(err) == "string" and err ~= "", "duplicate-label failure must be explicit")
    H.eq(c.scalar("SELECT n FROM " .. counter), "0", "duplicate-label metadata probe evaluated original read")
  end)
  test("T04 mixed text charsets JSON binary NUL and numeric spelling", function(c)
    raw(url, "CREATE TABLE " .. mixed .. "(id INTEGER PRIMARY KEY, latin VARCHAR(32) CHARACTER SET latin1,"
      .. "unicode_text VARCHAR(32) CHARACTER SET utf8mb4, native_json JSON, binary_value BLOB,"
      .. "nul_text TEXT CHARACTER SET utf8mb4, exact_decimal DECIMAL(65,30), exact_integer BIGINT UNSIGNED);"
      .. "INSERT INTO " .. mixed .. " VALUES(1,CONVERT(X'636166E9' USING latin1),CONVERT(X'F09F9982' USING utf8mb4),"
      .. "CONVERT(X'7B2273223A22C3A9222C226E223A393030373139393235343734303939337D' USING utf8mb4),X'0041FF5CE9',CONCAT('a',CHAR(0),'b'),"
      .. "12345678901234567890123456789012345.123456789012345678901234567890,18446744073709551615);")
    local oracle = c.rows("SELECT HEX(CONVERT(latin USING utf8mb4)),HEX(CONVERT(unicode_text USING utf8mb4)),"
      .. "HEX(CAST(native_json AS CHAR CHARACTER SET utf8mb4)),HEX(binary_value),HEX(nul_text),"
      .. "CAST(exact_decimal AS CHAR),CAST(exact_integer AS CHAR) FROM " .. mixed)[1]
    local result, err = db.query("SELECT latin,unicode_text,native_json,binary_value,nul_text,exact_decimal,exact_integer FROM " .. mixed, url)
    assert(result, err)
    H.eq(result.rows[1], { unhex(oracle[1]), unhex(oracle[2]), unhex(oracle[3]), unhex(oracle[4]),
      unhex(oracle[5]), oracle[6], oracle[7] }, "compare against server bytes/strings, not JSON number decoding")
    H.eq(result.rows[1][1], "café")
    H.eq(result.rows[1][2], "🙂")
    H.eq(result.rows[1][4], "\0A\255\\\233")
    H.eq(result.rows[1][5], "a\0b")
    H.eq(result.rows[1][7], "18446744073709551615")
    local _, session = c.open(mixed)
    H.eq(require("dadbod-grip.data").effective_value(session.state, 1, "latin"), "café")
    H.eq(require("dadbod-grip.data").effective_value(session.state, 1, "binary_value"), "\0A\255\\\233")
  end)
  test("T05 read-only transport reads exact values and grid denies writes", function(c)
    raw(url, "CREATE TABLE " .. mixed .. "(id INTEGER PRIMARY KEY,payload TEXT);"
      .. "INSERT INTO " .. mixed .. " VALUES(1,CONCAT('a',CHAR(0),'b'));")
    vim.fn.writefile({ vim.json.encode({ { name = "review-ro", url = url, mode = "ro" } }) },
      c.root .. "/project/.grip/connections.json")
    local result, err = db.query("SELECT payload FROM " .. mixed, url)
    assert(result, err)
    H.eq(result.rows, { { "a\0b" } })
    local buf, session = c.open(mixed)
    H.eq(session.state.readonly, true)
    c.edit(buf, session, 1, "payload", "must-not-commit")
    c.action("grid_apply")
    H.eq(c.scalar("SELECT HEX(payload) FROM " .. mixed), "610062", "RO fixture must retain original server bytes")
  end)
end
H.finish("safety_adversarial_mysql_read_live_spec")
