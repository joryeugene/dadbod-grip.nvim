-- mutation_spec.lua: tests for UPDATE/DELETE detection and preview flow
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

local init = require("dadbod-grip")
local view = require("dadbod-grip.view")
local URL = "sqlite:tests/seed_sqlite.db"

-- ── resolve_query: statement detection ──
-- Through the real resolver, exported as _resolve_query for exactly this. An
-- earlier version of these tests re-derived the keyword match in the test body
-- (`sql:upper():match("^%s*(%u+)")`) and asserted on that, which is a test of
-- string.match: it passes no matter what init.lua decides to do with the
-- statement, including the very bug it was named after.

test("resolve_query: SELECT returns a raw spec, not a mutation", function()
  local spec, table_name, file_path, mutation = init._resolve_query("SELECT * FROM users", 100)
  assert(spec ~= nil, "spec should exist")
  eq(spec.is_raw, true, "is_raw")
  eq(spec.base_sql, "SELECT * FROM users", "base_sql")
  eq(table_name, "users", "single-table SELECT still names its table")
  eq(file_path, nil, "not a file")
  eq(mutation, nil, "not routed to the mutation path")
end)

-- The old bug: a mutation was treated as a table name and wrapped in SELECT,
-- which surfaced as "no such table: UPDATE". The resolver must return the
-- statement verbatim as its 4th value and nothing else.
for _, case in ipairs({
  { kw = "UPDATE",  sql = 'UPDATE "users" SET name = \'test\' WHERE id = 1' },
  { kw = "DELETE",  sql = "DELETE FROM orders WHERE id = 5" },
  { kw = "INSERT",  sql = "INSERT INTO users (name) VALUES ('test')" },
  { kw = "REPLACE", sql = "REPLACE INTO users (id, name) VALUES (1, 'test')" },
}) do
  test("resolve_query: " .. case.kw .. " is routed to the mutation path", function()
    local spec, table_name, file_path, mutation = init._resolve_query(case.sql, 100)
    eq(spec, nil, "no SELECT spec")
    eq(table_name, nil, "not treated as a table name")
    eq(file_path, nil, "not a file")
    eq(mutation, case.sql, "returned verbatim as mutation SQL")
  end)
end

test("resolve_query: a bare word is a table name", function()
  local spec, table_name, _, mutation = init._resolve_query("orders", 100)
  assert(spec ~= nil, "spec should exist")
  eq(spec.is_raw, false, "table spec is not raw")
  eq(table_name, "orders", "table name passed through")
  eq(mutation, nil, "not a mutation")
end)

-- ── mutation preview: table and WHERE extraction ──
-- _mutation_preview parses the table name and WHERE clause out of the statement
-- and builds the preview SELECT from them, so session.state.sql is that parser's
-- output. The previous tests copied its patterns into the test body instead,
-- which cannot fail when the parser they were meant to cover changes.

local function close_sessions()
  for bufnr in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

--- Run the real preview against the sqlite seed, hand back the session it staged.
local function preview(mutation_sql, stmt_type)
  close_sessions()
  init._mutation_preview(mutation_sql, URL, stmt_type, {})
  for _, session in pairs(view._sessions) do
    if session.pending_mutation then return session end
  end
  error("no grid opened with pending_mutation for: " .. mutation_sql)
end

test("preview: UPDATE with a quoted table scopes the preview to its WHERE", function()
  local mutation_sql = 'UPDATE "orders" SET status = \'done\' WHERE id = 1'
  local s = preview(mutation_sql, "UPDATE")
  eq(s.pending_mutation.type, "UPDATE", "mutation type")
  eq(s.pending_mutation.table_name, "orders", "table parsed out of the quoted identifier")
  eq(s.state.sql, 'SELECT * FROM "orders" WHERE id = 1', "preview SELECT")
  eq(s.pending_mutation.row_count, 1, "one row matches the WHERE")
  eq(s.pending_mutation.sql, mutation_sql, "original SQL stored")
  close_sessions()
end)

