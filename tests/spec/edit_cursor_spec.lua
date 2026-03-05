-- edit_cursor_spec.lua: tests for view._snap_col byte-to-column mapping
--
-- Verifies that _snap_col correctly snaps mid-separator bytes left and
-- in-column bytes to the right column, using a two-row scenario where
-- a preceding column has different byte widths:
--
-- Layout (ROW_PREFIX=4, SEP=5):
--   Row 1:  id="foo   " (6 bytes) → name.start = 4+6+5 = 15
--   Row 2:  id="·NULL·" (8 bytes) → name.start = 4+8+5 = 17
--
-- Using row1's byte offset (15) in row2 falls mid-separator → snaps LEFT → "id".
-- Using row2's actual bp.start (17) lands inside name col → snaps to "name".

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

-- Build byte-position table the same way build_render() does:
--   ROW_PREFIX_BYTES = 4  (║=3 + space=1)
--   COL_SEP_BYTES    = 5  (space + │(3) + space)
local ROW_PREFIX = 4
local COL_SEP    = 5

local function make_bp(col_widths)
  local bp = {}
  local pos = ROW_PREFIX
  for i, col in ipairs(col_widths) do
    bp[col.name] = { start = pos, finish = pos + col.bytes - 1 }
    pos = pos + col.bytes
    if i < #col_widths then pos = pos + COL_SEP end
  end
  return bp
end

-- Two-row scenario: "id" col = 6 display chars, "name" col = 8 display chars
--   Row 1 (edited):  id="foo   "  (6 bytes, 6 display)
--   Row 2 (next):    id="·NULL·"  (8 bytes, 6 display: each "·" is U+00B7 = 2 bytes)
local bp_row1 = make_bp({ { name = "id", bytes = 6 }, { name = "name", bytes = 8 } })
local bp_row2 = make_bp({ { name = "id", bytes = 8 }, { name = "name", bytes = 8 } })

-- Verify our arithmetic before the behavioral tests
test("setup: row1 name.start = 15", function()
  eq(bp_row1["name"].start, 15)
end)
test("setup: row2 name.start = 17", function()
  eq(bp_row2["name"].start, 17)
end)

local vis_cols = { "id", "name" }

-- ── mid-separator bytes snap LEFT ────────────────────────────────────────────

test("row1 name.start (byte 15) in row2 is mid-separator → snaps left to 'id'", function()
  local result = view._snap_col(vis_cols, bp_row2, bp_row1["name"].start)
  eq(result and result.col_name, "id", "byte 15 in row2 is mid-separator → 'id'")
end)

test("byte 14 (mid-separator) in row2 snaps left to 'id'", function()
  local result = view._snap_col(vis_cols, bp_row2, 14)
  eq(result and result.col_name, "id", "byte 14 is mid-separator → 'id'")
end)

-- ── correct bytes land on the right column ───────────────────────────────────

test("row2 name.start (byte 17) lands on 'name'", function()
  local result = view._snap_col(vis_cols, bp_row2, bp_row2["name"].start)
  eq(result and result.col_name, "name", "byte 17 inside name col [17,24] → 'name'")
end)

test("last sep byte (row2 name.start-1=16) snaps RIGHT to 'name'", function()
  local result = view._snap_col(vis_cols, bp_row2, 16)
  eq(result and result.col_name, "name", "byte 16 == name.start-1 → right-snap → 'name'")
end)

test("byte inside id col in row2 returns 'id'", function()
  local result = view._snap_col(vis_cols, bp_row2, 7)
  eq(result and result.col_name, "id", "byte 7 inside id col [4,11] → 'id'")
end)

-- ── summary ──────────────────────────────────────────────────────────────────
print(string.format("\nedit_cursor_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
