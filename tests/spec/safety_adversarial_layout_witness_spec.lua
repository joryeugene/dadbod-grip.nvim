-- Real assigned SQL effects; metadata filtering/denial is a CONTROLLED MODEL,
-- not a restricted-account or native ACL experiment. No grants/users/options.
local urls = { vim.env.GRIP_SAFETY_MYSQL_URL, vim.env.GRIP_SAFETY_MARIA_URL }
if not urls[1] and not urls[2] then
  print("safety_adversarial_layout_witness_spec: SKIP (assigned review fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, adapters = require("dadbod-grip.db"), require("dadbod-grip.adapters")
local mysql, sql = require("dadbod-grip.adapters.mysql"), require("dadbod-grip.sql")
local source, counter, func = "grip_review_layout_source", "grip_review_layout_counter", "grip_review_layout_value"
local marker = "LAYOUT_ORIGINAL_ONCE_REVIEW"
local function raw(url, statement)
  local parsed = assert(sql.parse_dadbod_url(url))
  assert(parsed.dbname == "grip_safety_review", "refuse any unassigned fixture")
  local out, err, code = adapters.run_cmd(mysql._mysql_args(parsed), 10000,
    { stdin = mysql._mysql_stdin(statement, {}), env = mysql._mysql_env(parsed), raw_output = true })
  assert(code == 0, err)
  return out
end
for i, url in ipairs(urls) do
  local flavor = i == 1 and "mysql" or "mariadb"
  local function test(id, fn)
    H.test(flavor .. " " .. id, function(c)
      c.url = url
      local function cleanup()
        raw(url, "DROP FUNCTION IF EXISTS " .. func .. ";DROP TABLE IF EXISTS " .. source .. "," .. counter .. ";")
      end
      cleanup()
      local ok, err = xpcall(function()
        raw(url, "CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY,payload TEXT CHARACTER SET utf8mb4,"
          .. "hidden TEXT INVISIBLE,g INTEGER GENERATED ALWAYS AS(id+1) STORED) ENGINE=InnoDB;"
          .. "INSERT INTO " .. source .. "(id,payload,hidden) VALUES(1,CONCAT('a',CHAR(0),'b'),'secret'),(2,'','second'),(3,NULL,'third');"
          .. "CREATE TABLE " .. counter .. "(n BIGINT) ENGINE=InnoDB;INSERT INTO " .. counter .. " VALUES(0);\n"
          .. "DELIMITER //\nCREATE FUNCTION " .. func .. "() RETURNS BIGINT DETERMINISTIC MODIFIES SQL DATA\n"
          .. "BEGIN UPDATE " .. counter .. " SET n=n+1; RETURN (SELECT n FROM " .. counter .. "); END//\nDELIMITER ;\n")
        fn(c)
      end, debug.traceback)
      cleanup()
      if not ok then error(err) end
    end)
  end
  local function query(mode, statement)
    local provider = require("dadbod-grip.mysql_source")
    local describe, inspect, complete, system = provider.describe, provider.inspect, provider.complete, vim.system
    local record = { calls = 0, input = {}, completed = {}, admission = 0, pids = {}, witness = 0 }
    local function altered(fetch, after)
      return function(text, phase, receipt)
        if phase == "source layout witness" then
          record.witness = record.witness + 1
          if mode == "pre-deny" and not after or mode == "post-deny" and after then
            return nil, "controlled layout witness denial"
          end
        end
        local lines, err = fetch(text, phase, receipt)
        if lines and mode == "filtered" and phase == "source column metadata" then
          local visible = {}
          for _, line in ipairs(lines) do
            if not line:match("^C|") or line:match("^C|1|") then visible[#visible + 1] = line end
          end
          return visible
        end
        return lines, err
      end
    end
    provider.describe = function(target, identity, fetch) return describe(target, identity, altered(fetch, false)) end
    provider.inspect = function(client, candidate, token)
      local exchange = client.exchange
      local fetch = altered(function(text, phase, receipt) return exchange(text, receipt, phase) end, true)
      client.exchange = function(text, receipt, phase) return fetch(text, phase, receipt) end
      local value, err = inspect(client, candidate, token)
      client.exchange = exchange
      return value, err
    end
    provider.complete = function(...) record.admission = record.admission + 1; return complete(...) end
    vim.system = function(args, opts, callback)
      record.calls = record.calls + 1
      local index = record.calls
      if type(opts.stdin) == "string" then record.input[#record.input + 1] = opts.stdin end
      local process = system(args, opts, function(value)
        record.completed[index] = value.code
        if callback then callback(value) end
      end)
      record.pids[#record.pids + 1] = process.pid
      local proxy = {}
      function proxy:write(value)
        if type(value) == "string" then record.input[#record.input + 1] = value end
        return process:write(value)
      end
      function proxy:wait(...) return process:wait(...) end
      function proxy:kill(...) return process:kill(...) end
      return proxy
    end
    local ok, result, err = pcall(db.query, statement or ("SELECT /* " .. marker .. " */ id," .. func
      .. "() AS seen FROM " .. source .. " ORDER BY id"), url)
    provider.describe, provider.inspect, provider.complete, vim.system = describe, inspect, complete, system
    assert(ok, result)
    for _, pid in ipairs(record.pids) do H.eq(vim.uv.fs_stat("/proc/" .. pid), nil) end
    record.input = table.concat(record.input, "\n")
    for _, option in ipairs({ "sql_quote_show_create", "show_gipk_in_create_table_and_information_schema" }) do
      assert(not record.input:lower():find("set%s+" .. option .. "%s*="), "do not change visibility options")
      assert(not record.input:lower():find("set%s+session%s+" .. option .. "%s*="), "do not change visibility options")
    end
    return result, err, record
  end
  test("LW01 actual SHOW CREATE agrees with full invisible/generated source and byte receipt", function()
    local result, err, seen = query("positive", "SELECT * FROM " .. source .. " ORDER BY id")
    assert(result, err)
    H.eq(result.columns, { "id", "payload", "g" })
    H.eq(result.rows, { { "1", "a\0b", "2" }, { "2", "", "3" }, { "3", vim.NIL, "4" } })
    H.eq(#result.source_schema_proof.columns, 4)
    H.eq(result.source_schema_proof.columns[3].visible, false)
    H.eq(result.source_schema_proof.columns[4].generated, true)
    H.eq(result.restorable, true)
    H.eq(result.editable, true)
    H.eq(type(result.source_schema_proof.receipt), "function")
    H.eq(seen.admission, 1)
    H.eq(seen.calls, 2)
    H.eq(seen.witness, 2)
  end)
  test("LW02 modeled matching filtered I_S prefix preserves one read but never mints completeness", function(c)
    local result, err, seen = query("filtered")
    assert(result, err)
    H.eq(result.rows, { { "1", "1" }, { "2", "2" }, { "3", "3" } })
    H.eq(c.scalar("SELECT n FROM " .. counter), "3")
    H.eq(seen.admission, 0)
    H.eq(result.readonly, true)
    H.eq(result.restorable, false)
    H.eq(result.editable, false)
    H.eq(result.cell_types[1], { "raw_unknown", "raw_unknown" })
    assert(not result.source_schema_proof or not result.source_schema_proof.receipt)
    H.eq(select(2, seen.input:gsub(marker, "")), 1)
    H.eq(seen.calls, 2)
    assert(not seen.input:find("START TRANSACTION;", 1, true), "legacy choice must precede original")
  end)
  test("LW03 controlled pre-read layout denial executes no original and never falls back", function(c)
    local result, err, seen = query("pre-deny")
    H.eq(result, nil)
    assert(err:find("controlled layout witness denial", 1, true), err)
    assert(err:find("original read was not submitted", 1, true), err)
    H.eq(seen.calls, 1)
    H.eq(seen.admission, 0)
    H.eq(select(2, seen.input:gsub(marker, "")), 0)
    H.eq(c.scalar("SELECT n FROM " .. counter), "0")
  end)
  test("LW04 controlled post-read layout denial withholds without COMMIT or replay", function(c)
    local result, err, seen = query("post-deny")
    H.eq(result, nil)
    assert(err:find("controlled layout witness denial", 1, true), err)
    assert(err:find("do not retry", 1, true), err)
    H.eq(seen.calls, 2)
    H.eq(seen.admission, 0)
    H.eq(select(2, seen.input:gsub(marker, "")), 1)
    assert(not seen.input:find("COMMIT;", 1, true))
    H.eq(c.scalar("SELECT n FROM " .. counter), "0", "own InnoDB counter must actually roll back on close")
  end)
  test("LW05 native quoted names and literal punctuation retain exact full layout", function(c)
    c.exec("DROP TABLE " .. source)
    local created, problem = db.query('CREATE TABLE ' .. source
      .. ' ("i`d" INTEGER PRIMARY KEY,"sp ace" TEXT,"λ.x" DECIMAL(12,4),'
      .. '"double""q" VARCHAR(40) DEFAULT \'a\'\'b,(x)\',"hidden field" TEXT INVISIBLE,'
      .. '"computed" INTEGER GENERATED ALWAYS AS(("i`d"+1)) STORED,UNIQUE KEY "u" ("double""q")) ENGINE=InnoDB', url)
    assert(created, problem)
    local inserted, failure = db.query('INSERT INTO ' .. source
      .. ' ("i`d","sp ace","λ.x") VALUES(1,CONVERT(X\'CEBB\' USING utf8mb4),1.2300)', url)
    assert(inserted, failure)
    local result, err, seen = query("positive", "SELECT * FROM " .. source)
    assert(result, err)
    H.eq(result.columns, { "i`d", "sp ace", "λ.x", 'double"q', "computed" })
    H.eq(result.rows, { { "1", "λ", "1.2300", "a'b,(x)", "2" } })
    H.eq(#result.source_schema_proof.columns, 6)
    H.eq(result.source_schema_proof.columns[5].column_name, "hidden field")
    H.eq(result.source_schema_proof.columns[5].visible, false)
    H.eq(result.restorable, true)
    H.eq(result.editable, true)
    H.eq(seen.witness, 2)
  end)
end
H.finish("safety_adversarial_layout_witness_spec")
