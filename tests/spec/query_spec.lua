-- query_spec.lua — unit tests for query.lua (pure query composition)
local query = require("dadbod-grip.query")

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

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

local function not_contains(s, pattern, msg)
  assert(not s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to NOT contain '" .. pattern .. "'")
end

-- ── constructors ────────────────────────────────────────────────────────────

test("new_table: creates table spec", function()
  local spec = query.new_table("users", 100)
  eq(spec.table_name, "users")
  eq(spec.is_raw, false)
  eq(spec.page, 1)
  eq(spec.page_size, 100)
  eq(#spec.sorts, 0)
  eq(#spec.filters, 0)
end)

test("new_raw: creates raw query spec", function()
  local spec = query.new_raw("SELECT * FROM orders", 50)
  eq(spec.base_sql, "SELECT * FROM orders")
  eq(spec.is_raw, true)
  eq(spec.page_size, 50)
end)

-- ── build_sql ───────────────────────────────────────────────────────────────

test("build_sql: table query", function()
  local spec = query.new_table("users", 100)
  local sql = query.build_sql(spec)
  contains(sql, 'SELECT * FROM "users"')
  contains(sql, "LIMIT 100")
  not_contains(sql, "OFFSET")
end)

test("build_sql: raw query wraps in subquery", function()
  local spec = query.new_raw("SELECT * FROM orders", 100)
  local sql = query.build_sql(spec)
  contains(sql, "SELECT * FROM orders")
  contains(sql, "_grip")
end)

test("build_sql: page 2 has OFFSET", function()
  local spec = query.new_table("users", 100)
  spec = query.set_page(spec, 2)
  local sql = query.build_sql(spec)
  contains(sql, "OFFSET 100")
end)

test("build_sql: page 3 has correct offset", function()
  local spec = query.new_table("users", 50)
  spec = query.set_page(spec, 3)
  local sql = query.build_sql(spec)
  contains(sql, "OFFSET 100")  -- (3-1) * 50 = 100
end)

-- ── sort modifiers ──────────────────────────────────────────────────────────

test("toggle_sort: first toggle adds ASC", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  local sql = query.build_sql(spec2)
  contains(sql, 'ORDER BY "name" ASC')
end)

test("toggle_sort: second toggle changes to DESC", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  local spec3 = query.toggle_sort(spec2, "name")
  local sql = query.build_sql(spec3)
  contains(sql, 'ORDER BY "name" DESC')
end)

test("toggle_sort: third toggle removes sort", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  local spec3 = query.toggle_sort(spec2, "name")
  local spec4 = query.toggle_sort(spec3, "name")
  local sql = query.build_sql(spec4)
  not_contains(sql, "ORDER BY")
end)

test("toggle_sort: replaces previous sort column", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  local spec3 = query.toggle_sort(spec2, "email")
  local sql = query.build_sql(spec3)
  contains(sql, '"email" ASC')
  not_contains(sql, '"name"')
end)

test("toggle_sort: resets page to 1", function()
  local spec = query.new_table("users", 100)
  spec = query.set_page(spec, 5)
  local spec2 = query.toggle_sort(spec, "name")
  eq(spec2.page, 1)
end)

test("add_sort: stacks secondary sort", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  local spec3 = query.add_sort(spec2, "email")
  local sql = query.build_sql(spec3)
  contains(sql, '"name" ASC')
  contains(sql, '"email" ASC')
end)

test("get_sort_indicator: returns arrow", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.toggle_sort(spec, "name")
  -- Cast to string for comparison since it returns a utf8 arrow
  local indicator = query.get_sort_indicator(spec2, "name")
  assert(indicator ~= nil, "should have indicator")
end)

test("get_sort_indicator: nil for unsorted column", function()
  local spec = query.new_table("users", 100)
  eq(query.get_sort_indicator(spec, "name"), nil)
end)

-- ── filter modifiers ────────────────────────────────────────────────────────

test("add_filter: adds WHERE clause", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "name = 'alice'")
  local sql = query.build_sql(spec2)
  contains(sql, "WHERE (name = 'alice')")
end)

test("add_filter: multiple filters are AND-ed", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "name = 'alice'")
  local spec3 = query.add_filter(spec2, "age > 20")
  local sql = query.build_sql(spec3)
  contains(sql, "AND")
end)

test("quick_filter: generates column = value", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.quick_filter(spec, "name", "alice")
  local sql = query.build_sql(spec2)
  contains(sql, '"name" = \'alice\'')
end)

test("quick_filter: nil value generates IS NULL", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.quick_filter(spec, "name", nil)
  local sql = query.build_sql(spec2)
  contains(sql, '"name" IS NULL')
end)

test("clear_filters: removes all filters", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "name = 'alice'")
  local spec3 = query.clear_filters(spec2)
  local sql = query.build_sql(spec3)
  not_contains(sql, "WHERE")
end)

