-- edit_nav_spec.lua: TDD tests for M._next_edit_cursor
--
-- Tests the pure function that computes where the cursor should land
-- after editing a cell (spreadsheet-style: advance to next row, same column).
--
-- Bug being fixed: when a preceding column has a different byte width in the
-- next row (e.g. "foo   "=6 bytes vs "·NULL·"=8 bytes), the cursor must use
-- the NEXT row's byte positions, not the current cursor byte offset.
--
-- Layout constants (ROW_PREFIX=4, COL_SEP=5) match build_render():
--   byte_pos starts at 4 (ROW_PREFIX_BYTES)
--   each col sep adds 5 bytes (" │ " = 1+3+1)

local M = require("dadbod-grip.init")

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

-- Build byte positions the same way build_render() does
-- (ROW_PREFIX=4, COL_SEP=5)
local function make_bp(col_widths)
  local bp = {}
  local pos = 4  -- ROW_PREFIX_BYTES
  for i, col in ipairs(col_widths) do
    bp[col.name] = { start = pos, finish = pos + col.bytes - 1 }
    pos = pos + col.bytes
    if i < #col_widths then pos = pos + 5 end  -- COL_SEP_BYTES
  end
  return bp
end

-- Two-row scenario:
--   Row 1 (order 1, row_idx=1): id=6 bytes ("foo   "),  name=8 bytes
--   Row 2 (order 2, row_idx=2): id=8 bytes ("·NULL·"),  name=8 bytes
--   name.start row1 = 4+6+5 = 15
--   name.start row2 = 4+8+5 = 17  ← cursor must land HERE, not at 15
local bp1 = make_bp({ { name = "id", bytes = 6 }, { name = "name", bytes = 8 } })
local bp2 = make_bp({ { name = "id", bytes = 8 }, { name = "name", bytes = 8 } })

-- Fake render state: 2 data rows, data_start=4, byte_positions indexed by order
local fake_render = {
  data_start     = 4,
  ordered        = { 1, 2 },   -- row_idx 1 is order 1, row_idx 2 is order 2
  byte_positions = { bp1, bp2 },
}

-- ── basic advance ──────────────────────────────────────────────────────────

test("_next_edit_cursor: editing row 1 → next is row 2, line=5, col=name.start of row2", function()
  local result = M._next_edit_cursor(fake_render, 1, "name")
  eq(result ~= nil, true, "result must not be nil")
  eq(result.line, 5, "line")    -- data_start(4) + next_order(2) - 1 = 5
  eq(result.col, 17, "col")     -- bp2.name.start = 4+8+5 = 17
end)

test("_next_edit_cursor: col uses NEXT ROW byte positions, not current row", function()
  -- row 1 name.start = 15, row 2 name.start = 17
  -- must return 17, not 15
  local result = M._next_edit_cursor(fake_render, 1, "name")
  eq(result ~= nil, true)
  eq(result.col, 17, "must be row2's name.start (17), not row1's (15)")
end)

test("_next_edit_cursor: stays on last row when editing last row", function()
  local result = M._next_edit_cursor(fake_render, 2, "name")
  eq(result ~= nil, true, "result must not be nil on last row")
  eq(result.line, 5, "line stays on last row (data_start=4, order=2 → line=5)")
  eq(result.col, 17, "col from last row's byte positions")
end)

test("_next_edit_cursor: returns nil when row_idx not in ordered", function()
  local result = M._next_edit_cursor(fake_render, 99, "name")
  eq(result, nil, "unknown row_idx → nil")
end)

test("_next_edit_cursor: returns nil when col not in byte_positions", function()
  local result = M._next_edit_cursor(fake_render, 1, "nonexistent_col")
  eq(result, nil, "unknown col → nil")
end)

test("_next_edit_cursor: first column in row 1 → correct line and col", function()
  local result = M._next_edit_cursor(fake_render, 1, "id")
  eq(result ~= nil, true)
  eq(result.line, 5, "line=5")
  eq(result.col, 4, "id.start in row2 = 4 (ROW_PREFIX_BYTES)")
end)

-- ── summary ────────────────────────────────────────────────────────────────
print(string.format("\nedit_nav_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
