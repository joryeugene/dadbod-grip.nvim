-- Native ordinary positives and pre-batch proof boundaries. Direct write
-- controls derive IDs/text from actual server rows, never inferred ordinals.
if not vim.env.GRIP_SAFETY_MYSQL_URL and not vim.env.GRIP_SAFETY_MARIA_URL then
  print("safety_adversarial_mysql_enum_boundary_spec: SKIP (assigned fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local profiles = dofile("tests/fixtures/safety_mysql_profiles.lua")
local db, data, transaction = require("dadbod-grip.db"), require("dadbod-grip.data"), require("dadbod-grip.transaction")
local adapters = require("dadbod-grip.adapters")
local name = "grip_review_enum_boundary"
local oracle = "SELECT id,payload+0,HEX(payload),note FROM " .. name .. " ORDER BY id"
local function unhex(value)
  return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end
for _, key in ipairs({ "GRIP_SAFETY_MYSQL_URL", "GRIP_SAFETY_MARIA_URL" }) do
  local url = vim.env[key]
  if url then
    assert(require("dadbod-grip.sql").parse_dadbod_url(url).dbname == "grip_safety_review", "unassigned fixture")
    local function test(profile, family, fn)
      H.test(key .. " " .. family .. " " .. profile.id, function(c)
        c.url = url
        c.exec("DROP TABLE IF EXISTS " .. name)
        c.exec("CREATE TABLE " .. name .. "(id INTEGER AUTO_INCREMENT PRIMARY KEY,payload " .. profile.definition
          .. ",note VARCHAR(30)); INSERT INTO " .. name .. " VALUES " .. profile.values)
        local ok, err = xpcall(function() fn(c, c.rows(oracle)) end, debug.traceback)
        c.exec("DROP TABLE " .. name)
        if not ok then error(err) end
      end)
    end
    for _, profile in ipairs(profiles.ordinary) do
      test(profile, "F09 proven common profile remains usable", function(c, before)
        H.eq({ before[1][2], before[2][2] }, profile.numeric, "native ordinary value/zero control")
        local buf, session = c.open(name)
        assert(not session.state.readonly, "ordinary profile was blanket-disabled")
        for row = 1, 2 do
          H.eq(data.effective_value(session.state, row, "payload"), unhex(before[row][3]), "original server bytes vs read")
        end
        c.edit(buf, session, 1, "note", "ours")
        c.action("grid_apply")
        H.eq(c.scalar("SELECT note FROM " .. name .. " WHERE id=1"), "ours")
        c.action("grid_undo")
        H.eq(c.rows(oracle), before)
        session.on_clone(buf, 1)
        c.action("grid_apply")
        H.eq(c.scalar("SELECT count(*) FROM " .. name), "3")
        local expected = vim.deepcopy(before[1]); expected[1] = "3"
        H.eq(c.rows(oracle)[3], expected)
        c.action("grid_undo")
        H.eq(c.rows(oracle), before)
        session.on_delete(buf, 1); session.on_delete(buf, 2)
        c.action("grid_apply")
        H.eq(c.scalar("SELECT count(*) FROM " .. name), "0")
        c.action("grid_undo")
        H.eq(c.rows(oracle), before, "ordinary profile must restore both member and unique zero spelling")
      end)
    end
    local function typed_state(c)
      -- Explicit transaction input from native HEX, as in the receipt tests.
      -- A computed CAST projection is deliberately not an editable grid now;
      -- this fixture must reach the compiler's independent type-profile gate.
      local encoded = c.rows("SELECT HEX(CAST(id AS CHAR)) AS id,HEX(CAST(payload AS CHAR)) AS payload,"
        .. "HEX(CONVERT(note USING utf8mb4)) AS note FROM " .. name .. " ORDER BY id")
      local rows, types = {}, {}
      for ri, row in ipairs(encoded) do
        rows[ri], types[ri] = {}, { "number", "text", "text" }
        for ci = 1, 3 do
          if row[ci] == vim.NIL then rows[ri][ci], types[ri][ci] = vim.NIL, "null"
          else
            assert(type(row[ci]) == "string" and row[ci]:match("^%x*$") and #row[ci] % 2 == 0,
              "native HEX oracle is malformed")
            rows[ri][ci] = unhex(row[ci])
          end
        end
      end
      return data.new({ table_name = name, primary_keys = { "id" }, columns = { "id", "payload", "note" },
        rows = rows, cell_types = types, storage_adapter = "mysql" }), assert(db.get_column_info(name, url))
    end
    local function submit(state, info)
      local plan, err = transaction.plan(state, info)
      assert(plan, err)
      local original, writers = adapters.run_cmd, 0
      adapters.run_cmd = function(argv, timeout, opts)
        if argv[1] == "mysql" and opts and opts.stdin and opts.stdin:find("\nBEGIN;", 1, true) then writers = writers + 1 end
        return original(argv, timeout, opts)
      end
      local ok, result, failure = pcall(db.execute, plan, url)
      adapters.run_cmd = original
      assert(ok, result)
      return result, failure, writers
    end
    for _, profile in ipairs(profiles.ambiguous) do
      test(profile, "F10 ambiguous profile refuses complete mixed batch", function(c, before)
        local state, info = typed_state(c)
        state = data.add_change(state, 1, "note", "first-must-not-commit")
        state = data.add_change(state, 2, "note", "second-must-not-commit")
        local result, err, writers = submit(state, info)
        H.eq(result, nil, "unproven definition reached verified write")
        assert(type(err) == "string" and (err:lower():find("enum", 1, true) or err:lower():find("set", 1, true)),
          "profile refusal must identify its unsupported type")
        H.eq(writers, 0, "refuse before submitting any batch write")
        H.eq(c.rows(oracle), before, "first or later batch member changed")
        assert(data.has_changes(state), "refusal lost pending work")
      end)
    end
    for _, profile in ipairs(profiles.escaped) do
      test(profile, "F11 escaping is exact or explicitly contained", function(c, before)
        local state, info = typed_state(c)
        state = data.toggle_delete(state, 1)
        local result, err, writers = submit(state, info)
        if not result then
          assert(type(err) == "string" and (err:lower():find("enum", 1, true) or err:lower():find("set", 1, true)))
          H.eq(writers, 0)
          H.eq(c.rows(oracle), before)
          print("CONTAINED: " .. profile.id .. " not claimed supported")
        else
          H.eq(c.scalar("SELECT count(*) FROM " .. name), "1")
          local restored, failure = db.execute(result.undo, url)
          assert(restored, failure)
          H.eq(c.rows(oracle), before, "escaped member lost its original ordinal/mask or bytes")
        end
      end)
    end
  end
end
H.finish("safety_adversarial_mysql_enum_boundary_spec")
