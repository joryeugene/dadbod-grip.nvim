-- Real SQLite, public grid callbacks, and disposable storage only.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data = require("dadbod-grip.db"), require("dadbod-grip.data")
local query, paths = require("dadbod-grip.query"), require("dadbod-grip.paths")
local ui, editor = require("dadbod-grip.ui"), require("dadbod-grip.editor")
local pass, fail = 0, 0
local fixture = vim.fn.tempname() .. "_pagination"
vim.fn.mkdir(fixture, "p")
local file, url = fixture .. "/fixture.sqlite", "sqlite:" .. fixture .. "/fixture.sqlite"
local saved = { root = paths.project_root, notify = vim.notify, confirm = ui.confirm,
  error = editor.show_error, native_confirm = vim.fn.confirm, opts = grip.get_opts() }
paths.project_root = function() return fixture end
vim.notify, ui.confirm, editor.show_error = function() end, function() return true end, function() end
vim.fn.confirm = function() return 1 end
grip.setup({ limit = 2, connections_path = fixture .. "/connections.json", completion = false })

local function eq(actual, expected, label)
  assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected)
    .. ", got " .. tostring(actual))
end
local function cleanup()
  local buffers = {}
  for b in pairs(view._sessions) do buffers[#buffers + 1] = b end
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
end
local function native(sql)
  local out = vim.fn.system({ "sqlite3", file }, sql)
  assert(vim.v.shell_error == 0, out)
  return out:gsub("\n$", "")
end
local function reset()
  cleanup()
  native([[DROP TABLE IF EXISTS items;
    CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT UNIQUE, active INTEGER);
    INSERT INTO items VALUES(1,'one',1),(2,'two',0),(3,'three',1),(4,'four',0),(5,'five',1);]])
end
local function test(name, fn)
  reset()
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function open(statement)
  grip.open(statement or "items", url, { from_pad = true })
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(view._sessions[buf], "public open did not create a grid")
  assert(vim.wait(1000, function() return session._column_info ~= nil end, 5), "column metadata did not settle")
  session.on_requery(buf, query.toggle_sort(session.query_spec, "id"))
  return buf, session
end
local function page(buf, session, n)
  session.on_requery(buf, query.set_page(session.query_spec, n))
end
local function ids(session)
  return table.concat(vim.tbl_map(function(row) return row[1] end, session.state.rows), ",")
end
local function undo(buf)
  local lhs = require("dadbod-grip.keymaps").get("grid_undo")
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs then assert(map.callback, "Undo has no callback"); map.callback(); return end
  end
  error("Undo mapping missing")
end

test("confirmed delete clamps the last page and refetches its surviving rows", function()
  local buf, session = open()
  page(buf, session, 3)
  eq(ids(session), "5", "last page fixture")
  view.apply_edit(buf, data.toggle_delete(session.state, 1))
  session.on_apply(buf)
  eq(native("SELECT GROUP_CONCAT(id) FROM (SELECT id FROM items ORDER BY id)"), "1,2,3,4", "actual delete")
  eq(session.total_rows, 4, "fresh total")
  eq(session.query_spec.page, 2, "clamped page")
  eq(ids(session), "3,4", "previous page rows")
  eq(session.query_sql, query.build_sql(session.query_spec), "published SQL")
  undo(buf)
  eq(native("SELECT COUNT(*) FROM items"), "5", "delete Undo committed")
  eq(session.total_rows, 5, "delete Undo total")
  eq(session.query_spec.page, 2, "delete Undo retains valid page")
end)

