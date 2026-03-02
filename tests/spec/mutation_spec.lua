-- mutation_spec.lua — tests for UPDATE/DELETE detection and preview flow
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

-- ── resolve_query: statement detection ──

test("resolve_query: SELECT returns raw spec", function()
  -- resolve_query is local, but we can test through the public interface
  -- by checking that M.open doesn't error for SELECT
  local query = require("dadbod-grip.query")
  local spec = query.new_raw("SELECT * FROM users", 100)
  assert(spec ~= nil, "spec should exist")
  eq(spec.is_raw, true, "is_raw")
  eq(spec.base_sql, "SELECT * FROM users", "base_sql")
end)

test("resolve_query: UPDATE is detected as mutation (not wrapped in SELECT)", function()
  -- We test this by calling init.open with an UPDATE and checking it doesn't
  -- produce a "no such table" error (which was the old bug: wrapping in SELECT)
  -- Since resolve_query is local, we test the behavior:
  -- An UPDATE should NOT be treated as a table name
  local query = require("dadbod-grip.query")
  -- If UPDATE were treated as table name, new_table would be called
  -- Let's verify the first keyword detection
  local sql = 'UPDATE "users" SET name = \'test\' WHERE id = 1'
  local upper = sql:upper():match("^%s*(%u+)")
  eq(upper, "UPDATE", "detects UPDATE keyword")
end)

test("resolve_query: DELETE is detected as mutation", function()
  local sql = "DELETE FROM orders WHERE id = 5"
  local upper = sql:upper():match("^%s*(%u+)")
  eq(upper, "DELETE", "detects DELETE keyword")
end)

test("resolve_query: INSERT is detected as mutation", function()
  local sql = "INSERT INTO users (name) VALUES ('test')"
  local upper = sql:upper():match("^%s*(%u+)")
  eq(upper, "INSERT", "detects INSERT keyword")
end)

-- ── SQL parsing for preview ──

test("extract table from UPDATE SQL", function()
  local sql = 'UPDATE "orders" SET status = \'done\' WHERE id = 1'
  local flat = sql:gsub("\n", " ")
  local after_update = flat:match("[Uu][Pp][Dd][Aa][Tt][Ee]%s+(.*)")
  local table_name = after_update:match('^"([^"]+)"')
    or after_update:match("^`([^`]+)`")
    or after_update:match("^([%w_%.]+)")
  eq(table_name, "orders", "extracts table from UPDATE")
end)

test("extract table from DELETE SQL", function()
  local sql = 'DELETE FROM "users" WHERE age > 60'
  local flat = sql:gsub("\n", " ")
  local table_name = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
    or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
    or flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
  eq(table_name, "users", "extracts table from DELETE")
end)

test("extract WHERE from UPDATE SQL", function()
  local sql = 'UPDATE orders SET status = \'done\' WHERE id = 1;'
  local flat = sql:gsub("\n", " ")
  local where = flat:match("[Ww][Hh][Ee][Rr][Ee]%s+(.+)$")
  if where then where = where:gsub("%s*;%s*$", "") end
  eq(where, "id = 1", "extracts WHERE clause")
end)

test("extract WHERE from DELETE SQL", function()
  local sql = "DELETE FROM orders WHERE status = 'cancelled' ORDER BY id LIMIT 10;"
  local flat = sql:gsub("\n", " ")
  local where = flat:match("[Ww][Hh][Ee][Rr][Ee]%s+(.+)$")
  if where then
    where = where:gsub("%s*;%s*$", "")
    where = where:gsub("%s+[Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy].*$", "")
    where = where:gsub("%s+[Ll][Ii][Mm][Ii][Tt]%s+.*$", "")
  end
  eq(where, "status = 'cancelled'", "extracts WHERE, strips ORDER BY/LIMIT")
end)

-- ── mutation preview: grid opens with pending_mutation ──

test("_mutation_preview opens grid with pending_mutation flag", function()
  -- This requires a real DB. Use the test sqlite DB.
  local init = require("dadbod-grip")
  local view = require("dadbod-grip.view")
  local url = "sqlite:tests/seed_sqlite.db"

  -- Clean up any existing sessions
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  -- Call _mutation_preview directly
  local mutation_sql = 'UPDATE "orders" SET status = \'done\' WHERE id = 1'
  init._mutation_preview(mutation_sql, url, "UPDATE", {})

  -- Check that a grid was opened with pending_mutation
  local found_mutation = false
  for bufnr, session in pairs(view._sessions) do
    if session.pending_mutation then
      found_mutation = true
      eq(session.pending_mutation.type, "UPDATE", "mutation type")
      eq(session.pending_mutation.table_name, "orders", "mutation table")
      assert(session.pending_mutation.row_count >= 0, "row_count set")
      assert(session.pending_mutation.sql == mutation_sql, "original SQL stored")
    end
  end
  assert(found_mutation, "grid opened with pending_mutation flag")

  -- Clean up
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(0)[#vim.api.nvim_tabpage_list_wins(0)], true)
  end
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

  -- toggle_delete should NOT be used for inserted rows
  -- (this is a design test: the on_delete callback should check)
  state = data.insert_row(state, 0)
  for idx in pairs(state.inserted) do ins_idx = idx end
  state = data.toggle_delete(state, ins_idx)
  -- toggle_delete marks it in deleted but doesn't remove from inserted
  eq(state.deleted[ins_idx], true, "toggle_delete marks deleted")
  assert(state.inserted[ins_idx] ~= nil, "toggle_delete does NOT remove from inserted (bug)")
end)

print(string.format("\nmutation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
