-- filters_spec.lua -- unit tests for saved filter presets
local filters = require("dadbod-grip.filters")

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

-- ── mock helpers ────────────────────────────────────────────────────────────

-- Override M._read_all and M._write_all on the module to use in-memory store.
local mock_store = {}

local function setup_mock()
  mock_store = {}
  local orig_read = filters._read_all
  local orig_write = filters._write_all
  local orig_notify = vim.notify
  filters._read_all = function() return mock_store end
  filters._write_all = function(data) mock_store = data end
  vim.notify = function() end
  return function()
    filters._read_all = orig_read
    filters._write_all = orig_write
    vim.notify = orig_notify
  end
end

local function with_mock(fn)
  local teardown = setup_mock()
  local ok, err = pcall(fn)
  teardown()
  if not ok then error(err) end
end

-- ── list ────────────────────────────────────────────────────────────────────

test("list: returns empty for unknown table", function()
  with_mock(function()
    local result = filters.list("nonexistent")
    eq(#result, 0, "should be empty")
  end)
end)

test("list: returns presets for known table", function()
  with_mock(function()
    mock_store = {
      users = {
        { name = "active", clause = "status = 'active'" },
        { name = "old", clause = "age > 60" },
      }
    }
    local result = filters.list("users")
    eq(#result, 2, "should have 2 presets")
    eq(result[1].name, "active", "first name")
    eq(result[2].clause, "age > 60", "second clause")
  end)
end)

test("list: skips malformed entries", function()
  with_mock(function()
    mock_store = {
      users = {
        { name = "good", clause = "x = 1" },
        { name = "no-clause" },
        { clause = "no-name" },
        "not-a-table",
      }
    }
    local result = filters.list("users")
    eq(#result, 1, "should have 1 valid preset")
    eq(result[1].name, "good", "name")
  end)
end)

test("list: handles non-table value for table key", function()
  with_mock(function()
    mock_store = { users = "not-a-table" }
    local result = filters.list("users")
    eq(#result, 0, "should be empty for non-table value")
  end)
end)

-- ── save ────────────────────────────────────────────────────────────────────

test("save: creates new preset for table", function()
  with_mock(function()
    filters.save("users", "adults", "age >= 18")
    local result = filters.list("users")
    eq(#result, 1, "should have 1 preset")
    eq(result[1].name, "adults", "name")
    eq(result[1].clause, "age >= 18", "clause")
  end)
end)

test("save: appends to existing presets", function()
  with_mock(function()
    mock_store = {
      users = {{ name = "first", clause = "id = 1" }}
    }
    filters.save("users", "second", "id = 2")
    local result = filters.list("users")
    eq(#result, 2, "should have 2 presets")
    eq(result[2].name, "second", "appended name")
  end)
end)

test("save: overwrites preset with same name", function()
  with_mock(function()
    mock_store = {
      users = {{ name = "active", clause = "old clause" }}
    }
    filters.save("users", "active", "new clause")
    local result = filters.list("users")
    eq(#result, 1, "should still have 1 preset")
    eq(result[1].clause, "new clause", "clause should be updated")
  end)
end)

test("save: does not cross-pollinate tables", function()
  with_mock(function()
    filters.save("users", "preset_a", "x = 1")
    filters.save("orders", "preset_b", "y = 2")
    eq(#filters.list("users"), 1, "users has 1")
    eq(#filters.list("orders"), 1, "orders has 1")
    eq(filters.list("users")[1].name, "preset_a", "users preset")
    eq(filters.list("orders")[1].name, "preset_b", "orders preset")
  end)
end)

test("save: rejects empty table name", function()
  with_mock(function()
    filters.save("", "name", "clause")
    eq(#filters.list(""), 0, "should not save with empty table name")
  end)
end)

test("save: rejects nil table name", function()
  with_mock(function()
    filters.save(nil, "name", "clause")
    -- Should not crash, just notify
  end)
end)

test("save: rejects empty preset name", function()
  with_mock(function()
    filters.save("users", "", "clause")
    eq(#filters.list("users"), 0, "should not save with empty name")
  end)
end)

-- ── delete ──────────────────────────────────────────────────────────────────

test("delete: removes preset by name", function()
  with_mock(function()
    mock_store = {
      users = {
        { name = "keep", clause = "x = 1" },
        { name = "remove", clause = "y = 2" },
      }
    }
    filters.delete("users", "remove")
    local result = filters.list("users")
    eq(#result, 1, "should have 1 remaining")
    eq(result[1].name, "keep", "correct one kept")
  end)
end)

test("delete: removes table key when last preset deleted", function()
  with_mock(function()
    mock_store = {
      users = {{ name = "only", clause = "x = 1" }}
    }
    filters.delete("users", "only")
    eq(mock_store.users, nil, "table key should be nil")
  end)
end)

test("delete: no-op for nonexistent preset", function()
  with_mock(function()
    mock_store = {
      users = {{ name = "keep", clause = "x = 1" }}
    }
    filters.delete("users", "nonexistent")
    eq(#filters.list("users"), 1, "should still have 1")
  end)
end)

test("delete: no-op for nonexistent table", function()
  with_mock(function()
    filters.delete("nonexistent", "name")
    -- Should not crash
  end)
end)

-- ── compound clauses ────────────────────────────────────────────────────────

test("save: preserves compound AND clause", function()
  with_mock(function()
    local clause = "(age > 18) AND (status = 'active') AND (city = 'NYC')"
    filters.save("users", "complex", clause)
    local result = filters.list("users")
    eq(result[1].clause, clause, "compound clause preserved verbatim")
  end)
end)

test("save: preserves SQL with special characters", function()
  with_mock(function()
    local clause = "name LIKE '%O''Brien%'"
    filters.save("users", "special", clause)
    local result = filters.list("users")
    eq(result[1].clause, clause, "special chars preserved")
  end)
end)

-- ── edge cases ──────────────────────────────────────────────────────────────

test("save then delete then save: clean round-trip", function()
  with_mock(function()
    filters.save("users", "temp", "x = 1")
    eq(#filters.list("users"), 1, "after save")
    filters.delete("users", "temp")
    eq(#filters.list("users"), 0, "after delete")
    filters.save("users", "temp", "x = 2")
    eq(#filters.list("users"), 1, "after re-save")
    eq(filters.list("users")[1].clause, "x = 2", "new clause")
  end)
end)

test("list: returns independent copies (not references)", function()
  with_mock(function()
    filters.save("users", "test", "x = 1")
    local a = filters.list("users")
    local b = filters.list("users")
    a[1].name = "mutated"
    eq(b[1].name, "test", "second list should not be affected by mutation")
  end)
end)

test("save: multiple tables with many presets each", function()
  with_mock(function()
    for i = 1, 5 do
      filters.save("users", "preset_" .. i, "col = " .. i)
    end
    for i = 1, 3 do
      filters.save("orders", "order_" .. i, "id = " .. i)
    end
    eq(#filters.list("users"), 5, "users count")
    eq(#filters.list("orders"), 3, "orders count")
    eq(#filters.list("products"), 0, "products empty")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nfilters_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
