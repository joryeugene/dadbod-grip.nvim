-- diff_spec.lua -- unit tests for diff engine and renderers
local diff = require("dadbod-grip.diff")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. " — " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Build a minimal data state for testing.
local function make_state(columns, pks, rows)
  return { columns = columns, pks = pks, rows = rows }
end

-- ── compute ──────────────────────────────────────────────────────────────────

test("compute: matched rows with cell diffs", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"2", "Bob"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"2", "Robert"}})
  local result, err = diff.compute(left, right)
  assert(result, "should not error: " .. tostring(err))
  eq(#result.matched, 2, "two matched rows")
  eq(result.summary.changed, 1, "one changed")
  eq(result.summary.same, 1, "one same")
  -- Row 2 should have a name diff
  local row2 = result.matched[2]
  assert(row2.has_diffs, "row 2 has diffs")
  eq(row2.diffs["name"].left, "Bob", "left value")
  eq(row2.diffs["name"].right, "Robert", "right value")
end)

test("compute: left_only rows identified", function()
  local left  = make_state({"id", "val"}, {"id"}, {{"1", "a"}, {"2", "b"}})
  local right = make_state({"id", "val"}, {"id"}, {{"1", "a"}})
  local result = diff.compute(left, right)
  eq(#result.left_only, 1, "one left-only")
  eq(result.summary.deleted, 1, "one deleted")
end)

test("compute: right_only rows identified", function()
  local left  = make_state({"id", "val"}, {"id"}, {{"1", "a"}})
  local right = make_state({"id", "val"}, {"id"}, {{"1", "a"}, {"3", "c"}})
  local result = diff.compute(left, right)
  eq(#result.right_only, 1, "one right-only")
  eq(result.summary.added, 1, "one added")
end)

test("compute: identical datasets produce zero diffs", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"2", "Bob"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"2", "Bob"}})
  local result = diff.compute(left, right)
  eq(result.summary.changed, 0, "no changes")
  eq(result.summary.same, 2, "both same")
  eq(#result.left_only, 0, "no left-only")
  eq(#result.right_only, 0, "no right-only")
end)

test("compute: no PKs returns error", function()
  local left  = make_state({"id", "name"}, {}, {{"1", "Alice"}})
  local right = make_state({"id", "name"}, {}, {{"1", "Alice"}})
  local result, err = diff.compute(left, right)
  assert(result == nil, "should fail")
  contains(err, "primary key", "error mentions PKs")
end)

test("compute: composite PK matching works", function()
  local left  = make_state({"a", "b", "val"}, {"a", "b"}, {{"1", "x", "old"}, {"2", "y", "same"}})
  local right = make_state({"a", "b", "val"}, {"a", "b"}, {{"1", "x", "new"}, {"2", "y", "same"}})
  local result = diff.compute(left, right)
  eq(result.summary.changed, 1, "one changed")
  eq(result.summary.same, 1, "one same")
  eq(result.matched[1].diffs["val"].left, "old", "left val")
  eq(result.matched[1].diffs["val"].right, "new", "right val")
end)

-- ── render_compact ───────────────────────────────────────────────────────────

test("render_compact: changed row shows PK context + changed cols only", function()
  local left  = make_state({"id", "name", "email"}, {"id"}, {{"1", "Alice", "a@x.com"}})
  local right = make_state({"id", "name", "email"}, {"id"}, {{"1", "Alice", "a@new.com"}})
  local result = diff.compute(left, right)
  local lines = diff._render_compact(result, left, right, left.columns)
  -- Should have separator, id (PK context), email (changed), blank line
  local joined = table.concat(lines, "\n")
  contains(joined, "Row (changed)", "has changed header")
  contains(joined, "id", "shows PK column")
  contains(joined, "->", "shows arrow for changed value")
  -- name should NOT appear (unchanged, not a PK)
  local has_name = false
  for _, l in ipairs(lines) do
    if l:find("name") then has_name = true end
  end
  assert(not has_name, "unchanged non-PK column 'name' should be hidden")
end)

test("render_compact: shows old -> new format", function()
  local left  = make_state({"id", "status"}, {"id"}, {{"1", "active"}})
  local right = make_state({"id", "status"}, {"id"}, {{"1", "pending"}})
  local result = diff.compute(left, right)
  local lines = diff._render_compact(result, left, right, left.columns)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("pending") and l:find("->") and l:find("active") then
      found = true
    end
  end
  assert(found, "should show 'pending  ->  active' format")
end)

test("render_compact: deleted row shows all columns", function()
  local left  = make_state({"id", "name", "email"}, {"id"}, {{"1", "Alice", "a@x.com"}, {"2", "Bob", "b@x.com"}})
  local right = make_state({"id", "name", "email"}, {"id"}, {{"1", "Alice", "a@x.com"}})
  local result = diff.compute(left, right)
  local lines = diff._render_compact(result, left, right, left.columns)
  local joined = table.concat(lines, "\n")
  contains(joined, "Row (deleted)", "has deleted header")
  contains(joined, "Bob", "shows deleted name")
  contains(joined, "b@x.com", "shows deleted email")
end)

test("render_compact: added row shows all columns", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"3", "Charlie"}})
  local result = diff.compute(left, right)
  local lines = diff._render_compact(result, left, right, left.columns)
  local joined = table.concat(lines, "\n")
  contains(joined, "Row (added)", "has added header")
  contains(joined, "Charlie", "shows added name")
