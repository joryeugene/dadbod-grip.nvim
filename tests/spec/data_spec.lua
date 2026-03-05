-- data_spec.lua: unit tests for data.lua (pure state transforms)
local data = require("dadbod-grip.data")

local function make_state(overrides)
  local result = {
    rows = overrides.rows or { { "1", "alice", "alice@test.com" }, { "2", "bob", "bob@test.com" } },
    columns = overrides.columns or { "id", "name", "email" },
    primary_keys = overrides.primary_keys or { "id" },
    table_name = overrides.table_name,  -- nil means no table_name (readonly)
    url = "postgresql://localhost/test",
  }
  -- Default table_name to "users" unless explicitly set to nil
  if overrides.table_name == nil and not overrides.no_table_name then
    result.table_name = "users"
  end
  return data.new(result)
end

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

-- ── new() ───────────────────────────────────────────────────────────────────

test("new: creates state with correct columns", function()
  local st = make_state({})
  eq(#st.columns, 3)
  eq(st.columns[1], "id")
  eq(st.columns[2], "name")
  eq(st.columns[3], "email")
end)

test("new: readonly when no PKs", function()
  local st = make_state({ primary_keys = {} })
  eq(st.readonly, true, "should be readonly")
end)

test("new: editable when PKs present", function()
  local st = make_state({})
  eq(st.readonly, false, "should be editable")
end)

test("new: readonly when no table_name", function()
  local st = make_state({ no_table_name = true, primary_keys = { "id" } })
  eq(st.readonly, true, "no table_name should be readonly")
end)

test("new: rows are deep-copied", function()
  local original = { { "1", "alice" } }
  local st = make_state({ rows = original, columns = { "id", "name" } })
  original[1][2] = "mutated"
  eq(st.rows[1][2], "alice", "should not mutate")
end)

test("new: initial state has no changes", function()
  local st = make_state({})
  eq(data.has_changes(st), false)
  eq(data.count_staged(st), 0)
end)

-- ── add_change() ────────────────────────────────────────────────────────────

test("add_change: stages a cell change", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "alice_new")
  eq(data.effective_value(st2, 1, "name"), "alice_new")
end)

test("add_change: does not mutate original", function()
  local st = make_state({})
  local _ = data.add_change(st, 1, "name", "bob")
  eq(data.effective_value(st, 1, "name"), "alice", "original should be unchanged")
end)

test("add_change: nil stores as NULL", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", nil)
  eq(data.effective_value(st2, 1, "name"), nil, "nil means NULL")
end)

test("add_change: empty string stores as NULL", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "")
  eq(data.effective_value(st2, 1, "name"), nil, "empty string means NULL")
end)

test("add_change: multiple changes on same row", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "newname")
  local st3 = data.add_change(st2, 1, "email", "new@test.com")
  eq(data.effective_value(st3, 1, "name"), "newname")
  eq(data.effective_value(st3, 1, "email"), "new@test.com")
end)

-- ── toggle_delete() ─────────────────────────────────────────────────────────

test("toggle_delete: marks row for deletion", function()
  local st = make_state({})
  local st2 = data.toggle_delete(st, 1)
  eq(data.row_status(st2, 1), "deleted")
end)

test("toggle_delete: double toggle unmarks", function()
  local st = make_state({})
  local st2 = data.toggle_delete(st, 1)
  local st3 = data.toggle_delete(st2, 1)
  eq(data.row_status(st3, 1), "clean")
end)

-- ── insert_row() ────────────────────────────────────────────────────────────

test("insert_row: creates inserted row", function()
  local st = make_state({})
  local st2 = data.insert_row(st, 2)
  local ordered = data.get_ordered_rows(st2)
  assert(#ordered == 3, "should have 3 rows (2 original + 1 insert)")
  eq(data.row_status(st2, ordered[3]), "inserted")
end)

test("insert_row: inserted row has nil values", function()
  local st = make_state({})
  local st2 = data.insert_row(st, 2)
  local ordered = data.get_ordered_rows(st2)
  local ins_idx = ordered[3]
  eq(data.effective_value(st2, ins_idx, "name"), nil)
end)

test("insert_row: can edit inserted row", function()
  local st = make_state({})
  local st2 = data.insert_row(st, 2)
  local ordered = data.get_ordered_rows(st2)
  local ins_idx = ordered[3]
  local st3 = data.add_change(st2, ins_idx, "name", "carol")
  eq(data.effective_value(st3, ins_idx, "name"), "carol")
end)

-- ── undo_row() ──────────────────────────────────────────────────────────────

test("undo_row: removes changes", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "changed")
  local st3 = data.undo_row(st2, 1)
  eq(data.effective_value(st3, 1, "name"), "alice")
  eq(data.row_status(st3, 1), "clean")
end)

test("undo_row: removes deletion", function()
  local st = make_state({})
  local st2 = data.toggle_delete(st, 1)
  local st3 = data.undo_row(st2, 1)
  eq(data.row_status(st3, 1), "clean")
end)

-- ── undo_all() ──────────────────────────────────────────────────────────────

test("undo_all: clears all changes", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "changed")
  local st3 = data.toggle_delete(st2, 2)
  local st4 = data.insert_row(st3, 2)
  local st5 = data.undo_all(st4)
  eq(data.has_changes(st5), false)
  eq(data.count_staged(st5), 0)
end)

-- ── effective_value() ───────────────────────────────────────────────────────

test("effective_value: returns original for unstaged", function()
  local st = make_state({})
  eq(data.effective_value(st, 1, "name"), "alice")
  eq(data.effective_value(st, 2, "name"), "bob")
end)

