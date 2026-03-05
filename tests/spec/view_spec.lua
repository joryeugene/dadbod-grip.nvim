-- view_spec.lua: unit tests for classify_cell conditional formatting
local view = require("dadbod-grip.view")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local classify = view._classify_cell

-- ── boolean detection (no type) ──────────────────────────────────────────────

test("classify_cell: 'true' returns GripBoolTrue", function()
  eq(classify("true", nil), "GripBoolTrue")
end)

test("classify_cell: 'false' returns GripBoolFalse", function()
  eq(classify("false", nil), "GripBoolFalse")
end)

test("classify_cell: 't' returns GripBoolTrue", function()
  eq(classify("t", nil), "GripBoolTrue")
end)

test("classify_cell: 'f' returns GripBoolFalse", function()
  eq(classify("f", nil), "GripBoolFalse")
end)

-- ── boolean detection (with type) ────────────────────────────────────────────

test("classify_cell: '1' with tinyint(1) returns GripBoolTrue", function()
  eq(classify("1", "tinyint(1)"), "GripBoolTrue")
end)

test("classify_cell: '0' with boolean returns GripBoolFalse", function()
  eq(classify("0", "boolean"), "GripBoolFalse")
end)

test("classify_cell: 'yes' with bool returns GripBoolTrue", function()
  eq(classify("yes", "bool"), "GripBoolTrue")
end)

test("classify_cell: 'no' with boolean returns GripBoolFalse", function()
  eq(classify("no", "boolean"), "GripBoolFalse")
end)

-- ── negative numbers ─────────────────────────────────────────────────────────

test("classify_cell: '-12.50' returns GripNegative", function()
  eq(classify("-12.50", nil), "GripNegative")
end)

test("classify_cell: '-1' returns GripNegative", function()
  eq(classify("-1", nil), "GripNegative")
end)

test("classify_cell: '0' without type returns nil", function()
  eq(classify("0", nil), nil)
end)

test("classify_cell: '100' returns nil", function()
  eq(classify("100", nil), nil)
end)

-- ── URLs and emails ──────────────────────────────────────────────────────────

test("classify_cell: https URL returns GripUrl", function()
  eq(classify("https://example.com", nil), "GripUrl")
end)

test("classify_cell: http URL returns GripUrl", function()
  eq(classify("http://insecure.com", nil), "GripUrl")
end)

test("classify_cell: email returns GripUrl", function()
  eq(classify("user@example.com", nil), "GripUrl")
end)

test("classify_cell: non-URL returns nil", function()
  eq(classify("not_a_url", nil), nil)
end)

-- ── past dates ───────────────────────────────────────────────────────────────

test("classify_cell: past date with date type returns GripDatePast", function()
  eq(classify("2020-01-01", "date"), "GripDatePast")
end)

test("classify_cell: future date with timestamp returns nil", function()
  eq(classify("2099-12-31", "timestamp"), nil)
end)

test("classify_cell: past date without type returns nil", function()
  eq(classify("2020-01-01", nil), nil)
end)

-- ── edge cases ───────────────────────────────────────────────────────────────

test("classify_cell: nil returns nil", function()
  eq(classify(nil, nil), nil)
end)

test("classify_cell: empty string returns nil", function()
  eq(classify("", nil), nil)
end)

test("classify_cell: '-0.5' is negative not bool", function()
  eq(classify("-0.5", nil), "GripNegative")
end)

-- ── precedence ───────────────────────────────────────────────────────────────

test("classify_cell: 'true' with tinyint(1) returns GripBoolTrue (type-gated)", function()
  eq(classify("true", "tinyint(1)"), "GripBoolTrue")
end)

test("classify_cell: '1' without type returns nil (not bool)", function()
  eq(classify("1", nil), nil)
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nview_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