end)

test("render_compact: empty diff produces minimal output", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}})
  local result = diff.compute(left, right)
  local lines = diff._render_compact(result, left, right, left.columns)
  -- Should just have the "1 unchanged" summary line
  eq(#lines, 1, "minimal lines")
  contains(lines[1], "unchanged", "summary text")
end)

test("render_compact: highlight marks match expected count", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}, {"2", "Bob"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alicia"}, {"2", "Bob"}})
  local result = diff.compute(left, right)
  local lines, marks = diff._render_compact(result, left, right, left.columns)
  assert(#marks > 0, "should have highlight marks")
  -- Changed row: separator (1 mark) + changed col (1 mark) = at least 2
  local changed_marks = 0
  for _, m in ipairs(marks) do
    if m.hl == "GripDiffChanged" then changed_marks = changed_marks + 1 end
  end
  assert(changed_marks >= 1, "at least one GripDiffChanged mark")
end)

-- ── render_unified ───────────────────────────────────────────────────────────

test("render_unified: basic output has header and separator", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alicia"}})
  local result = diff.compute(left, right)
  local lines = diff._render_unified(result, left, right, left.columns, 200)
  assert(#lines >= 4, "header + separator + at least 2 data lines")
  contains(lines[1], "id", "header has column names")
  assert(lines[2]:find("%-%-"), "separator line has dashes")
end)

test("render_unified: changed row shows current and was labels", function()
  local left  = make_state({"id", "name"}, {"id"}, {{"1", "Alice"}})
  local right = make_state({"id", "name"}, {"id"}, {{"1", "Alicia"}})
  local result = diff.compute(left, right)
  local lines = diff._render_unified(result, left, right, left.columns, 200)
  local joined = table.concat(lines, "\n")
  contains(joined, "(current)", "shows current label")
  contains(joined, "(was)", "shows was label")
end)

-- ── adjust_widths ────────────────────────────────────────────────────────────

test("adjust_widths: no shrink when width is sufficient", function()
  local widths = { id = 6, name = 10, email = 15 }
  local columns = { "id", "name", "email" }
  diff._adjust_widths(widths, columns, 200)
  eq(widths.id, 6, "id unchanged")
  eq(widths.name, 10, "name unchanged")
  eq(widths.email, 15, "email unchanged")
end)

test("adjust_widths: shrinks columns proportionally", function()
  local widths = { id = 10, name = 30, email = 30 }
  local columns = { "id", "name", "email" }
  local orig_total = 10 + 30 + 30
  diff._adjust_widths(widths, columns, 50)
  local new_total = widths.id + widths.name + widths.email
  assert(new_total < orig_total, "total should decrease, got " .. new_total .. " vs " .. orig_total)
end)

test("adjust_widths: minimum 6 chars per column enforced", function()
  local widths = { id = 10, name = 30, email = 30 }
  local columns = { "id", "name", "email" }
  diff._adjust_widths(widths, columns, 20) -- very narrow
  assert(widths.id >= 6, "id at least 6, got " .. widths.id)
  assert(widths.name >= 6, "name at least 6, got " .. widths.name)
  assert(widths.email >= 6, "email at least 6, got " .. widths.email)
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\ndiff_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
