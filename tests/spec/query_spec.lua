-- query_spec.lua: unit tests for query.lua (pure query composition)
local query = require("dadbod-grip.query")

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

test("filter_summary: shows all clauses for multiple filters", function()
  local spec = query.new_table("users", 100)
  local spec2 = query.add_filter(spec, "a = 1")
  local spec3 = query.add_filter(spec2, "b = 2")
  local summary = query.filter_summary(spec3)
  assert(summary:find("a = 1", 1, true), "expected 'a = 1' in: " .. summary)
  assert(summary:find("b = 2", 1, true), "expected 'b = 2' in: " .. summary)
  assert(summary:find("filters:", 1, true), "expected 'filters:' prefix in: " .. summary)
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

-- ── set_filters (for filter presets) ─────────────────────────────────────────

test("set_filters: replaces all existing filters with single clause", function()
  local spec = query.new_table("users", 100)
  spec = query.add_filter(spec, "a = 1")
  spec = query.add_filter(spec, "b = 2")
  local spec2 = query.set_filters(spec, "status = 'active'")
  eq(#spec2.filters, 1, "should have exactly 1 filter")
  eq(spec2.filters[1].clause, "status = 'active'", "clause")
end)

test("set_filters: resets page to 1", function()
  local spec = query.new_table("users", 100)
  spec = query.set_page(spec, 5)
  local spec2 = query.set_filters(spec, "x > 10")
  eq(spec2.page, 1, "page should be 1")
end)

test("set_filters: does not mutate original", function()
  local spec = query.new_table("users", 100)
  spec = query.add_filter(spec, "old = true")
  local _ = query.set_filters(spec, "new = true")
  eq(#spec.filters, 1, "original should still have 1 filter")
  eq(spec.filters[1].clause, "old = true", "original clause unchanged")
end)

test("set_filters: compound clause preserved verbatim", function()
  local spec = query.new_table("users", 100)
  local clause = "(age > 18) AND (status = 'active')"
  local spec2 = query.set_filters(spec, clause)
  eq(spec2.filters[1].clause, clause, "compound clause preserved")
end)

test("set_filters: SQL builds correctly with preset filter", function()
  local spec = query.new_table("orders", 100)
  local spec2 = query.set_filters(spec, "total > 1000")
  local sql = query.build_sql(spec2)
  contains(sql, "WHERE (total > 1000)", "WHERE clause")
  contains(sql, '"orders"', "table name")
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

-- ── build_filter_clause ─────────────────────────────────────────────────────

test("build_filter_clause: = quotes string value", function()
  local clause = query.build_filter_clause("name", "=", "alice")
  eq(clause, '"name" = \'alice\'')
end)

test("build_filter_clause: = passes numeric value raw", function()
  local clause = query.build_filter_clause("age", "=", "42")
  eq(clause, '"age" = 42')
end)

test("build_filter_clause: LIKE auto-wraps value with % when no % present", function()
  local clause = query.build_filter_clause("sku", "LIKE", "ROLL")
  eq(clause, '"sku" LIKE \'%ROLL%\'')
end)

test("build_filter_clause: LIKE respects explicit % prefix", function()
  local clause = query.build_filter_clause("sku", "LIKE", "%ROLL")
  eq(clause, '"sku" LIKE \'%ROLL\'')
end)

test("build_filter_clause: LIKE respects explicit % suffix", function()
  local clause = query.build_filter_clause("sku", "LIKE", "ROLL%")
  eq(clause, '"sku" LIKE \'ROLL%\'')
end)

test("build_filter_clause: LIKE respects internal % wildcard", function()
  local clause = query.build_filter_clause("sku", "LIKE", "R%L")
  eq(clause, '"sku" LIKE \'R%L\'')
end)

test("build_filter_clause: IN parses comma list", function()
  local clause = query.build_filter_clause("status", "IN", "a,b,c")
  eq(clause, '"status" IN (\'a\',\'b\',\'c\')')
end)

test("build_filter_clause: IN trims whitespace around items", function()
  local clause = query.build_filter_clause("id", "IN", "1, 2, 3")
  eq(clause, '"id" IN (1,2,3)')
end)

test("build_filter_clause: BETWEEN numeric range", function()
  local clause = query.build_filter_clause("price", "BETWEEN", "10,100")
  eq(clause, '"price" BETWEEN 10 AND 100')
end)

test("build_filter_clause: BETWEEN string/date range", function()
  local clause = query.build_filter_clause("created_at", "BETWEEN", "2024-01-01,2024-12-31")
  eq(clause, '"created_at" BETWEEN \'2024-01-01\' AND \'2024-12-31\'')
end)

test("build_filter_clause: BETWEEN trims whitespace", function()
  local clause = query.build_filter_clause("score", "BETWEEN", "0 , 100")
  eq(clause, '"score" BETWEEN 0 AND 100')
end)

test("build_filter_clause: BETWEEN errors on wrong part count", function()
  local ok, err = pcall(query.build_filter_clause, "x", "BETWEEN", "only_one")
  assert(not ok, "should error")
  assert(err:find("two values"), "error should mention two values: " .. tostring(err))
end)

test("build_filter_clause: NULL generates IS NULL", function()
  local clause = query.build_filter_clause("col", "NULL", nil)
  eq(clause, '"col" IS NULL')
end)

test("build_filter_clause: NOT NULL generates IS NOT NULL", function()
  local clause = query.build_filter_clause("col", "NOT NULL", nil)
  eq(clause, '"col" IS NOT NULL')
end)

test("filter_summary: long clauses not truncated", function()
  local spec = query.new_table("users", 100)
  local long_clause = '"some_very_long_column_name" LIKE \'%a_very_long_search_value%\''
  local spec2 = query.add_filter(spec, long_clause)
  local spec3 = query.add_filter(spec2, "another = 1")
  local summary = query.filter_summary(spec3)
  -- Must contain the full clause without any "..." truncation
  assert(summary:find(long_clause, 1, true), "long clause must appear in full: " .. summary)
  assert(not summary:find("...", 1, true), "must not truncate with '...': " .. summary)
end)

-- ── clean_sql ────────────────────────────────────────────────────────────────
-- The pad-prefill SQL must quote the table name exactly like build_sql does, or
-- running the generated query fails on case-sensitive/reserved-word tables:
-- Postgres folds an unquoted `Organization` to `organization` (relation not found).

test("clean_sql: table query quotes the identifier", function()
  local spec = query.new_table("Organization", 100)
  eq(query.clean_sql(spec), 'SELECT * FROM "Organization"')
end)

test("clean_sql: quotes a schema-qualified table per part", function()
  local spec = query.new_table("public.Organization", 100)
  eq(query.clean_sql(spec), 'SELECT * FROM "public"."Organization"')
end)

test("clean_sql: matches build_sql's FROM clause", function()
  local spec = query.new_table("Organization", 100)
  contains(query.build_sql(spec), query.clean_sql(spec),
    "build_sql must start from the same quoted FROM the pad shows")
end)

test("clean_sql: raw query returns base_sql verbatim", function()
  local spec = query.new_raw("SELECT * FROM whatever", 100)
  eq(query.clean_sql(spec), "SELECT * FROM whatever")
end)

-- ── pinned filters (FK navigation context) ──────────────────────────────────
-- FK navigation (gf/gm) replaces the grid's spec with one carrying a WHERE that
-- IS the identity of the new grid ("the CategoryVersion rows referencing Category
-- 15"), not a view modifier the user applied. Such a filter is pinned:
--   • F (clear filters) and X (reset view) must not drop it — otherwise the grid
--     silently widens to the whole table while the breadcrumb still claims an FK
--     context, and <C-o> pops back into a state that never existed;
--   • the [filtered] badge and gP (save preset) must ignore it — the user did not
--     filter anything, and the FK clause has no business in a saved preset;
--   • build_sql/build_count_sql must still apply it — it is a real WHERE.

test("add_filter: filters are unpinned by default", function()
  local spec = query.add_filter(query.new_table("t", 100), "a = 1")
  eq(spec.filters[1].pinned, nil)
end)

test("add_filter: pinned option marks the filter", function()
  local spec = query.add_filter(query.new_table("t", 100), "a = 1", { pinned = true })
  eq(spec.filters[1].pinned, true)
  eq(spec.filters[1].clause, "a = 1")
end)

test("clear_filters: keeps pinned filters, drops user filters", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  local cleared = query.clear_filters(spec)
  eq(#cleared.filters, 1, "only the pinned filter survives")
  eq(cleared.filters[1].clause, "fk = 15")
  eq(cleared.filters[1].pinned, true, "stays pinned after clearing")
end)

test("clear_filters: still drops everything when nothing is pinned", function()
  local spec = query.add_filter(query.new_table("t", 100), "name = 'x'")
  eq(#query.clear_filters(spec).filters, 0)
end)

test("reset: keeps pinned filters", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  spec = query.toggle_sort(spec, "id")
  spec = query.set_page(spec, 3)
  local r = query.reset(spec)
  eq(#r.filters, 1, "pinned FK context survives a view reset")
  eq(r.filters[1].clause, "fk = 15")
  eq(#r.sorts, 0, "sorts still cleared")
  eq(r.page, 1, "page still reset")
end)

test("set_filters: preset replaces user filters but keeps pinned", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  local loaded = query.set_filters(spec, "age > 30")
  eq(#loaded.filters, 2, "pinned + preset clause")
  eq(loaded.filters[1].clause, "fk = 15", "pinned filter comes first")
  eq(loaded.filters[1].pinned, true)
  eq(loaded.filters[2].clause, "age > 30", "preset clause replaces the user filter")
  eq(loaded.filters[2].pinned, nil, "a preset is a user filter")
end)

test("has_filters: false when only pinned filters exist", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  eq(query.has_filters(spec), false, "FK context is not a user filter")
end)

test("has_filters: true when a user filter joins a pinned one", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  eq(query.has_filters(spec), true)
end)

test("user_filters: returns only the unpinned filters", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  spec = query.add_filter(spec, "age > 30")
  local uf = query.user_filters(spec)
  eq(#uf, 2)
  eq(uf[1].clause, "name = 'x'")
  eq(uf[2].clause, "age > 30")
end)

test("user_filters: empty list when every filter is pinned", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  eq(#query.user_filters(spec), 0)
end)

test("build_sql: ANDs pinned and user filters together", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  spec = query.add_filter(spec, "name = 'x'")
  eq(query.build_sql(spec),
    'SELECT * FROM "t" WHERE (fk = 15) AND (name = \'x\') LIMIT 100')
end)

test("build_count_sql: includes pinned filters", function()
  local spec = query.add_filter(query.new_table("t", 100), "fk = 15", { pinned = true })
  contains(query.build_count_sql(spec), "(fk = 15)",
    "the pagination count must be scoped to the FK context")
end)

test("clean_sql: includes a pinned filter as WHERE", function()
  local spec = query.add_filter(query.new_table("CategoryVersion", 100),
    '"categoryId" = 15', { pinned = true })
  eq(query.clean_sql(spec),
    'SELECT * FROM "CategoryVersion" WHERE ("categoryId" = 15)')
end)

test("clean_sql: ANDs multiple pinned filters", function()
  local spec = query.add_filter(query.new_table("t", 100), "a = 1", { pinned = true })
  spec = query.add_filter(spec, "b = 2", { pinned = true })
  eq(query.clean_sql(spec), 'SELECT * FROM "t" WHERE (a = 1) AND (b = 2)')
end)

test("clean_sql: omits user filters, sorts and pagination", function()
  local spec = query.add_filter(query.new_table("t", 100), "name = 'x'")
  spec = query.toggle_sort(spec, "id")
  spec = query.set_page(spec, 4)
  eq(query.clean_sql(spec), 'SELECT * FROM "t"',
    "the pad shows the query you opened, not transient view state")
end)

test("clean_sql: raw spec returns base_sql even with a pinned filter", function()
  local spec = query.add_filter(query.new_raw("SELECT 1", 100), "a = 1", { pinned = true })
  eq(query.clean_sql(spec), "SELECT 1",
    "raw specs are user-authored text: never rewritten")
end)

test("clean_sql: pinned output is runnable as-is (matches build_sql prefix)", function()
  local spec = query.add_filter(query.new_table("Organization", 100),
    '"id" = 7', { pinned = true })
  contains(query.build_sql(spec), query.clean_sql(spec),
    "build_sql must extend exactly what the pad shows")
end)

test("immutability: add_filter with pinned does not mutate original", function()
  local spec = query.new_table("t", 100)
  query.add_filter(spec, "a = 1", { pinned = true })
  eq(#spec.filters, 0)
end)

-- ── summary ─────────────────────────────────────────────────────────────────
print(string.format("\nquery_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
