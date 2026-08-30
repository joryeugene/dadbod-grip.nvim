-- fk_reverse_spec.lua: reverse foreign-key navigation (grid_fk_referencing).
-- From a row, jump to the rows in other tables that reference it.
-- Uses tests/seed_sqlite.db fixtures: users ← orders ← order_items, products ← order_items.

local db    = require("dadbod-grip.db")
local data  = require("dadbod-grip.data")
local qmod  = require("dadbod-grip.query")
local view  = require("dadbod-grip.view")

local url = "sqlite:tests/seed_sqlite.db"

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(type(s) == "string" and s:find(pattern, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

--- Find a ref entry by child table name in a get_referencing_foreign_keys result.
local function find_ref(refs, child_table)
  for _, r in ipairs(refs or {}) do
    if r.table == child_table then return r end
  end
  return nil
end

-- ── grid helpers (mirror mutation_spec setup style) ───────────────────────

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

--- Open a real grid for a table (same result shape init.lua builds).
local function open_grid(tbl)
  local spec = qmod.new_table(tbl, 100)
  local sql_str = qmod.build_sql(spec)
  local result, err = db.query(sql_str, url)
  assert(result, "query failed for " .. tbl .. ": " .. tostring(err))
  result.primary_keys = db.get_primary_keys(tbl, url) or {}
  result.table_name = tbl
  result.url = url
  result.sql = sql_str
  local state = data.new(result)
  local bufnr = view.open(state, url, sql_str)
  view._sessions[bufnr].query_spec = spec
  return bufnr
end

--- Put the cursor on a given data row (1-based render order) and column.
local function cursor_to(bufnr, row_order, col_name)
  local r = view._sessions[bufnr]._render
  local line = (r.data_start or 4) + row_order - 1
  local bp = r.byte_positions[row_order][col_name]
  assert(bp, "no byte position for column " .. col_name)
  vim.api.nvim_win_set_cursor(0, { line, bp.start })
end

--- Run fn with vim.notify captured; returns list of messages.
local function with_notify(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, _) table.insert(msgs, tostring(m)) end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then error(err) end
  return msgs
end

-- ── reverse FK map computation (db layer) ─────────────────────────────────

test("reverse map: users is referenced by orders.user_id", function()
  local refs, err = db.get_referencing_foreign_keys("users", url)
  assert(refs, "refs nil: " .. tostring(err))
  eq(#refs, 1, "one referencing FK")
  eq(refs[1].table, "orders", "child table")
  eq(refs[1].column, "user_id", "child column")
  eq(refs[1].ref_column, "id", "referenced column")
  assert(not refs[1].composite, "not composite")
end)

test("reverse map: orders is referenced by order_items.order_id", function()
  local refs = db.get_referencing_foreign_keys("orders", url)
  local r = find_ref(refs, "order_items")
  truthy(r, "order_items entry")
  eq(r.column, "order_id", "child column")
  eq(r.ref_column, "id", "referenced column")
end)

test("reverse map: products is referenced by order_items.product_id", function()
  local refs = db.get_referencing_foreign_keys("products", url)
  local r = find_ref(refs, "order_items")
  truthy(r, "order_items entry")
  eq(r.column, "product_id", "child column")
end)

test("reverse map: unreferenced table yields empty list", function()
  local refs, err = db.get_referencing_foreign_keys("long_values", url)
  assert(refs, "refs nil: " .. tostring(err))
  eq(#refs, 0, "no referencing FKs")
  eq(err, nil, "no error")
end)

test("generic fallback: list_tables + get_foreign_keys scan finds referencing tables", function()
  -- Simulate an adapter without a native reverse query (e.g. sqlserver)
  -- by hiding sqlite's dedicated implementation.
  local sqlite_adapter = require("dadbod-grip.adapters.sqlite")
  local native = sqlite_adapter.get_referencing_foreign_keys
  sqlite_adapter.get_referencing_foreign_keys = nil
  local ok, err = pcall(function()
    local refs = db.get_referencing_foreign_keys("users", url)
    local r = find_ref(refs, "orders")
    truthy(r, "fallback found orders")
    eq(r.column, "user_id", "fallback child column")
    eq(r.ref_column, "id", "fallback referenced column")
  end)
  sqlite_adapter.get_referencing_foreign_keys = native
  assert(ok, tostring(err))
end)

-- ── adapter SQL generation (no live DB; vim.system mocked) ───────────────

local function capture_system(stdout, fn)
  local captured
  local orig = vim.system
  vim.system = function(args, opts, cb)
    captured = args
    captured._stdin = opts and opts.stdin
    local r = { stdout = stdout or "", stderr = "", code = 0 }
    if cb then cb(r) else return { wait = function() return r end } end
  end
  local ok, err = pcall(fn)
  vim.system = orig
  if not ok then error(err) end
  return captured
end

test("postgres: reverse FK SQL filters on referenced table in one query", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local stdout = "child_schema,child_table,fk_column,ref_column,constraint_name\n"
    .. "public,orders,user_id,id,orders_user_id_fkey\n"
  local args = capture_system(stdout, function()
    local refs, err = pg.get_referencing_foreign_keys("users", "postgresql://localhost/testdb")
    assert(refs and not err, "refs: " .. tostring(err))
    eq(#refs, 1, "one ref")
    eq(refs[1].table, "orders", "child table")
    eq(refs[1].column, "user_id", "child column")
    eq(refs[1].ref_column, "id", "referenced column")
  end)
  truthy(args, "psql invoked")
  local sql_arg = args._stdin
  contains(sql_arg, "FOREIGN KEY", "constraint type filter")
  contains(sql_arg, "ccu.table_name = 'users'", "filters on referenced table")
  contains(sql_arg, "ccu.table_schema = 'public'", "filters on referenced schema")
end)

test("postgres: composite reverse FK is grouped and flagged", function()
  local pg = require("dadbod-grip.adapters.postgresql")
  local stdout = "child_schema,child_table,fk_column,ref_column,constraint_name\n"
    .. "public,child,a,x,child_composite_fkey\n"
    .. "public,child,b,y,child_composite_fkey\n"
    .. "public,other,c,x,other_c_fkey\n"
  capture_system(stdout, function()
    local refs = pg.get_referencing_foreign_keys("parent", "postgresql://localhost/testdb")
    eq(#refs, 2, "two constraints")
    local comp = find_ref(refs, "child")
    truthy(comp, "composite entry present")
    eq(comp.composite, true, "flagged composite")
    contains(comp.column, "a", "composite lists first column")
    contains(comp.column, "b", "composite lists second column")
    local single = find_ref(refs, "other")
    truthy(single, "single entry present")
    assert(not single.composite, "single-column FK not flagged")
  end)
end)

test("mysql: reverse FK SQL filters on REFERENCED_TABLE_NAME", function()
  local mysql = require("dadbod-grip.adapters.mysql")
  local stdout = "child_table\tfk_column\tref_column\tconstraint_name\n"
    .. "orders\tuser_id\tid\torders_ibfk_1\n"
  local args = capture_system(stdout, function()
    local refs, err = mysql.get_referencing_foreign_keys("users", "mysql://root@localhost/testdb")
    assert(refs and not err, "refs: " .. tostring(err))
    eq(#refs, 1, "one ref")
    eq(refs[1].table, "orders", "child table")
    eq(refs[1].column, "user_id", "child column")
  end)
  truthy(args, "mysql invoked")
  local sql_arg = args._stdin
  contains(sql_arg, "REFERENCED_TABLE_NAME = 'users'", "filters on referenced table")
end)

-- ── view: session cache ───────────────────────────────────────────────────

test("reverse map is cached on the session (one db scan per table)", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local calls = 0
  local orig = db.get_referencing_foreign_keys
  db.get_referencing_foreign_keys = function(...)
    calls = calls + 1
    return orig(...)
  end
  cursor_to(bufnr, 1, "id")
  with_notify(function() view._fk_referencing(bufnr) end)
  local session = view._sessions[bufnr]
  truthy(session.rev_fk_cache and session.rev_fk_cache["users"], "cache populated")
  eq(calls, 1, "db scanned once on first use")
  -- Back to users, trigger again: cache hit, no second scan.
  session.query_spec = session.nav_stack[1].query_spec
  view.render(bufnr, session.nav_stack[1].state)
  session.nav_stack = {}
  cursor_to(bufnr, 1, "id")
  with_notify(function() view._fk_referencing(bufnr) end)
  eq(calls, 1, "cached: no re-scan for the same table")
  db.get_referencing_foreign_keys = orig
  cleanup_grids()
end)

-- ── view: single-referencing-table jump ───────────────────────────────────

test("single referencing table: direct jump users → orders", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "id")  -- row 1 = Alice, id 1
  local msgs = with_notify(function() view._fk_referencing(bufnr) end)

  local session = view._sessions[bufnr]
  eq(session.state.table_name, "orders", "grid now shows orders")
  eq(#session.state.rows, 10, "10 orders for user 1")
  truthy(session.query_spec and #session.query_spec.filters == 1, "one filter")
  eq(session.query_spec.filters[1].clause, [["user_id" = '1']], "filtered by FK column")
  -- notify mirrors forward style, reversed arrow
  local found
  for _, m in ipairs(msgs) do
    if m:find("orders.user_id", 1, true) and m:find("←", 1, true) and m:find("users", 1, true) then
      found = m
    end
  end
  truthy(found, "notify 'orders.user_id ← users'")
  -- nav stack: can go back
  truthy(session.nav_stack and #session.nav_stack == 1, "nav stack pushed")
  eq(session.nav_stack[1].table_name, "users", "frame records source table")
  cleanup_grids()
end)

test("PK fallback: cursor on non-referenced column still jumps via row PK", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 2, "name")  -- row 2 = Bob, id 2; name is not referenced
  with_notify(function() view._fk_referencing(bufnr) end)
  local session = view._sessions[bufnr]
  eq(session.state.table_name, "orders", "jumped to orders")
  eq(session.query_spec.filters[1].clause, [["user_id" = '2']], "used row PK value")
  cleanup_grids()
end)

-- ── view: chain hop users → orders → order_items ─────────────────────────

test("chain hop: users → orders → order_items", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "id")
  with_notify(function() view._fk_referencing(bufnr) end)
  local session = view._sessions[bufnr]
  eq(session.state.table_name, "orders", "first hop")

  cursor_to(bufnr, 1, "id")  -- first order of user 1 is order id 1
  with_notify(function() view._fk_referencing(bufnr) end)
  eq(session.state.table_name, "order_items", "second hop")
  eq(#session.state.rows, 2, "order 1 has 2 items")
  eq(session.query_spec.filters[1].clause, [["order_id" = '1']], "filtered by order FK")
  eq(#session.nav_stack, 2, "two nav frames")
  cleanup_grids()
end)

-- ── view: no referencing tables ───────────────────────────────────────────

test("no referencing tables: notify and keep grid unchanged", function()
  cleanup_grids()
  local bufnr = open_grid("order_items")
  cursor_to(bufnr, 1, "id")
  local msgs = with_notify(function() view._fk_referencing(bufnr) end)
  local session = view._sessions[bufnr]
  eq(session.state.table_name, "order_items", "grid unchanged")
  assert(not session.nav_stack or #session.nav_stack == 0, "no nav frame pushed")
  local found
  for _, m in ipairs(msgs) do
    if m:find("No tables reference order_items", 1, true) then found = m end
  end
  truthy(found, "notified 'No tables reference order_items'")
  cleanup_grids()
end)

-- ── view: multiple referencing tables → picker ────────────────────────────

test("multiple referencing tables: picker lists child.fk_column entries", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local session = view._sessions[bufnr]
  -- Two children referencing users.id (second is synthetic but points at real data)
  session.rev_fk_cache = {
    users = {
      { table = "orders", column = "user_id", ref_column = "id" },
      { table = "order_items", column = "order_id", ref_column = "id" },
    },
  }
  local grip_picker = require("dadbod-grip.grip_picker")
  local orig_pick = grip_picker.pick
  local picked_opts
  grip_picker.pick = function(opts)
    picked_opts = opts
    opts.on_select(opts.items[1])  -- choose orders.user_id
  end
  cursor_to(bufnr, 1, "id")
  local ok, err = pcall(function()
    with_notify(function() view._fk_referencing(bufnr) end)
  end)
  grip_picker.pick = orig_pick
  assert(ok, tostring(err))

  truthy(picked_opts, "picker invoked")
  eq(#picked_opts.items, 2, "two candidates")
  contains(picked_opts.display(picked_opts.items[1]), "orders.user_id", "display child.fk_column")
  eq(session.state.table_name, "orders", "selection opened orders")
  cleanup_grids()
end)

-- ── view: composite FK and NULL edges ─────────────────────────────────────

test("composite referencing FK: clear notify, no jump", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local session = view._sessions[bufnr]
  session.rev_fk_cache = {
    users = {
      { table = "composite_pk", column = "tenant_id,user_id", ref_column = "id", composite = true },
    },
  }
  cursor_to(bufnr, 1, "id")
  local msgs = with_notify(function() view._fk_referencing(bufnr) end)
  eq(session.state.table_name, "users", "grid unchanged")
  local found
  for _, m in ipairs(msgs) do
    if m:lower():find("composite", 1, true) then found = m end
  end
  truthy(found, "notified about composite FK")
  cleanup_grids()
end)

test("NULL referenced value: clear notify, no jump", function()
  cleanup_grids()
  local bufnr = open_grid("users")
  local session = view._sessions[bufnr]
  -- Pretend email is a referenced column; row 4 (Diana) has NULL email.
  session.rev_fk_cache = {
    users = { { table = "orders", column = "user_id", ref_column = "email" } },
  }
  cursor_to(bufnr, 4, "email")
  local msgs = with_notify(function() view._fk_referencing(bufnr) end)
  eq(session.state.table_name, "users", "grid unchanged")
  local found
  for _, m in ipairs(msgs) do
    if m:find("NULL", 1, true) then found = m end
  end
  truthy(found, "notified about NULL value")
  cleanup_grids()
end)

-- ── keymap + palette registration ─────────────────────────────────────────

test("grid_fk_referencing has a default key", function()
  local km = require("dadbod-grip.keymaps")
  truthy(km.defaults.grid_fk_referencing, "default key exists")
  -- Must not collide with another grid/shared default
  local key = km.defaults.grid_fk_referencing
  for action, k in pairs(km.defaults) do
    if action ~= "grid_fk_referencing" and not action:match("^sidebar_")
      and not action:match("^qpad_") and not action:match("^grid_v_") then
      assert(k ~= key, "key '" .. tostring(key) .. "' collides with " .. action)
    end
  end
end)

test("grid_fk_referencing does not shadow Neovim's gr LSP prefix", function()
  -- Neovim 0.11+ ships global default keymaps grn/gra/grr/gri/grt/grx
  -- (LSP rename/code-action/references/...). Using bare "gr" as a grid
  -- default makes "gr" a prefix: pressing it waits timeoutlen and which-key
  -- surfaces the LSP submenu instead of firing reverse-FK navigation.
  local km = require("dadbod-grip.keymaps")
  assert(km.defaults.grid_fk_referencing ~= "gr",
    "grid_fk_referencing must not be 'gr' — collides with nvim 0.11+ gr* LSP prefix")
end)

--- Summary
print(string.format("\nfk_reverse_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