test("has_filters: false when no filters", function()
  local spec = query.new_table("users", 100)
  eq(query.has_filters(spec), false)
end)

test("has_filters: true after filter", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "x = 1")
  eq(query.has_filters(spec2), true)
end)

test("filter_summary: empty when no filters", function()
  local spec = query.new_table("users", 100)
  eq(query.filter_summary(spec), "")
end)

test("filter_summary: shows clause for single filter", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "age > 20")
  eq(query.filter_summary(spec2), "filter: age > 20")
end)

test("filter_summary: shows count for multiple filters", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "a = 1")
  local spec3 = query.add_filter(spec2, "b = 2")
  eq(query.filter_summary(spec3), "2 filters")
end)

-- ── pagination modifiers ────────────────────────────────────────────────────

test("set_page: clamps to minimum 1", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.set_page(spec, 0)
  eq(spec2.page, 1)
end)

test("next_page: increments", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.next_page(spec)
  eq(spec2.page, 2)
end)

test("prev_page: decrements", function()
  local spec = query.new_table("users", 100)
  spec = query.set_page(spec, 3)
  local spec2 = query.prev_page(spec)
  eq(spec2.page, 2)
end)

test("prev_page: clamps at 1", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.prev_page(spec)
  eq(spec2.page, 1)
end)

test("page_info: without total", function()
  local spec = query.new_table("users", 100)
  eq(query.page_info(spec), "Page 1")
end)

test("page_info: with total", function()
  local spec = query.new_table("users", 100)
  local info = query.page_info(spec, 250)
  contains(info, "Page 1/3")
  contains(info, "250 rows")
end)

-- ── reset ───────────────────────────────────────────────────────────────────

test("reset: clears sorts, filters, resets page", function()
  local spec = query.new_table("users", 100)
  spec = query.toggle_sort(spec, "name")
  spec = query.add_filter(spec, "x = 1")
  spec = query.set_page(spec, 5)
  local spec2 = query.reset(spec)
  eq(#spec2.sorts, 0)
  eq(#spec2.filters, 0)
  eq(spec2.page, 1)
end)

-- ── immutability ────────────────────────────────────────────────────────────

test("immutability: toggle_sort does not mutate original", function()
  local spec = query.new_table("users", 100)
  local _ = query.toggle_sort(spec, "name")
  eq(#spec.sorts, 0, "original should have 0 sorts")
end)

test("immutability: add_filter does not mutate original", function()
  local spec = query.new_table("users", 100)
  local _ = query.add_filter(spec, "x = 1")
  eq(#spec.filters, 0, "original should have 0 filters")
end)

test("immutability: set_page does not mutate original", function()
  local spec = query.new_table("users", 100)
  local _ = query.set_page(spec, 5)
  eq(spec.page, 1, "original should stay on page 1")
end)

-- ── build_count_sql ─────────────────────────────────────────────────────────

test("build_count_sql: table query", function()
  local spec = query.new_table("users", 100)
  local sql = query.build_count_sql(spec)
  contains(sql, "SELECT COUNT(*)")
  contains(sql, '"users"')
end)

test("build_count_sql: with filters", function()
  local spec = query.new_table("users", 100)
  spec = query.add_filter(spec, "active = true")
  local sql = query.build_count_sql(spec)
  contains(sql, "WHERE")
  contains(sql, "active = true")
end)

test("build_count_sql: no LIMIT or OFFSET", function()
  local spec = query.new_table("users", 100)
  spec = query.set_page(spec, 3)
  local sql = query.build_count_sql(spec)
  not_contains(sql, "LIMIT")
  not_contains(sql, "OFFSET")
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\nquery_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
