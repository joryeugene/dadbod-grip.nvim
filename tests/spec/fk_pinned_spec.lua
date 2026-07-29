-- fk_pinned_spec.lua: FK navigation context is a *pinned* filter, and in-place
-- navigation syncs the query pad.
--
-- Both FK jumps (gf forward, gm reverse) replace the grid's spec with one scoped
-- by a WHERE clause. That clause is the identity of the new grid, not a filter the
-- user applied, so:
--   • F / X must not drop it (dropping it widens the grid to the whole table while
--     the breadcrumb still says "users > orders" and <C-o> pops to a state that
--     never existed);
--   • the [filtered] badge and gP (save preset) must ignore it;
--   • build_sql must still apply it.
-- And because FK navigation swaps the spec *inside* an existing grid, it never goes
-- through init.open() — so it has to sync the query pad itself, or the pad keeps
-- advertising the table you started from.
--
-- Uses tests/seed_sqlite.db: users ← orders.user_id (10 orders for user 1).

local db   = require("dadbod-grip.db")
local data = require("dadbod-grip.data")
local qmod = require("dadbod-grip.query")
local view = require("dadbod-grip.view")
local qp   = require("dadbod-grip.query_pad")
local km   = require("dadbod-grip.keymaps")

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

local function not_contains(s, pattern, msg)
  assert(type(s) == "string" and not s:find(pattern, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to NOT contain '" .. pattern .. "'")
end

-- ── harness ───────────────────────────────────────────────────────────────

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

--- Re-run a spec into an existing grid: the same contract init.lua's on_requery
--- implements, minus the pagination COUNT. Wired by open_grid so the F/X/f
--- keymaps actually reach the DB in these tests.
local function requery(bufnr, new_spec)
  local session = view._sessions[bufnr]
  local sql_str = qmod.build_sql(new_spec)
  local result, err = db.query(sql_str, url)
  assert(result, "requery failed: " .. tostring(err))
  result.primary_keys = db.get_primary_keys(new_spec.table_name, url) or {}
  result.table_name = new_spec.table_name
  result.url = url
  result.sql = sql_str
  session.query_spec = new_spec
  session.total_rows = #result.rows
  view.render(bufnr, data.new(result))
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
  local bufnr = view.open(data.new(result), url, sql_str)
  view._sessions[bufnr].query_spec = spec
  view._sessions[bufnr].on_requery = requery
  return bufnr
end

local function cursor_to(bufnr, row_order, col_name)
  local r = view._sessions[bufnr]._render
  local line = (r.data_start or 4) + row_order - 1
  local bp = r.byte_positions[row_order][col_name]
  assert(bp, "no byte position for column " .. col_name)
  vim.api.nvim_win_set_cursor(0, { line, bp.start })
end

local function with_notify(fn)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m, _) table.insert(msgs, tostring(m)) end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then error(err) end
  return msgs
end

local function joined(msgs)
  return table.concat(msgs, " | ")
end

--- Press a grid keymap by its configured lhs.
local function feed(lhs)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
end

local function title_of(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
end

--- Wire a scratch buffer as the query pad and return it.
local function make_pad()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = true
  qp._set_pad_bufnr(bufnr)
  return bufnr
end

local function pad_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- users row 1 (Alice, id 1) → gm → the 10 orders referencing her.
local function grid_on_alices_orders()
  local bufnr = open_grid("users")
  cursor_to(bufnr, 1, "id")
  with_notify(function() view._fk_referencing(bufnr) end)
  local session = view._sessions[bufnr]
  eq(session.state.table_name, "orders", "precondition: reverse FK landed on orders")
  eq(#session.state.rows, 10, "precondition: 10 orders for user 1")
  return bufnr, session
end

-- ── pinning ───────────────────────────────────────────────────────────────

test("reverse FK (gm) pins its scoping clause", function()
  cleanup_grids()
  local _, session = grid_on_alices_orders()
  eq(#session.query_spec.filters, 1, "one filter")
  eq(session.query_spec.filters[1].pinned, true, "FK clause is pinned")
  eq(session.query_spec.filters[1].clause, [["user_id" = '1']])
  cleanup_grids()
end)

test("forward FK (gf) pins its scoping clause", function()
  cleanup_grids()
  local bufnr = open_grid("orders")
  cursor_to(bufnr, 1, "user_id")
  with_notify(function() feed(km.defaults.grid_fk_follow) end)
  local session = view._sessions[bufnr]
  eq(session.state.table_name, "users", "followed FK to users")
  eq(#session.query_spec.filters, 1, "one filter")
  eq(session.query_spec.filters[1].pinned, true, "FK clause is pinned")
  cleanup_grids()
end)

test("pinned clause still reaches the DB (grid stays scoped)", function()
  cleanup_grids()
  local _, session = grid_on_alices_orders()
  contains(qmod.build_sql(session.query_spec), [[WHERE ("user_id" = '1')]])
  cleanup_grids()
end)

-- ── F: clear filters ──────────────────────────────────────────────────────

test("F on a pure FK context reports nothing to clear and keeps the rows", function()
  cleanup_grids()
  local _, session = grid_on_alices_orders()
  local msgs = with_notify(function() feed(km.defaults.grid_filter_clear) end)
  contains(joined(msgs), "No active filters", "F treats the FK clause as context")
  eq(session.state.table_name, "orders", "still on orders")
  eq(#session.state.rows, 10, "grid was not widened to all orders")
  eq(#session.query_spec.filters, 1, "FK clause survived F")
  eq(session.query_spec.filters[1].pinned, true, "and is still pinned")
  cleanup_grids()
end)

test("F clears the user filter but keeps the FK context", function()
  cleanup_grids()
  local bufnr, session = grid_on_alices_orders()
  requery(bufnr, qmod.add_filter(session.query_spec, [["id" = 1]]))
  eq(#session.state.rows, 1, "precondition: user filter narrowed to one order")

  with_notify(function() feed(km.defaults.grid_filter_clear) end)
  eq(#session.query_spec.filters, 1, "only the pinned filter is left")
  eq(session.query_spec.filters[1].pinned, true, "the survivor is the FK clause")
  eq(#session.state.rows, 10, "back to user 1's orders, not the whole table")
  cleanup_grids()
end)

-- ── X: reset view ─────────────────────────────────────────────────────────

test("X on a pure FK context reports defaults and keeps the rows", function()
  cleanup_grids()
  local _, session = grid_on_alices_orders()
  local msgs = with_notify(function() feed(km.defaults.grid_reset_view) end)
  contains(joined(msgs), "already at defaults", "FK context is the grid's default state")
  eq(#session.query_spec.filters, 1, "FK clause survived X")
  eq(#session.state.rows, 10, "grid was not widened to all orders")
  cleanup_grids()
end)

test("X clears sorts and user filters but keeps the FK context", function()
  cleanup_grids()
  local bufnr, session = grid_on_alices_orders()
  local spec = qmod.add_filter(session.query_spec, [["id" = 1]])
  spec = qmod.toggle_sort(spec, "total")
  requery(bufnr, spec)

  with_notify(function() feed(km.defaults.grid_reset_view) end)
  eq(#session.query_spec.sorts, 0, "sorts cleared")
  eq(#session.query_spec.filters, 1, "only the pinned filter is left")
  eq(session.query_spec.filters[1].pinned, true, "the survivor is the FK clause")
  eq(#session.state.rows, 10, "back to user 1's orders")
  cleanup_grids()
end)

-- ── title badge ───────────────────────────────────────────────────────────

test("no [filtered] badge for a pure FK context", function()
  cleanup_grids()
  local bufnr = select(1, grid_on_alices_orders())
  not_contains(title_of(bufnr), "filtered",
    "the user filtered nothing — the breadcrumb already says where we are")
  contains(title_of(bufnr), "users > orders", "breadcrumb still shown")
  cleanup_grids()
end)

test("[filtered] badge appears once the user filters on top", function()
  cleanup_grids()
  local bufnr, session = grid_on_alices_orders()
  requery(bufnr, qmod.add_filter(session.query_spec, [["id" = 1]]))
  contains(title_of(bufnr), "filtered", "user filter is badged")
  cleanup_grids()
end)

-- ── gP: save filter preset ────────────────────────────────────────────────

--- Run fn with filters.save captured and ui.input answering the name prompt.
local function with_preset_capture(name, fn)
  local filters_mod = require("dadbod-grip.filters")
  local ui = require("dadbod-grip.ui")
  local orig_save, orig_input = filters_mod.save, ui.input
  local captured
  filters_mod.save = function(tbl, n, clause) captured = { tbl = tbl, name = n, clause = clause } end
  ui.input = function() return name end
  local ok, err = pcall(fn)
  filters_mod.save, ui.input = orig_save, orig_input
  if not ok then error(err) end
  return captured
end

test("gP refuses to save a pure FK context as a preset", function()
  cleanup_grids()
  grid_on_alices_orders()
  local msgs
  local captured = with_preset_capture("p1", function()
    msgs = with_notify(function() feed(km.defaults.grid_preset_save) end)
  end)
  eq(captured, nil, "nothing saved")
  contains(joined(msgs), "No active filters to save")
  cleanup_grids()
end)

test("gP saves only the user clause, never the FK context", function()
  cleanup_grids()
  local bufnr, session = grid_on_alices_orders()
  requery(bufnr, qmod.add_filter(session.query_spec, [["id" = 1]]))
  local captured = with_preset_capture("just-order-1", function()
    with_notify(function() feed(km.defaults.grid_preset_save) end)
  end)
  truthy(captured, "preset saved")
  eq(captured.tbl, "orders", "saved under the current table")
  contains(captured.clause, [["id" = 1]], "user clause saved")
  not_contains(captured.clause, "user_id",
    "the FK context must not leak into a reusable preset")
  cleanup_grids()
end)

-- ── query pad sync ────────────────────────────────────────────────────────

test("reverse FK (gm) syncs the pad to the new table, scoped by the FK clause", function()
  cleanup_grids()
  local pad = make_pad()
  grid_on_alices_orders()
  eq(pad_text(pad), [[SELECT * FROM "orders" WHERE ("user_id" = '1')]],
    "the pad must describe the rows the grid is showing")
  cleanup_grids()
end)

test("forward FK (gf) syncs the pad", function()
  cleanup_grids()
  local pad = make_pad()
  local bufnr = open_grid("orders")
  cursor_to(bufnr, 1, "user_id")
  with_notify(function() feed(km.defaults.grid_fk_follow) end)
  contains(pad_text(pad), [[SELECT * FROM "users" WHERE (]], "pad follows the jump")
  cleanup_grids()
end)

test("FK back (<C-o>) syncs the pad to the restored query", function()
  cleanup_grids()
  local pad = make_pad()
  local bufnr = select(1, grid_on_alices_orders())
  with_notify(function() feed(km.defaults.grid_fk_back) end)
  eq(view._sessions[bufnr].state.table_name, "users", "precondition: popped back to users")
  eq(pad_text(pad), 'SELECT * FROM "users"',
    "popping the nav stack must not leave the pad on the child table")
  cleanup_grids()
end)

test("FK round trip out of a pad query leaves that query in the pad once", function()
  cleanup_grids()
  local pad = make_pad()
  local user_sql = "SELECT id, user_id FROM orders LIMIT 5"
  vim.api.nvim_buf_set_lines(pad, 0, -1, false, { user_sql })

  -- A grid over the user's own query: init.open() skips the sync for these
  -- (from_pad), so the pad holds exactly their text.
  local spec = qmod.new_raw(user_sql, 100)
  local sql_str = qmod.build_sql(spec)
  local result = assert(db.query(sql_str, url))
  result.table_name = "orders"
  result.url = url
  result.sql = sql_str
  result.primary_keys = db.get_primary_keys("orders", url) or {}
  local bufnr = view.open(data.new(result), url, sql_str)
  view._sessions[bufnr].query_spec = spec

  cursor_to(bufnr, 1, "user_id")
  with_notify(function() feed(km.defaults.grid_fk_follow) end)
  contains(pad_text(pad), [[SELECT * FROM "users" WHERE (]], "jump appended the FK query")

  with_notify(function() feed(km.defaults.grid_fk_back) end)
  eq(pad_text(pad), user_sql,
    "coming back must restore the pad, not restate the query below itself")
  cleanup_grids()
end)

test("pad sync does not clobber a query the user is composing", function()
  cleanup_grids()
  local pad = make_pad()
  vim.api.nvim_buf_set_lines(pad, 0, -1, false, { "SELECT count(*) FROM orders" })
  grid_on_alices_orders()
  contains(pad_text(pad), "SELECT count(*) FROM orders", "user's query kept")
  contains(pad_text(pad), [[SELECT * FROM "orders" WHERE ("user_id" = '1')]],
    "synced query appended below it")
  cleanup_grids()
end)

--- Summary
print(string.format("\nfk_pinned_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
