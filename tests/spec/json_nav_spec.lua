-- json_nav_spec.lua: TDD spec for view.json_to_lines()
-- Exported as M._json_to_lines for testing.
-- Run: just test
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

local function contains(s, pattern, msg)
  assert(tostring(s):find(pattern, 1, true),
    (msg or "") .. ": expected to contain '" .. pattern .. "', got: " .. tostring(s))
end

local json_to_lines = view._json_to_lines

-- ── basic scalars ────────────────────────────────────────────────────────────

test("json_to_lines: nil input returns nil", function()
  local result = json_to_lines(nil)
  eq(result, nil)
end)

test("json_to_lines: string scalar returns single-element table", function()
  local result = json_to_lines("hello")
  eq(type(result), "table")
  eq(#result, 1)
  eq(result[1], '"hello"')
end)

test("json_to_lines: number scalar returns single-element table", function()
  local result = json_to_lines(42)
  eq(result[1], "42")
end)

test("json_to_lines: boolean true returns single-element table", function()
  local result = json_to_lines(true)
  eq(result[1], "true")
end)

test("json_to_lines: boolean false returns single-element table", function()
  local result = json_to_lines(false)
  eq(result[1], "false")
end)

-- ── flat object ──────────────────────────────────────────────────────────────

test("json_to_lines: flat object has opening brace, key-value, closing brace", function()
  -- Use vim.fn.json_decode to get a real decoded object
  local ok, decoded = pcall(vim.fn.json_decode, '{"key":"val"}')
  if not ok then return end  -- skip if json_decode unavailable
  local result = json_to_lines(decoded)
  eq(result[1], "{")
  eq(result[#result], "}")
  -- Middle lines contain the key-value pair
  local found = false
  for _, line in ipairs(result) do
    if line:find('"key"', 1, true) and line:find('"val"', 1, true) then
      found = true
    end
  end
  assert(found, "Expected key-value line in flat object output")
end)

test("json_to_lines: flat object has proper indentation (2 spaces)", function()
  local ok, decoded = pcall(vim.fn.json_decode, '{"x":1}')
  if not ok then return end
  local result = json_to_lines(decoded)
  -- Key-value line should start with 2 spaces
  local kv_line
  for _, line in ipairs(result) do
    if line:find('"x"', 1, true) then kv_line = line; break end
  end
  assert(kv_line, "Expected kv line")
  assert(kv_line:sub(1, 2) == "  ", "Expected 2-space indent, got: " .. kv_line)
end)

-- ── array ────────────────────────────────────────────────────────────────────

test("json_to_lines: array has [ and ] brackets", function()
  local ok, decoded = pcall(vim.fn.json_decode, '["a","b","c"]')
  if not ok then return end
  local result = json_to_lines(decoded)
  eq(result[1], "[")
  eq(result[#result], "]")
end)

test("json_to_lines: array items are on separate lines", function()
  local ok, decoded = pcall(vim.fn.json_decode, '["alpha","beta"]')
  if not ok then return end
  local result = json_to_lines(decoded)
  -- Should have at least 4 lines: [, item1, item2, ]
  assert(#result >= 4, "Expected at least 4 lines, got " .. #result)
end)

-- ── nested object ────────────────────────────────────────────────────────────

test("json_to_lines: nested object has deeper indentation", function()
  local ok, decoded = pcall(vim.fn.json_decode, '{"outer":{"inner":"val"}}')
  if not ok then return end
  local result = json_to_lines(decoded)
  -- "inner" should be indented more than "outer"
  local outer_indent, inner_indent = 0, 0
  for _, line in ipairs(result) do
    if line:find('"outer"', 1, true) then
      outer_indent = #(line:match("^(%s*)") or "")
    end
    if line:find('"inner"', 1, true) then
      inner_indent = #(line:match("^(%s*)") or "")
    end
  end
  assert(inner_indent > outer_indent,
    "inner indent (" .. inner_indent .. ") should be > outer indent (" .. outer_indent .. ")")
end)

-- ── empty containers ─────────────────────────────────────────────────────────

test("json_to_lines: empty object produces { and }", function()
  local ok, decoded = pcall(vim.fn.json_decode, '{}')
  if not ok then return end
  local result = json_to_lines(decoded)
  eq(result[1], "{")
  eq(result[#result], "}")
end)

-- ── max depth truncation ─────────────────────────────────────────────────────

test("json_to_lines: max_depth truncation emits ellipsis placeholder", function()
  -- Build a deeply nested object that exceeds depth limit
  local deep = '{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":"leaf"}}}}}}}}}'
  local ok, decoded = pcall(vim.fn.json_decode, deep)
  if not ok then return end
  local result = json_to_lines(decoded)
  local found_ellipsis = false
  for _, line in ipairs(result) do
    if line:find("...", 1, true) then found_ellipsis = true; break end
  end
  assert(found_ellipsis, "Expected ... truncation at max depth")
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\njson_nav_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
