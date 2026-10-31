-- Pure plan/provenance controls, not evidence of native MDL or public writes.
-- Parent clarified separate read-like and intentional custom-batch policies.
local ok, planner = pcall(require, "dadbod-grip.mysql_read_plan")
if not ok then print("safety_adversarial_derived_plan_spec: SKIP (gated planner unavailable)"); return end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local literals = {
  { name = "TRUE", dtype = "int" }, { name = "FALSE", dtype = "int" },
  { name = "NULL", dtype = "int" }, { name = "CURRENT_DATE", dtype = "date" },
  { name = "CURRENT_TIME", dtype = "time" }, { name = "CURRENT_TIMESTAMP", dtype = "datetime" },
}
for _, literal in ipairs(literals) do
  H.test("D01 literal does not acquire physical provenance " .. literal.name, function()
    local plan = planner.plan("SELECT id," .. literal.name .. " FROM t")
    if not plan or plan.route == "legacy" then return end
    assert(plan.slots[2].kind ~= "direct", "bare keyword expression acquired direct-column classification")
  end)
  H.test("D02 quoted keyword remains a direct column " .. literal.name, function()
    local plan, err = planner.plan("SELECT id,`" .. literal.name .. "` FROM t")
    assert(plan, err)
    H.eq(plan.route, "derived")
    H.eq(plan.slots[2].kind, "direct")
    H.eq(plan.slots[2].column, literal.name)
    H.eq(plan.columns[2], literal.name)
  end)
end
for _, statement in ipairs({
  "SHOW TABLES; SELECT 1", "SHOW TABLES;\n\\q", "DESCRIBE t; SELECT 1",
  "EXPLAIN SELECT 1; SELECT 2", "PRAGMA table_info(t); SELECT 1",
}) do
  H.test("D03 read-like head cannot hide batch/client-command tail " .. statement, function()
    local plan, err = planner.plan(statement)
    H.eq(plan, nil, "first word bypassed whole-input boundary checks")
    assert(type(err) == "string" and err ~= "")
  end)
end
for _, statement in ipairs({ "SHOW TABLES", "EXPLAIN SELECT 1", "SET @x=1; SELECT @x",
  "CREATE TABLE t(id INTEGER); INSERT INTO t VALUES(1)", "INSERT INTO t VALUES('literal \\! is data')" }) do
  H.test("D04 admitted custom seam is never a derived SELECT " .. statement, function()
    local plan, err = planner.plan(statement)
    assert(plan, err)
    assert(plan.route ~= "derived", "custom seam acquired safe-SELECT admission")
  end)
end
for _, statement in ipairs({
  "CREATE TABLE t(id INTEGER);\n\\! id", "INSERT INTO t VALUES(1);\nsource /tmp/not-an-authorized-script",
  "UPDATE t SET id=1;\n\\. /tmp/not-an-authorized-script", "CREATE TABLE t(id INTEGER);\n\\r other_database",
}) do
  H.test("D09 custom seam rejects client-control tail " .. statement, function()
    local plan, err = planner.plan(statement)
    H.eq(plan, nil, "custom first word bypassed client-control safety")
    assert(type(err) == "string" and err ~= "")
  end)
end
H.finish("safety_adversarial_derived_plan_spec")
