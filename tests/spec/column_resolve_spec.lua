-- column_resolve_spec.lua: column-scoped actions must resolve the column from
-- whichever row the cursor is on -- a data row, the header row, or the type row.
--
-- The rows do not share byte offsets. A type name too long for its column is
-- truncated with "…", which spends 3 bytes on 1 display cell, so every column
-- after it sits at a different byte offset in the type row than in the header.
-- Handlers that paired _snap_col with hdr_byte_positions by hand therefore
-- resolved the wrong column while the cursor sat on the type row, and `s`/`S`
-- refused to resolve one at all off a data row.
--
-- These tests drive the real keymaps on a real grid buffer, which is the only
-- way to cover the wiring; view_snap_spec covers _resolve_col_at as a function.

local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")
local qmod = require("dadbod-grip.query")

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

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

--- A grid with the type row on, and types deliberately wider than their columns
--- so the type row truncates and its byte offsets diverge from the header's.
local function open_with_types()
  local state = data.new({
    columns = { "id", "name", "age" },
    rows = { { "1", "alice", "30" }, { "2", "bob", "25" } },
    primary_keys = { "id" },
    table_name = "users",
    url = "sqlite:test.db",
    sql = "SELECT * FROM users",
  })
  local bufnr = view.open(state, "sqlite:test.db", "SELECT * FROM users", {})
  local session = view._sessions[bufnr]
  session.show_types = true
  session._column_info = {
    { column_name = "id",   data_type = "INTEGER" },
    { column_name = "name", data_type = "CHARACTER VARYING" },
    { column_name = "age",  data_type = "INTEGER" },
  }
  session.query_spec = qmod.new_table("users", 100)
  view.render(bufnr, session.state)
  return bufnr, session
end

--- Invoke a buffer-local normal-mode keymap by its lhs.
local function press(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

--- The byte offset on the type row where reading hdr_byte_positions instead of
--- type_row_byte_positions would answer with a different column. Returned with
--- both answers so a test can assert the right one was taken.
local function divergent_offset(session)
  local r = session._render
  local cols = r.visible_columns or session.state.columns
  assert(r.type_row_byte_positions, "fixture has a type row")
  local last = 0
  for _, bp in pairs(r.hdr_byte_positions) do
    if bp.finish > last then last = bp.finish end
  end
  for c = 0, last + 4 do
    local by_hdr = view._snap_col(cols, r.hdr_byte_positions, c)
    local by_type = view._snap_col(cols, r.type_row_byte_positions, c)
    if by_hdr and by_type and by_hdr.col_name ~= by_type.col_name then
      return c, by_type.col_name, by_hdr.col_name
    end
  end
  return nil
end

-- ── the fixture itself has to diverge, or nothing below proves anything ──────

test("fixture: the type row's byte offsets diverge from the header's", function()
  cleanup()
  local bufnr, session = open_with_types()
  local col_nr, on_type, on_hdr = divergent_offset(session)
  assert(col_nr, "found no offset where the two rows disagree -- fixture no longer covers the bug")
  assert(on_type ~= on_hdr, "the two rows answer differently at byte " .. col_nr)
  assert(bufnr, "grid opened")
  cleanup()
end)

-- ── sort from every row ─────────────────────────────────────────────────────

test("s on a data row sorts the column under the cursor", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local captured
  session.on_requery = function(_, spec) captured = spec end

  local target = session._render.visible_columns[2]
  vim.api.nvim_win_set_cursor(win, { 5, session._render.byte_positions[1][target].start })
  assert(press(bufnr, "s"), "s is mapped")
  assert(captured, "requery fired")
  eq(captured.sorts[1].column, target, "sorted the column under the cursor")
  cleanup()
end)

test("s on the header row sorts, instead of refusing for want of a data row", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local captured
  session.on_requery = function(_, spec) captured = spec end

  local target = session._render.visible_columns[3]
  vim.api.nvim_win_set_cursor(win, { 2, session._render.hdr_byte_positions[target].start })
  assert(press(bufnr, "s"), "s is mapped")
  assert(captured, "requery fired from the header row")
  eq(captured.sorts[1].column, target, "sorted the header column under the cursor")
  cleanup()
end)

test("s on the type row uses the type row's byte offsets, not the header's", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local col_nr, on_type, on_hdr = divergent_offset(session)
  assert(col_nr, "fixture diverges")

  local captured
  session.on_requery = function(_, spec) captured = spec end

  vim.api.nvim_win_set_cursor(win, { 3, col_nr })
  assert(press(bufnr, "s"), "s is mapped")
  assert(captured, "requery fired from the type row")
  eq(captured.sorts[1].column, on_type, "sorted the column the cursor is really over")
  assert(captured.sorts[1].column ~= on_hdr,
    "reading hdr_byte_positions here would have sorted " .. tostring(on_hdr))
  cleanup()
end)

test("S on the type row stacks a sort on the right column", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local col_nr, on_type = divergent_offset(session)
  assert(col_nr, "fixture diverges")

  local captured
  session.on_requery = function(_, spec) captured = spec end

  vim.api.nvim_win_set_cursor(win, { 3, col_nr })
  assert(press(bufnr, "S"), "S is mapped")
  assert(captured, "requery fired")
  eq(captured.sorts[#captured.sorts].column, on_type, "stacked sort on the cursor's column")
  cleanup()
end)

-- ── filter from the type row ─────────────────────────────────────────────────

test("filter IS NULL on the type row targets the cursor's column", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local col_nr, on_type, on_hdr = divergent_offset(session)
  assert(col_nr, "fixture diverges")

  local captured
  session.on_requery = function(_, spec) captured = spec end

  vim.api.nvim_win_set_cursor(win, { 3, col_nr })
  local km = require("dadbod-grip.keymaps")
  assert(press(bufnr, km.get("grid_filter_null")), "filter-null is mapped")
  assert(captured, "requery fired")
  eq(#captured.filters, 1, "one filter added")
  assert(captured.filters[1].clause:find(on_type, 1, true),
    "filtered on " .. on_type .. ", got: " .. captured.filters[1].clause)
  assert(not captured.filters[1].clause:find(on_hdr, 1, true),
    "did not filter on the column the header would have named (" .. on_hdr .. ")")
  cleanup()
end)

-- ── value-scoped actions are deliberately left alone ────────────────────────

test("f on the type row still refuses: a cell value needs a data row", function()
  cleanup()
  local bufnr, session = open_with_types()
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_set_current_win(win)

  local captured
  session.on_requery = function(_, spec) captured = spec end

  vim.api.nvim_win_set_cursor(win, { 3, 4 })
  press(bufnr, "f")
  eq(captured, nil, "quick-filter-by-value is scoped to a cell, not a column")
  cleanup()
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\ncolumn_resolve_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
