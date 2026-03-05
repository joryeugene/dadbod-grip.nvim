-- view_snap_spec.lua: unit tests for M._snap_col (pure separator snap logic)
-- Tests that cursor in separator between columns snaps to the LEFT (current) column,
-- not the RIGHT (next) column.
--
-- Layout used in tests (ROW_PREFIX = 4 bytes, COL_SEP = 5 bytes):
--   ║ [id  ] │ [name   ] │ [email          ] ║
--     4    5   12     18   25              38
--   bp:  4,5       12,18       25,38
--   sep: bytes 6-10 (between id/name), bytes 19-23 (between name/email)

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

-- bp_row with 3 columns: id(2), name(7), email(16)
-- Layout: ║ (4 bytes) + id(2) + sep(5) + name(7) + sep(5) + email(16) + " ║"
--   id:    start=4,  finish=5
--   name:  start=11, finish=17
--   email: start=23, finish=38
local vis_cols = { "id", "name", "email" }
local bp_row = {
  id    = { start = 4,  finish = 5  },
  name  = { start = 11, finish = 17 },
  email = { start = 23, finish = 38 },
}

-- ── Direct column hits ──────────────────────────────────────────────────────

test("_snap_col: cursor at id.start returns id", function()
  local result = view._snap_col(vis_cols, bp_row, 4)
  eq(result.col_name, "id")
  eq(result.col_idx, 1)
end)

test("_snap_col: cursor at id.finish returns id", function()
  local result = view._snap_col(vis_cols, bp_row, 5)
  eq(result.col_name, "id")
  eq(result.col_idx, 1)
end)

test("_snap_col: cursor at name.start returns name", function()
  local result = view._snap_col(vis_cols, bp_row, 11)
  eq(result.col_name, "name")
  eq(result.col_idx, 2)
end)

test("_snap_col: cursor at email.finish returns email", function()
  local result = view._snap_col(vis_cols, bp_row, 38)
  eq(result.col_name, "email")
  eq(result.col_idx, 3)
end)

-- ── Separator positions: must snap LEFT ────────────────────────────────────

test("_snap_col: cursor in sep between id/name snaps to id (mid-sep)", function()
  -- Separator bytes 6-9 (mid-separator): snap LEFT to id
  for col_nr = 6, 9 do
    local result = view._snap_col(vis_cols, bp_row, col_nr)
    eq(result.col_name, "id", "byte " .. col_nr .. " should snap to id")
    eq(result.col_idx, 1, "byte " .. col_nr .. " idx should be 1")
  end
end)

test("_snap_col: last sep byte before name snaps RIGHT to name", function()
  -- Byte 10 = name.start - 1: cursor is touching name → snap RIGHT
  local result = view._snap_col(vis_cols, bp_row, 10)
  eq(result.col_name, "name", "byte 10 (last sep before name) should snap to name")
  eq(result.col_idx, 2, "byte 10 idx should be 2")
end)

test("_snap_col: cursor in sep between name/email snaps to name (mid-sep)", function()
  -- Separator bytes 18-21 (mid-separator): snap LEFT to name
  for col_nr = 18, 21 do
    local result = view._snap_col(vis_cols, bp_row, col_nr)
    eq(result.col_name, "name", "byte " .. col_nr .. " should snap to name")
    eq(result.col_idx, 2, "byte " .. col_nr .. " idx should be 2")
  end
end)

test("_snap_col: last sep byte before email snaps RIGHT to email", function()
  -- Byte 22 = email.start - 1: cursor is touching email → snap RIGHT
  local result = view._snap_col(vis_cols, bp_row, 22)
  eq(result.col_name, "email", "byte 22 (last sep before email) should snap to email")
  eq(result.col_idx, 3, "byte 22 idx should be 3")
end)

-- ── Edge cases ──────────────────────────────────────────────────────────────

test("_snap_col: cursor before first column snaps to first", function()
  -- Before ROW_PREFIX ends (bytes 0-3 are "║ ")
  local result = view._snap_col(vis_cols, bp_row, 0)
  eq(result.col_name, "id", "pre-first-col should snap to id")
  eq(result.col_idx, 1)
end)

test("_snap_col: cursor past last column snaps to last", function()
  -- Past email.finish=38
  local result = view._snap_col(vis_cols, bp_row, 45)
  eq(result.col_name, "email", "post-last-col should snap to email")
  eq(result.col_idx, 3)
end)

test("_snap_col: single column always returns that column", function()
  local single_cols = { "only" }
  local single_bp = { only = { start = 4, finish = 10 } }
  -- In separator region after only col
  local result = view._snap_col(single_cols, single_bp, 15)
  eq(result.col_name, "only")
  eq(result.col_idx, 1)
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\nview_snap_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