test("preview: DELETE reads its table from FROM and stages every matched row", function()
  local s = preview('DELETE FROM "users" WHERE age > 40', "DELETE")
  eq(s.pending_mutation.table_name, "users", "table parsed out of the FROM clause")
  eq(s.state.sql, 'SELECT * FROM "users" WHERE age > 40', "preview SELECT")
  eq(s.pending_mutation.row_count, 3, "three seeded users are over 40")
  local staged = 0
  for _ in pairs(s.state.deleted) do staged = staged + 1 end
  eq(staged, 3, "every previewed row is marked deleted, which is what shows it red")
  close_sessions()
end)

test("preview: DELETE drops ORDER BY and LIMIT from the extracted WHERE", function()
  -- The WHERE has to survive into a plain SELECT. Carrying ORDER BY/LIMIT over
  -- would preview a different row set than the statement is going to touch.
  local s = preview("DELETE FROM orders WHERE status = 'cancelled' ORDER BY id LIMIT 10;", "DELETE")
  eq(s.state.sql, 'SELECT * FROM "orders" WHERE status = \'cancelled\'',
    "trailing ORDER BY, LIMIT and semicolon stripped")
  close_sessions()
end)

test("preview: INSERT previews the whole table and counts the incoming rows", function()
  local s = preview("INSERT INTO users (name) VALUES ('probe')", "INSERT")
  eq(s.pending_mutation.table_name, "users", "table parsed out of INSERT INTO")
  eq(s.state.sql, 'SELECT * FROM "users"', "no WHERE for INSERT")
  eq(s.pending_mutation.row_count, 1, "row_count is the rows being inserted, not the table size")
  close_sessions()
end)

-- Keep the target alias in the preview source, without changing the stored
-- mutation or the base table used for schema metadata. These are real SELECTs
-- against SQLite; the MySQL DELETE form below is only previewed, not executed.
for _, case in ipairs({
  { source = "orders AS o", ref = "o", alias = "o" },
  { source = "orders AS offset", ref = "offset", alias = "offset" },
  { source = "orders as MixedCase", ref = "MixedCase", alias = "MixedCase" },
  { source = '"orders" AS "order alias"', ref = '"order alias"', alias = '"order alias"' },
  { source = 'orders AS "o.part"', ref = '"o.part"', alias = '"o.part"' },
  { source = 'orders AS "o""part"', ref = '"o""part"', alias = '"o""part"' },
  { source = 'orders AS "set"', ref = '"set"', alias = '"set"' },
  { source = "`orders` AS `o``part`", ref = "`o``part`", alias = "`o``part`" },
}) do
  for _, verb in ipairs({ "UPDATE", "DELETE" }) do
    test("preview: " .. verb .. " preserves alias " .. case.alias, function()
      local where = case.ref .. ".id = 1"
      local mutation_sql = verb == "UPDATE"
        and ("UPDATE " .. case.source .. " SET status = 'done' WHERE " .. where)
        or ("DELETE FROM " .. case.source .. " WHERE " .. where)
      local s = preview(mutation_sql, verb)
      eq(s.state.sql, 'SELECT * FROM "orders" AS ' .. case.alias .. " WHERE " .. where,
        "alias retained verbatim")
      eq(s.pending_mutation.sql, mutation_sql, "original mutation unchanged")
      eq(s.pending_mutation.table_name, "orders", "base table retained")
      eq(s.state.table_name, "orders", "schema metadata uses base table")
      eq(s.pending_mutation.row_count, 1, "only matching row previewed")
      eq(s.state.rows[1][1], "1", "matching row id")
      eq(s.state.pks[1], "id", "primary key still resolved")
      if verb == "UPDATE" then
        eq(s.state.changes[1].status, "done", "update staged")
      else
        eq(s.state.deleted[1], true, "delete staged")
      end
      close_sessions()
    end)
  end
end

