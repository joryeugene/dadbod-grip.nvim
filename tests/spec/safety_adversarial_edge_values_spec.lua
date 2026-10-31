-- Additive controls for exact supported values or explicit pre-write refusal.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local data = require("dadbod-grip.data")
local eq = H.eq

local function no_false_success(c)
  assert(not table.concat(c.notices, "\n"):find("Applied ", 1, true), "refused work reported success")
end
for _, case in ipairs({
  { id = "V01 finite REAL", values = "(1,5e-324),(2,2.2250738585072014e-308),(3,1.7976931348623157e308),(4,0.1)" },
  { id = "V02 nonfinite REAL", values = "(1,1e999),(2,-1e999)" },
}) do
  H.test(case.id .. " delete Undo is exact or refused before mutation", function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload REAL); INSERT INTO t VALUES " .. case.values)
    local oracle = "SELECT id,typeof(payload),CASE WHEN payload=1e999 THEN '+inf' WHEN payload=-1e999"
      .. " THEN '-inf' ELSE printf('%!.26g',payload) END FROM t ORDER BY id"
    local before = c.rows(oracle)
    local buf, session = c.open("t")
    for row = 1, #before do session.on_delete(buf, row) end
    c.action("grid_apply")
    local remaining = tonumber(c.scalar("SELECT count(*) FROM t"))
    if remaining == #before then
      eq(c.rows(oracle), before, "refusal preserves exact original values")
      assert(session.state.readonly or data.has_changes(session.state), "refusal lost pending work")
      no_false_success(c)
      print("CONTAINED: " .. case.id .. " refused before write; durable restoration not demonstrated")
      return
    end
    eq(remaining, 0, "no partial delete")
    c.action("grid_undo")
    eq(c.rows(oracle), before, "do not restore REAL values through rounded display text")
  end)
end

for _, case in ipairs({
  { id = "V03 BLOB clone", declared = "BLOB", value = "X'004142ff'" },
  { id = "V04 dynamic BLOB clone", declared = "TEXT", value = "X'004142ff'" },
  { id = "V05 typeless INTEGER clone", declared = "", value = "7" },
  { id = "V06 typeless REAL clone", declared = "", value = "7.5" },
}) do
  H.test(case.id .. " preserves bytes and storage class or refuses before write", function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload " .. case.declared .. ");"
      .. "INSERT INTO t VALUES(1," .. case.value .. ")")
    local before = c.rows("SELECT typeof(payload),hex(payload) FROM t")
    local buf, session = c.open("t")
    session.on_clone(buf, 1)
    eq(c.scalar("SELECT count(*) FROM t"), "1", "cloning only stages work")
    c.action("grid_apply")
    local rows = c.rows("SELECT typeof(payload),hex(payload) FROM t ORDER BY id")
    if #rows == 1 then
      eq(rows, before)
      assert(session.state.readonly or data.has_changes(session.state), "refusal lost pending work")
      no_false_success(c)
      print("CONTAINED: " .. case.id .. " refused before write; clone capability not demonstrated")
      return
    end
    eq(rows, { before[1], before[1] }, "display text is not the original storage value")
  end)
end
H.finish("safety_adversarial_edge_values_spec")
