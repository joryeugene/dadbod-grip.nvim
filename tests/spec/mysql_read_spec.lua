-- Current N/T/X wire codec. Physical source admission is tested by the native
-- provider; these unbound results must never infer SQL types from payloads.
local read = require("dadbod-grip.mysql_read")
local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b) assert(vim.deep_equal(a, b), "expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a)) end
local function plan(count)
  local projections = {}
  for i = 1, count do projections[i] = "expr() AS c" .. i end
  return assert(read.resolve_plan(assert(read.plan("SELECT " .. table.concat(projections, ",")))))
end
test("wire tags preserve NULL, empty, literal hex, NUL, binary and exact numbers", function()
  local result = read.decode_derived({ "N\tT\tT307834313432\tX00FF41\tX39303037313939323534373430393933", "0" }, plan(5))
  eq(result.rows[1], { vim.NIL, "", "0x4142", "\0\255A", "9007199254740993" })
  eq(result.cell_types[1], { "null", "raw_unknown", "raw_unknown", "raw_unknown", "raw_unknown" })
  eq(result.restorable, false); eq(result.byte_exact, true)
end)
for _, data in ipairs({ { "T0", "0" }, { "TFF", "0" }, { "N00", "0" }, { "B00", "0" },
  { "T00\textra", "0" }, { "T00", "1" }, { "T00" }, { "T00", "0", "extra" } }) do
  test("reject malformed/inconsistent derived receipt: " .. table.concat(data, "/"), function()
    assert(not pcall(read.decode_derived, data, plan(1)))
  end)
end
test("empty results retain exact known headers but cannot prove physical types", function()
  local result = read.decode_derived({ "0" }, plan(2))
  eq(result.rows, {}); eq(result.columns, { "c1", "c2" })
  eq(result.column_info[1].kind, "raw_unknown"); eq(result.lossless, false)
end)
test("diagnostics allow only the bounded native deprecation warning", function()
  read.warnings({ "0" }); read.warnings({ "1", "Warning\t1287\tdeprecated" })
  assert(not pcall(read.warnings, { "1", "Warning\t1265\ttruncated" }))
  assert(not pcall(read.warnings, { "0", "Warning\t1287\textra" }))
end)
test("text tags prove UTF8 bytes independently of physical restoration", function()
  local result = read.decode_derived({ "TC3A9", "0" }, plan(1))
  eq(result.rows[1][1], "é"); eq(result.column_info[1].encoding_proven, true)
  eq(result.cell_types[1][1], "raw_unknown"); eq(result.editable, false)
end)
print(string.format("mysql_read_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