for _, case in ipairs({
  { verb = "UPDATE", sql = "UPDATE orders o SET status = 'done' WHERE o.id = 1" },
  { verb = "DELETE", sql = "DELETE o FROM orders o WHERE o.id = 1" },
}) do
  test("preview: " .. case.verb .. " preserves a bare target alias", function()
    local s = preview(case.sql, case.verb)
    eq(s.state.sql, 'SELECT * FROM "orders" AS o WHERE o.id = 1', "bare alias retained")
    eq(s.pending_mutation.sql, case.sql, "original SQL unchanged")
    eq(s.pending_mutation.row_count, 1, "one matched row")
    close_sessions()
  end)
end

test("preview: alias qualifiers in literals and nested predicates stay intact", function()
  local where = "o.id = 1 AND 'o.id' = 'o.id'"
    .. " AND EXISTS (SELECT 1 FROM orders other WHERE other.id = o.id)"
  local s = preview("UPDATE orders AS o SET status = 'done' WHERE " .. where, "UPDATE")
  eq(s.state.sql, 'SELECT * FROM "orders" AS o WHERE ' .. where, "WHERE unchanged")
  eq(s.pending_mutation.row_count, 1, "correlated predicate matches one row")
  close_sessions()
end)

for _, case in ipairs({
  { verb = "UPDATE", sql = "UPDATE orders SET status = 'done'", suffix = "" },
  { verb = "DELETE", sql = "DELETE FROM orders;", suffix = "" },
  { verb = "UPDATE", sql = "UPDATE orders AS o SET status = 'done'", suffix = " AS o" },
  { verb = "UPDATE", sql = "UPDATE orders AS offset SET status = 'done'", suffix = " AS offset" },
  { verb = "DELETE", sql = "DELETE FROM orders AS o;", suffix = " AS o" },
}) do
  test("preview: no-WHERE statement " .. case.sql, function()
    local s = preview(case.sql, case.verb)
    eq(s.state.sql, 'SELECT * FROM "orders"' .. case.suffix, "full-table preview")
    eq(s.pending_mutation.sql, case.sql, "original SQL unchanged")
    assert(s.pending_mutation.row_count > 1, "all rows previewed")
    if case.verb == "UPDATE" then eq(s.state.changes[1].status, "done", "update staged") end
    close_sessions()
  end)
end

test("preview: a second DELETE source is rejected instead of previewing the whole table", function()
  close_sessions()
  local notify, notice = vim.notify, nil
  vim.notify = function(message) notice = message end
  local ok, err = pcall(init._mutation_preview,
    "DELETE FROM orders FROM orders JOIN users ON orders.user_id = users.id", URL, "DELETE", {})
  vim.notify = notify
  assert(ok, err)
  eq(next(view._sessions), nil, "no guessed preview")
  assert(notice and notice:find("single target table", 1, true), "unsupported source explained")
end)

-- ── delete on inserted row ──

test("delete on inserted row removes it via undo_row", function()
  local data = require("dadbod-grip.data")
  local state = data.new({
    columns = {"id", "name"},
    rows = {},
    primary_keys = {"id"},
    table_name = "test",
    url = "sqlite:test.db",
    sql = "SELECT * FROM test",
  })

  -- Insert a row
  state = data.insert_row(state, 0)
  local ins_idx
  for idx in pairs(state.inserted) do ins_idx = idx end
  assert(ins_idx, "inserted row exists")

  -- undo_row should remove it
  state = data.undo_row(state, ins_idx)
  eq(state.inserted[ins_idx], nil, "inserted row removed by undo_row")

  -- toggle_delete is the wrong verb for an unsaved inserted row: it only adds a
  -- delete mark, leaving the row in `inserted` and thus staged both ways. That
  -- is by design, not a bug -- deciding between the two is the caller's job, and
  -- init.lua's on_delete does branch on state.inserted[row_idx] before choosing.
  -- Both halves of that contract are pinned here so the branch stays meaningful.
  state = data.insert_row(state, 0)
  for idx in pairs(state.inserted) do ins_idx = idx end
  state = data.toggle_delete(state, ins_idx)
  eq(state.deleted[ins_idx], true, "toggle_delete marks deleted")
  assert(state.inserted[ins_idx] ~= nil, "toggle_delete leaves the row in inserted")
end)

print(string.format("\nmutation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
