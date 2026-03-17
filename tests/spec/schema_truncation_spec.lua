-- schema_truncation_spec.lua
-- Contract: schema._truncate_name(label, max_cols) right-truncates a table name
-- to fit within max_cols display columns, preserving the left side (schema prefix).
--
-- Three bugs this catches:
-- 1. Left-truncation: old code discards the schema prefix, leaving "...fct_logs_raw"
-- 2. Static width: old code ignores actual window size, clips at 33 cols always
-- 3. Crash on narrow windows: max_cols - 1 without a floor can produce empty/nil
dofile("tests/minimal_init.lua")
local schema = require("dadbod-grip.schema")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

local ELLIPSIS = "\xe2\x80\xa6"  -- U+2026 HORIZONTAL ELLIPSIS, display width 1

-- Short name: fits without truncation
test("short name fits: no ellipsis", function()
  eq(schema._truncate_name("users", 20), "users", "short name unchanged")
end)

-- Exact fit: no truncation at boundary
test("exact fit: no ellipsis at boundary", function()
  eq(schema._truncate_name("users", 5), "users", "5-char name fits in 5 cols")
end)

-- One over: right-truncates, appending ellipsis at end
test("one-over: right-truncated with ellipsis suffix", function()
  local result = schema._truncate_name("abcdef", 5)
  -- 5 cols: 4 chars of name + 1-col ellipsis
  eq(result, "abcd" .. ELLIPSIS, "4 chars + ellipsis")
end)

-- Long qualified name: schema prefix preserved (right side clipped)
test("long qualified name: schema prefix preserved", function()
  local name = "autodesk_data_raw.fct_daily_ms365_copilot_usage"
  local result = schema._truncate_name(name, 33)
  assert(
    result:sub(1, 1) ~= ELLIPSIS:sub(1, 1),
    "result must not start with ellipsis (left-truncation was the old bug): " .. result
  )
  assert(
    result:sub(1, 17) == "autodesk_data_raw",
    "schema prefix preserved: " .. result
  )
end)

-- Long qualified name: result fits within max_cols display columns
test("long qualified name: result fits in max_cols", function()
  local name = "autodesk_data_raw.fct_daily_ms365_copilot_usage"
  local result = schema._truncate_name(name, 33)
  local dw = vim.fn.strdisplaywidth(result)
  assert(dw <= 33, "display width " .. dw .. " exceeds max_cols 33: " .. result)
end)

-- Very narrow window: no crash, non-empty result
test("very narrow (max_cols=5): no crash, non-empty", function()
  local result = schema._truncate_name("autodesk_data_raw.fct_gpt_logs_raw", 5)
  assert(type(result) == "string" and #result > 0, "non-empty result")
end)

-- Extreme narrow (max_cols=1): no crash
test("extreme narrow (max_cols=1): no crash", function()
  local ok, result = pcall(schema._truncate_name, "very_long_table_name", 1)
  assert(ok, "no error on max_cols=1")
  assert(type(result) == "string" and #result > 0, "non-empty result")
end)

-- Already fits at exact window size after previous widening
test("wider window: no truncation on 46-char name at 50 cols", function()
  local name = "autodesk_data_raw.fct_daily_ms365_copilot_usage"
  local result = schema._truncate_name(name, 50)
  eq(result, name, "full name fits at 50 cols, no truncation")
end)

print(string.format("schema_truncation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
