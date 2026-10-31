-- Native assigned-DB effects with controlled provider/completion faults.
-- These are not native ACL-denial or network-outage reproductions.
local urls = { vim.env.GRIP_SAFETY_MYSQL_URL, vim.env.GRIP_SAFETY_MARIA_URL }
if not urls[1] and not urls[2] then
  print("safety_adversarial_read_first_spec: SKIP (assigned review fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, adapters = require("dadbod-grip.db"), require("dadbod-grip.adapters")
local mysql, sql = require("dadbod-grip.adapters.mysql"), require("dadbod-grip.sql")
local counter, source, func = "grip_review_bound_counter", "grip_review_bound_source", "grip_review_bound_value"
local marker = "BOUND_ORIGINAL_ONCE_REVIEW"
local function raw(url, statement)
  local parsed = assert(sql.parse_dadbod_url(url))
  assert(parsed.dbname == "grip_safety_review", "refuse any unassigned database")
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
        raw(url, "DROP FUNCTION IF EXISTS " .. func .. ";DROP TABLE IF EXISTS " .. counter .. "," .. source .. ";")
      end
      cleanup()
      local ok, err = xpcall(function()
        raw(url, "CREATE TABLE " .. counter .. "(n BIGINT) ENGINE=InnoDB; INSERT INTO " .. counter .. " VALUES(0);"
          .. "CREATE TABLE " .. source .. "(id INTEGER PRIMARY KEY) ENGINE=InnoDB; INSERT INTO " .. source .. " VALUES(1),(2),(3);\n"
          .. "DELIMITER //\nCREATE FUNCTION " .. func .. "() RETURNS BIGINT DETERMINISTIC MODIFIES SQL DATA\n"
          .. "BEGIN UPDATE " .. counter .. " SET n=n+1; RETURN (SELECT n FROM " .. counter .. "); END//\nDELIMITER ;\n")
        fn(c)
      end, debug.traceback)
      cleanup()
      if not ok then error(err) end
    end)
  end
  local function query(mode)
    local provider = require("dadbod-grip.mysql_source")
    local system, run_cmd = vim.system, adapters.run_cmd
    local describe, inspect, complete = provider.describe, provider.inspect, provider.complete
    local record = { calls = 0, completions = {}, input = {}, admitted = 0, pids = {} }
    -- All native processes still run normally. Only the original client's
    -- returned completion status changes in the after-COMMIT fault model.
    vim.system = function(args, opts, on_exit)
      record.calls = record.calls + 1
      local index = record.calls
      local proc = system(args, opts, function(value)
        record.completions[index] = value.code
        if mode == "completion" and index == 2 then
          value = vim.tbl_extend("force", value, { code = 79 })
        end
        if on_exit then on_exit(value) end
      end)
      record.pids[#record.pids + 1] = proc.pid
      local proxy = {}
      function proxy:write(value)
        if type(value) == "string" then record.input[#record.input + 1] = value end
        return proc:write(value)
      end
      function proxy:kill(...) return proc:kill(...) end
      function proxy:wait(...) return proc:wait(...) end
      return proxy
    end
    adapters.run_cmd = function() error("bound read must not fall back to legacy transport") end
    if mode == "pre" then
      provider.describe = function(target, identity, fetch)
        return describe(target, identity, function(statement, phase)
          if phase == "source column metadata" then return nil, "controlled pre-read metadata denial" end
          return fetch(statement, phase)
        end)
      end
    elseif mode == "post" then
      provider.inspect = function(client, candidate, token)
        local exchange = client.exchange
        client.exchange = function(statement, receipt, phase)
          if phase == "source column metadata" then return nil, "controlled post-read metadata denial" end
          return exchange(statement, receipt, phase)
        end
        local value, err = inspect(client, candidate, token)
        client.exchange = exchange
        return value, err
      end
    end
    provider.complete = function(...)
      record.admitted = record.admitted + 1
      return complete(...)
    end
    local ok, result, err = pcall(db.query, "SELECT /* " .. marker .. " */ id," .. func
      .. "() AS seen FROM " .. source .. " ORDER BY id", url)
    vim.system, adapters.run_cmd = system, run_cmd
    provider.describe, provider.inspect, provider.complete = describe, inspect, complete
    assert(ok, result)
    record.input = table.concat(record.input, "\n")
    for _, pid in ipairs(record.pids) do
      H.eq(vim.uv.fs_stat("/proc/" .. pid), nil, "owned native bridge child must be reaped")
    end
    return result, err, record
  end
  test("RF01 bound mixed projection commits one original and keeps computed cells unadmitted", function(c)
    local result, err, seen = query("positive")
    assert(result, err)
    H.eq(result.columns, { "id", "seen" })
    H.eq(result.rows, { { "1", "1" }, { "2", "2" }, { "3", "3" } })
    H.eq(c.scalar("SELECT n FROM " .. counter), "3")
    H.eq(seen.calls, 2)
    H.eq(seen.completions, { 0, 0 })
    H.eq(seen.admitted, 1)
    H.eq(select(2, seen.input:gsub(marker, "")), 1)
    H.eq(result.source_schema_proof.binding, "read_first_transaction")
    H.eq(type(result.source_schema_proof.receipt), "function")
    H.eq(result.source_columns[2], false)
    H.eq(result.cell_types[1][2], "raw_unknown")
    H.eq(result.editable, false)
    H.eq(result.restorable, false)
  end)
  test("RF02 controlled pre-read metadata denial runs no original", function(c)
    local result, err, seen = query("pre")
    H.eq(result, nil)
    assert(err:find("controlled pre-read metadata denial", 1, true), err)
    assert(err:find("original read was not submitted", 1, true), err)
    H.eq(seen.calls, 1)
    H.eq(seen.admitted, 0)
    H.eq(select(2, seen.input:gsub(marker, "")), 0)
    H.eq(c.scalar("SELECT n FROM " .. counter), "0")
  end)
  test("RF03 controlled post-read metadata denial withholds without COMMIT or replay", function(c)
    local result, err, seen = query("post")
    H.eq(result, nil)
    assert(err:find("controlled post-read metadata denial", 1, true), err)
    assert(err:find("do not retry", 1, true), err)
    H.eq(seen.calls, 2)
    H.eq(seen.admitted, 0)
    H.eq(select(2, seen.input:gsub(marker, "")), 1)
    assert(not seen.input:find("COMMIT;", 1, true), "must not continue denied metadata transaction")
    -- This disposable InnoDB function's effects actually roll back on close;
    -- this assertion is not a general claim for arbitrary function effects.
    H.eq(c.scalar("SELECT n FROM " .. counter), "0")
  end)
  test("RF04 controlled after-COMMIT completion fault never admits or repeats", function(c)
    local result, err, seen = query("completion")
    H.eq(result, nil)
    assert(err:find("COMMIT acknowledged but successful client completion unproven", 1, true), err)
    assert(err:find("do not retry", 1, true), err)
    H.eq(seen.calls, 2)
    H.eq(seen.completions, { 0, 0 }, "both actual native clients exited successfully before model injection")
    H.eq(seen.admitted, 0)
    H.eq(select(2, seen.input:gsub(marker, "")), 1)
    H.eq(select(2, seen.input:gsub("COMMIT;", "")), 1)
    H.eq(c.scalar("SELECT n FROM " .. counter), "3", "actual COMMIT must be visible once after result refusal")
  end)
end
H.finish("safety_adversarial_read_first_spec")