test("deleting the only row publishes zero rows on page one", function()
  native("DELETE FROM items WHERE id <> 1")
  local buf, session = open()
  view.apply_edit(buf, data.toggle_delete(session.state, 1))
  session.on_apply(buf)
  eq(native("SELECT COUNT(*) FROM items"), "0", "actual empty table")
  eq(session.total_rows, 0, "empty total")
  eq(session.query_spec.page, 1, "empty page")
  eq(#session.state.rows, 0, "empty rows")
end)

test("insert and committed Undo update totals while retaining a valid current page", function()
  local buf, session = open()
  page(buf, session, 2)
  local staged = data.insert_row(session.state, #session.state.rows)
  local row = assert(next(staged.inserted))
  staged = data.add_change(staged, row, "id", "6")
  staged = data.add_change(staged, row, "name", "six")
  staged = data.add_change(staged, row, "active", "1")
  view.apply_edit(buf, staged)
  session.on_apply(buf)
  eq(native("SELECT COUNT(*) FROM items"), "6", "insert committed")
  eq(session.total_rows, 6, "insert total")
  eq(session.query_spec.page, 2, "insert page")
  eq(ids(session), "3,4", "insert current page")
  undo(buf)
  eq(native("SELECT COUNT(*) FROM items"), "5", "Undo committed")
  eq(session.total_rows, 5, "Undo total")
  eq(session.query_spec.page, 2, "Undo page")
end)

test("filtered update recounts and clamps without losing filter sort or page size", function()
  local buf, session = open()
  local spec = query.add_filter(session.query_spec, '"active" = 1', { pinned = true })
  spec = query.toggle_sort(spec, "id")
  session.on_requery(buf, query.set_page(spec, 2))
  eq(ids(session), "1", "filtered last page")
  view.apply_edit(buf, data.add_change(session.state, 1, "active", "0"))
  session.on_apply(buf)
  eq(native("SELECT GROUP_CONCAT(id) FROM items WHERE active=1"), "3,5", "actual filtered update")
  eq(session.total_rows, 2, "filtered total")
  eq(session.query_spec.page, 1, "filtered clamp")
  eq(session.query_spec.page_size, 2, "page size")
  eq(session.query_spec.filters[1].clause, '"active" = 1', "filter")
  eq(session.query_spec.filters[1].pinned, true, "pinned filter")
  eq(session.query_spec.sorts[1].dir, "DESC", "sort")
  eq(ids(session), "5,3", "filtered sorted rows")
end)

test("manual refresh recounts external deletions before fetching the valid page", function()
  local buf, session = open()
  page(buf, session, 3)
  native("DELETE FROM items WHERE id >= 4")
  session.on_refresh(buf)
  eq(session.total_rows, 3, "external total")
  eq(session.query_spec.page, 2, "external clamp")
  eq(ids(session), "3", "external current rows")
end)

for _, action in ipairs({ "refresh", "requery" }) do
  test("failed count leaves total unknown without guessing a page during " .. action, function()
    local buf, session = open()
    page(buf, session, 3)
    local real_query = db.query
    db.query = function(sql, ...)
      if sql:find("COUNT(*)", 1, true) then return nil, "controlled count denial" end
      return real_query(sql, ...)
    end
    local ok, err = pcall(function()
      if action == "refresh" then session.on_refresh(buf)
      else session.on_requery(buf, query.set_page(session.query_spec, 3)) end
    end)
    db.query = real_query
    assert(ok, err)
    eq(session.total_rows, nil, "unknown total")
    eq(session.query_spec.page, 3, "unknown count keeps requested page")
    eq(ids(session), "5", "successful page data")
  end)
end

test("raw refresh does not add a count execution or keep a stale total", function()
  local buf, session = open("SELECT id,name,active FROM items")
  page(buf, session, 3)
  local real_query, counts = db.query, 0
  db.query = function(sql, ...)
    if sql:find("COUNT(*)", 1, true) then counts = counts + 1 end
    return real_query(sql, ...)
  end
  local ok, err = pcall(session.on_refresh, buf)
  db.query = real_query
  assert(ok, err)
  eq(counts, 0, "no new raw count evaluation")
  eq(session.total_rows, nil, "raw total becomes unknown")
  eq(session.query_spec.page, 3, "raw current page retained")
  eq(ids(session), "5", "raw current rows")
end)

test("malformed count remains unknown instead of clamping to page one", function()
  local buf, session = open()
  page(buf, session, 3)
  local real_query = db.query
  db.query = function(sql, ...)
    if sql:find("COUNT(*)", 1, true) then return { columns = { "count" }, rows = {{ "not-a-count" }} } end
    return real_query(sql, ...)
  end
  local ok, err = pcall(session.on_requery, buf, query.set_page(session.query_spec, 3))
  db.query = real_query
  assert(ok, err)
  eq(session.total_rows, nil, "malformed total")
  eq(session.query_spec.page, 3, "unproved clamp refused")
  eq(ids(session), "5", "current rows")
end)

test("failed page SELECT does not publish a fresh count or clamp over staged rows", function()
  local buf, session = open()
  page(buf, session, 3)
  view.apply_edit(buf, data.add_change(session.state, 1, "name", "staged"))
  local before = { state = session.state, spec = session.query_spec, sql = session.query_sql,
    total = session.total_rows }
  native("DELETE FROM items WHERE id=5")
  local real_query = db.query
  db.query = function(sql, ...)
    if not sql:find("COUNT(*)", 1, true) then return nil, "controlled SELECT refusal" end
    return real_query(sql, ...)
  end
  local ok, err = pcall(session.on_refresh, buf)
  db.query = real_query
  assert(ok, err)
  eq(session.state, before.state, "staging snapshot")
  eq(session.query_spec, before.spec, "query identity")
  eq(session.query_sql, before.sql, "SQL identity")
  eq(session.total_rows, before.total, "unpublished count")
  eq(data.has_changes(session.state), true, "staging retained")
end)

test("newer nested navigation keeps its rows count and page over an older refresh", function()
  local buf, session = open()
  page(buf, session, 3)
  local real_query, entered = db.query, false
  db.query = function(sql, ...)
    local result, err = real_query(sql, ...)
    if not entered and not sql:find("COUNT(*)", 1, true) then
      entered = true
      native("DELETE FROM items WHERE id=5")
      session.on_requery(buf, query.set_page(session.query_spec, 1))
    end
    return result, err
  end
  local ok, err = pcall(session.on_refresh, buf)
  db.query = real_query
  assert(ok, err)
  eq(entered, true, "nested navigation ran")
  eq(session.query_spec.page, 1, "newer page")
  eq(session.total_rows, 4, "newer total")
  eq(ids(session), "1,2", "newer rows")
end)

test("unsettled write refusal does not count query or discard staging", function()
  local buf, session = open()
  view.apply_edit(buf, data.add_change(session.state, 1, "name", "staged"))
  local before, calls = session.state, 0
  session._write_unknown, session._write_lifecycle = true, { settled = false }
  local real_query = db.query
  db.query = function(...) calls = calls + 1; return real_query(...) end
  local ok, err = pcall(session.on_refresh, buf)
  db.query = real_query
  assert(ok, err)
  eq(calls, 0, "no refresh submission")
  eq(session.state, before, "retained staging")
  eq(session._write_unknown, true, "retained uncertainty")
end)

cleanup()
grip.setup(saved.opts)
paths.project_root, vim.notify, ui.confirm, editor.show_error = saved.root, saved.notify, saved.confirm, saved.error
vim.fn.confirm = saved.native_confirm
vim.fn.delete(fixture, "rf")
print(string.format("\npagination_after_write_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