test("effective_value: empty string in original stays empty", function()
  -- In the CSV output from DB CLIs, empty string represents NULL.
  -- effective_value returns it as-is; view.lua handles display.
  local st = make_state({ rows = { { "1", "", "test@x.com" } } })
  eq(data.effective_value(st, 1, "name"), "", "empty string preserved from original")
end)

test("effective_value: staged overrides original", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "override")
  eq(data.effective_value(st2, 1, "name"), "override")
end)

-- ── row_status() ────────────────────────────────────────────────────────────

test("row_status: clean by default", function()
  local st = make_state({})
  eq(data.row_status(st, 1), "clean")
end)

test("row_status: modified after change", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "x")
  eq(data.row_status(st2, 1), "modified")
end)

test("row_status: deleted after toggle", function()
  local st = make_state({})
  local st2 = data.toggle_delete(st, 1)
  eq(data.row_status(st2, 1), "deleted")
end)

-- ── has_changes() / count_staged() ──────────────────────────────────────────

test("has_changes: false when no changes", function()
  local st = make_state({})
  eq(data.has_changes(st), false)
end)

test("has_changes: true after change", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "x")
  eq(data.has_changes(st2), true)
end)

test("count_staged: counts all types", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "x")
  local st3 = data.toggle_delete(st2, 2)
  local st4 = data.insert_row(st3, 2)
  eq(data.count_staged(st4), 3)
end)

-- ── get_updates / get_inserts / get_deletes ─────────────────────────────────

test("get_updates: returns changed rows with PK values", function()
  local st = make_state({})
  local st2 = data.add_change(st, 1, "name", "updated")
  local updates = data.get_updates(st2)
  eq(#updates, 1)
  eq(updates[1].pk_values.id, "1")
  eq(updates[1].changes.name, "updated")
end)

test("get_deletes: returns deleted rows with PK values", function()
  local st = make_state({})
  local st2 = data.toggle_delete(st, 2)
  local deletes = data.get_deletes(st2)
  eq(#deletes, 1)
  eq(deletes[1].pk_values.id, "2")
end)

test("get_inserts: returns inserted rows", function()
  local st = make_state({})
  local st2 = data.insert_row(st, 2)
  local ordered = data.get_ordered_rows(st2)
  local ins_idx = ordered[3]
  local st3 = data.add_change(st2, ins_idx, "name", "carol")
  local inserts = data.get_inserts(st3)
  eq(#inserts, 1)
  eq(inserts[1].values.name, "carol")
end)

-- ── get_ordered_rows() ──────────────────────────────────────────────────────

test("get_ordered_rows: returns original indices when no inserts", function()
  local st = make_state({})
  local ordered = data.get_ordered_rows(st)
  eq(#ordered, 2)
  eq(ordered[1], 1)
  eq(ordered[2], 2)
end)

test("get_ordered_rows: inserts are spliced after their _after idx", function()
  local st = make_state({})
  local st2 = data.insert_row(st, 1)
  local ordered = data.get_ordered_rows(st2)
  eq(#ordered, 3)
  eq(ordered[1], 1)
  eq(ordered[3], 2)
  -- The inserted row should be between 1 and 2
  assert(ordered[2] >= 1000, "insert idx should be >= 1000")
end)

-- ── clone_row() ─────────────────────────────────────────────────────────────

test("clone_row: non-PK values are copied", function()
  local st = make_state({})
  local st2 = data.clone_row(st, 1)
  local ordered = data.get_ordered_rows(st2)
  -- Find the new insert idx (it's not 1 or 2)
  local ins_idx
  for _, idx in ipairs(ordered) do
    if idx ~= 1 and idx ~= 2 then ins_idx = idx; break end
  end
  assert(ins_idx, "should have an inserted row")
  eq(data.effective_value(st2, ins_idx, "name"), "alice")
  eq(data.effective_value(st2, ins_idx, "email"), "alice@test.com")
end)

test("clone_row: PK values are nil in cloned row", function()
  local st = make_state({})
  local st2 = data.clone_row(st, 1)
  local ordered = data.get_ordered_rows(st2)
  local ins_idx
  for _, idx in ipairs(ordered) do
    if idx ~= 1 and idx ~= 2 then ins_idx = idx; break end
  end
  assert(ins_idx, "should have an inserted row")
  eq(data.effective_value(st2, ins_idx, "id"), nil, "PK should be nil so DB generates new ID")
end)

test("clone_row: NULL source values are not stored", function()
  local st = make_state({ rows = { { "1", "", "alice@test.com" } } })
  local st2 = data.clone_row(st, 1)
  local ordered = data.get_ordered_rows(st2)
  local ins_idx
  for _, idx in ipairs(ordered) do
    if idx ~= 1 then ins_idx = idx; break end
  end
  assert(ins_idx, "should have an inserted row")
  -- empty string in original = nil (NULL), should not be stored
  eq(data.effective_value(st2, ins_idx, "name"), nil, "NULL source value should stay nil in clone")
end)

test("clone_row: inserts after source row_idx", function()
  local st = make_state({})
  local st2 = data.clone_row(st, 1)
  local ordered = data.get_ordered_rows(st2)
  -- Row at position 2 should be the clone (spliced after row_idx=1)
  eq(ordered[1], 1, "first row is original row 1")
  assert(ordered[2] ~= 2, "clone should come before original row 2")
  eq(ordered[3], 2, "original row 2 should be last")
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\ndata_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
