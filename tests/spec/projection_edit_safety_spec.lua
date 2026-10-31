-- projection_edit_safety_spec.lua: projected query columns must map safely
-- back to the base table before a result grid is editable.

local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")
local sql = require("dadbod-grip.sql")

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

local function eq(actual, expected, msg)
  assert(actual == expected,
    (msg or "") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function cleanup_grids()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function open_query(query_sql, query_url)
  cleanup_grids()
  grip.open(query_sql, query_url or url, { from_pad = true })
  local bufnr, session = next(view._sessions)
  assert(bufnr and session, "expected a grid session")
  return session
end

test("aliased column result stays read-only", function()
  local session = open_query([[
SELECT id, total AS status
FROM orders;
]])
  eq(session.state.readonly, true, "aliased result must not be editable")
  eq(session.state.table_name, nil, "unsafe projection must not expose a mutation table")
  eq(view._is_editable(session), false, "grid edit actions must stay disabled")
end)

test("computed aliased column result stays read-only", function()
  local session = open_query([[
SELECT id, total * 2 AS status
FROM orders;
]])
  eq(session.state.readonly, true, "computed result must not be editable")
  eq(session.state.table_name, nil, "unsafe projection must not expose a mutation table")
  eq(view._is_editable(session), false, "grid edit actions must stay disabled")
end)

test("plain direct column projection remains editable", function()
  local session = open_query([[
SELECT id, total
FROM orders;
]])
  eq(session.state.table_name, "orders", "base table")
  eq(session.state.readonly, false, "direct base-table columns should remain editable")
  eq(session.state.pks[1], "id", "primary key")
  eq(view._is_editable(session), true, "grid edit actions should remain enabled")
end)

-- A separate database keeps the shared seed unchanged for later specs.
local fixture = vim.fn.tempname() .. "_projection.db"
vim.fn.system({ "sqlite3", fixture }, [[
CREATE TABLE projection_values (
  id INTEGER PRIMARY KEY,
  "姓名" TEXT,
  "CURRENT_DATE" TEXT,
  "CURRENT_TIME" TEXT,
  "CURRENT_TIMESTAMP" TEXT,
  "user" TEXT,
  "true" TEXT,
  "false" TEXT
);
INSERT INTO projection_values VALUES (
  1, 'Alice', 'stored-date', 'stored-time', 'stored-timestamp',
  'stored-user', 'stored-true', 'stored-false'
);
]])
assert(vim.v.shell_error == 0, "could not create projection fixture")
local fixture_url = "sqlite:" .. fixture

local function assert_edit_targets(session, column)
  eq(session.state.readonly, false, "direct column must stay editable")
  eq(view._is_editable(session), true, "grid edit actions must stay enabled")
  local changed = data.add_change(session.state, 1, column, "changed")
  local preview = sql.preview_staged(
    session.state.table_name, data.get_updates(changed), {}, {})
  eq(preview,
    'UPDATE "projection_values" SET "' .. column
      .. '" = \'changed\' WHERE "id" = 1 AND typeof("id") = \'integer\';',
    "staged update must target the displayed base-table column")
  local actual = vim.fn.system({ "sqlite3", fixture }, 'BEGIN;\n' .. preview
    .. '\nSELECT ' .. sql.quote_column(column) .. ' FROM projection_values WHERE id=1;\nROLLBACK;')
  eq(vim.v.shell_error, 0, "typed preview must execute")
  eq(actual, "changed\n", "preview must update the exact displayed column")
end

for _, projection in ipairs({ "姓名", '"姓名"' }) do
  test("Unicode projection stays editable: " .. projection, function()
    local session = open_query(
      "SELECT id, " .. projection .. " FROM projection_values", fixture_url)
    eq(session.state.columns[2], "姓名", "original column name")
    eq(session.state.rows[1][2], "Alice", "original stored value")
    assert_edit_targets(session, "姓名")
  end)
end

for keyword, stored in pairs({
  CURRENT_DATE = "stored-date",
  CURRENT_TIME = "stored-time",
  CURRENT_TIMESTAMP = "stored-timestamp",
}) do
  test("bare " .. keyword .. " expression stays read-only", function()
    local session = open_query(
      "SELECT id, " .. keyword .. " FROM projection_values", fixture_url)
    eq(session.state.columns[2], keyword, "expression output name")
    assert(session.state.rows[1][2] ~= stored,
      "bare expression must not display the same-named stored column")
    eq(session.state.readonly, true, "expression must not be editable")
    eq(session.state.table_name, nil, "no mutation table for an expression")
    eq(view._is_editable(session), false, "grid edit actions stay disabled")
  end)

  test("quoted and qualified " .. keyword .. " columns stay editable",
  function()
    for _, projection in ipairs({ '"' .. keyword .. '"', "p." .. keyword }) do
      local session = open_query(
        "SELECT id, " .. projection .. " FROM projection_values p",
        fixture_url)
      eq(session.state.rows[1][2], stored, "real stored column value")
      assert_edit_targets(session, keyword)
    end
  end)
end

test("SQLite ordinary keyword-named columns stay editable", function()
  for _, column in ipairs({ "user", "true", "false" }) do
    local session = open_query(
      "SELECT id, " .. column .. " FROM projection_values", fixture_url)
    eq(session.state.rows[1][2], "stored-" .. column, "stored column value")
    assert_edit_targets(session, column)
  end
end)

test("SQLite literal backslash path filter stays editable", function()
  local session = open_query([[
SELECT id, "user" FROM projection_values
WHERE 'C:\data\orders' = 'C:\data\orders'
]], fixture_url)
  eq(session.state.columns[2], "user", "original column name")
  eq(session.state.rows[1][2], "stored-user", "real stored column value")
  assert_edit_targets(session, "user")
end)

cleanup_grids()
vim.fn.delete(fixture)

print(string.format("projection_edit_safety_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
