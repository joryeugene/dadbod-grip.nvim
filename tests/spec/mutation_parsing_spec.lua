-- Exercise mutation parsing through real SQLite previews and apply/cancel.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data = require("dadbod-grip.db"), require("dadbod-grip.data")
local keys = require("dadbod-grip.keymaps")
local pass, fail = 0, 0
local cwd, rtp = vim.fn.getcwd(), vim.o.runtimepath
local confirm, notify, execute = vim.fn.confirm, vim.notify, db.execute
local fixture_dir = vim.fn.tempname() .. "-mutation-parsing"
vim.fn.mkdir(fixture_dir, "p")
vim.opt.rtp:prepend(cwd)
vim.cmd.cd(vim.fn.fnameescape(fixture_dir))
local fixture, calls, notices = fixture_dir .. "/probe.sqlite", {}, {}
local url = "sqlite:" .. fixture
local initial = { { "1", "one" }, { "2", "two" }, { "3", "three" } }

vim.fn.confirm = function() return 1 end
vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
end
db.execute = function(sql, ...)
  calls[#calls + 1] = sql
  return execute(sql, ...)
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected),
    (message or "value") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function cleanup()
  local buffers = {}
  for buf in pairs(view._sessions) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    view._sessions[buf] = nil
  end
  while #vim.api.nvim_list_wins() > 1 do
    local wins = vim.api.nvim_list_wins()
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

local function test(name, run)
  cleanup()
  vim.fn.delete(fixture)
  vim.fn.system({ "sqlite3", fixture }, [[
CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT);
INSERT INTO items VALUES(1,'one'),(2,'two'),(3,'three');
CREATE TABLE "odd""table"(id INTEGER PRIMARY KEY, value TEXT);
INSERT INTO "odd""table" SELECT * FROM items;
]])
  assert(vim.v.shell_error == 0, "fixture seed failed")
  calls, notices = {}, {}
  local ok, err = pcall(run)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function rows(source)
  return assert(db.query("SELECT id, value FROM " .. (source or "items") .. " ORDER BY id", url)).rows
end

local function preview(sql, count, source)
  grip.open(sql, url, { from_pad = true })
  local session = assert(view._sessions[vim.api.nvim_get_current_buf()],
    "no preview: " .. table.concat(notices, "; "))
  local pending = assert(session.pending_mutation, "no pending mutation")
  eq(pending.sql, sql, "original SQL retained")
  eq(pending.row_count, count, "affected row count")
  eq(rows(source), initial, "preview must not write")
  eq(calls, {}, "preview must not execute mutation")
  eq(notices, {}, "preview warnings/errors")
  return session
end

local function invoke(action)
  local mapping = vim.fn.maparg(keys.get(action), "n", false, true)
  assert(type(mapping.callback) == "function", "missing mapping " .. action)
  mapping.callback()
end

local function apply(sql, session, expected, source)
  invoke("grid_apply")
  eq(calls, { sql }, "apply executes exact original SQL once")
  eq(rows(source), expected, "final rows")
  eq(session.pending_mutation, nil, "committed mutation cleared")
  eq(notices, {}, "apply warnings/errors")
end

for _, case in ipairs({
  { source = "items /* target */ AS i", alias = "i", table_name = "items" },
  { source = "items AS /* alias */ i", alias = "i", table_name = "items" },
  { source = "items AS somewhere", alias = "somewhere", table_name = "items" },
  { source = "items AS option", alias = "option", table_name = "items" },
  { source = 'items AS "WHERE hidden"', alias = '"WHERE hidden"', table_name = "items" },
  { source = 'items AS "set hidden"', alias = '"set hidden"', table_name = "items" },
  { source = '"main"."items" AS i', alias = "i", table_name = "main.items" },
  { source = '"odd""table" AS i', alias = "i", table_name = 'odd"table', read_source = '"odd""table"' },
}) do
  for _, verb in ipairs({ "UPDATE", "DELETE" }) do
    test(verb .. " source " .. case.source, function()
      local sql = verb == "UPDATE"
        and ("UPDATE " .. case.source .. " SET value='changed' WHERE " .. case.alias .. ".id=2")
        or ("DELETE FROM " .. case.source .. " WHERE " .. case.alias .. ".id=2")
      local session = preview(sql, 1, case.read_source)
      eq(session.pending_mutation.table_name, case.table_name, "base-table metadata")
      eq(session.state.rows[1][1], "2", "selected row")
      if verb == "UPDATE" then
        eq(session.state.changes[1], { value = "changed" }, "literal assignment staged")
        apply(sql, session, { { "1", "one" }, { "2", "changed" }, { "3", "three" } }, case.read_source)
      else
        eq(session.state.deleted[1], true, "selected row marked deleted")
        apply(sql, session, { { "1", "one" }, { "3", "three" } }, case.read_source)
      end
    end)
  end
end

for _, value in ipairs({
  "some WHERE text ORDER BY text LIMIT text",
  "hello,world",
  "it's quoted",
  "first line\nsecond line",
}) do
  test("literal value " .. value, function()
    local sql = "UPDATE items AS i SET value='" .. value:gsub("'", "''") .. "' WHERE i.id=2"
    local session = preview(sql, 1)
    eq(session.state.changes[1], { value = value }, "complete decoded literal staged")
    apply(sql, session, { { "1", "one" }, { "2", value }, { "3", "three" } })
  end)
end

for _, phrase in ipairs({ "one ORDER BY two", "one LIMIT two" }) do
  test("WHERE literal retains " .. phrase, function()
    local sql = "DELETE FROM items AS i WHERE i.id=2 AND '" .. phrase .. "'='" .. phrase .. "'"
    local session = preview(sql, 1)
    apply(sql, session, { { "1", "one" }, { "3", "three" } })
  end)
end

for _, verb in ipairs({ "UPDATE", "DELETE" }) do
  test(verb .. " line comment preserves the following condition", function()
    local sql = verb == "UPDATE" and "UPDATE items AS i SET value='changed'" or "DELETE FROM items AS i"
    sql = sql .. " WHERE i.id=2 -- ignored\n AND i.id=1;"
    local session = preview(sql, 0)
    eq(session.state.rows, {}, "contradictory predicate matches no rows")
    apply(sql, session, initial)
  end)
end

test("line comment between source and alias survives cancel", function()
  local sql = "UPDATE items -- target\n AS i SET value='changed' WHERE i.id=2;"
  local session = preview(sql, 1)
  eq(session.state.changes[1], { value = "changed" }, "update staged")
  invoke("grid_undo")
  eq(rows(), initial, "cancel must not write")
  eq(calls, {}, "cancel must not execute")
  eq(notices, {}, "cancel warnings/errors")
end)

test("SET subquery WHERE is not the mutation WHERE", function()
  local sql = "UPDATE items AS i SET value=(SELECT value FROM items WHERE id=1) WHERE i.id=2"
  local session = preview(sql, 1)
  eq(session.state.rows[1][1], "2", "outer predicate chooses row")
  eq(session.state.changes, {}, "expression is not presented as a literal result")
  apply(sql, session, { { "1", "one" }, { "2", "one" }, { "3", "three" } })
end)

test("nested ORDER BY and LIMIT remain inside WHERE", function()
  local sql = "DELETE FROM items AS i WHERE i.id IN (SELECT id FROM items ORDER BY id LIMIT 1)"
  local session = preview(sql, 1)
  eq(session.state.rows[1][1], "1", "subquery selects first row")
  apply(sql, session, { { "2", "two" }, { "3", "three" } })
end)

test("function commas do not split SET assignments", function()
  local sql = "UPDATE items AS i SET value=printf('%s,%s','hello','world') WHERE i.id=2"
  local session = preview(sql, 1)
  eq(session.state.changes, {}, "computed expression is not staged as text")
  apply(sql, session, { { "1", "one" }, { "2", "hello,world" }, { "3", "three" } })
end)

for _, verb in ipairs({ "UPDATE", "DELETE" }) do
  test(verb .. " RETURNING is kept only in original mutation", function()
    local sql = verb == "UPDATE" and "UPDATE items AS i SET value='changed'" or "DELETE FROM items AS i"
    sql = sql .. " WHERE i.id=2 RETURNING id"
    local session = preview(sql, 1)
    assert(not session.state.sql:find("RETURNING", 1, true), "RETURNING must not enter SELECT")
    local expected = verb == "UPDATE"
      and { { "1", "one" }, { "2", "changed" }, { "3", "three" } }
      or { { "1", "one" }, { "3", "three" } }
    apply(sql, session, expected)
  end)
end

test("NULL is staged as NULL, not the word NULL", function()
  local sql = "UPDATE items AS i SET value=NULL WHERE i.id=2"
  local session = preview(sql, 1)
  eq(session.state.changes[1].value, data.NULL_SENTINEL, "NULL staging")
  invoke("grid_apply")
  eq(calls, { sql }, "original NULL SQL applied once")
  local result = assert(db.query("SELECT id, value IS NULL FROM items ORDER BY id", url))
  eq(result.rows, { { "1", "0" }, { "2", "1" }, { "3", "0" } }, "only selected row changed to NULL")
  eq(notices, {}, "NULL apply warnings/errors")
end)

test("qualified SET column stages the target column in MySQL-style preview", function()
  -- The SELECT preview is real SQLite; this MySQL assignment is not executed.
  local sql = "UPDATE items AS i SET i.value='changed' WHERE i.id=2"
  local session = preview(sql, 1)
  eq(session.state.changes[1], { value = "changed" }, "qualification removed from target column")
  invoke("grid_undo")
  eq(calls, {}, "dialect-only mutation was not executed")
  eq(rows(), initial, "preview-only dialect case does not write")
end)

for _, sql in ipairs({
  "UPDATE items i JOIN items j ON i.id=j.id SET i.value='changed' WHERE i.id=2",
  "DELETE FROM items AS i USING items AS j WHERE i.id=j.id",
  "UPDATE items SET value='changed' WHERE id=2; DELETE FROM items WHERE id=1",
}) do
  test("unsupported preview does not guess affected rows: " .. sql, function()
    grip.open(sql, url, { from_pad = true })
    for _, session in pairs(view._sessions) do
      assert(not session.pending_mutation, "unsupported SQL must not open a guessed preview")
    end
    eq(calls, {}, "unsupported preview must not execute")
    eq(rows(), initial, "unsupported preview must not write")
    assert(#notices > 0, "unsupported SQL must explain why preview is unavailable")
  end)
end

test("ordinary OPTION column in a SET expression does not terminate the statement", function()
  vim.fn.system({ "sqlite3", fixture }, "ALTER TABLE items ADD COLUMN option TEXT DEFAULT 'copied'")
  assert(vim.v.shell_error == 0, "add option column")
  local sql = "UPDATE items SET value=option WHERE id=2"
  local session = preview(sql, 1)
  eq(session.state.changes, {}, "column expression is not staged as a literal")
  apply(sql, session, { { "1", "one" }, { "2", "copied" }, { "3", "three" } })
end)

test("unaliased UPDATE remains executable", function()
  local sql = "UPDATE items SET value='changed' WHERE id=2"
  local session = preview(sql, 1)
  eq(session.state.changes[1], { value = "changed" }, "unaliased assignment unchanged")
  apply(sql, session, { { "1", "one" }, { "2", "changed" }, { "3", "three" } })
end)

test("unaliased DELETE remains executable", function()
  local sql = "DELETE FROM items WHERE id=2"
  local session = preview(sql, 1)
  apply(sql, session, { { "1", "one" }, { "3", "three" } })
end)

for _, case in ipairs({
  { set = "value='fake', value=upper(value)", expected = "TWO" },
  { set = "value='fake', value='last'", staged = "last", expected = "last" },
  { set = "VaLuE='mixed'", staged = "mixed", expected = "mixed" },
  { set = "value=''", staged = "", expected = "" },
}) do
  test("UPDATE assignment semantics: " .. case.set, function()
    local sql = "UPDATE items AS i SET " .. case.set .. " WHERE i.id=2"
    local session = preview(sql, 1)
    eq(session.state.changes, case.staged ~= nil and { { value = case.staged } } or {},
      "only the final known literal is staged")
    apply(sql, session, { { "1", "one" }, { "2", case.expected }, { "3", "three" } })
  end)
end

test("OUTPUT is an ordinary SQLite column", function()
  assert(db.execute("ALTER TABLE items ADD COLUMN output TEXT", url))
  calls = {}
  local sql = "UPDATE items SET output='known' WHERE id=2"
  local session = preview(sql, 1)
  eq(session.state.changes[1], { output = "known" }, "OUTPUT literal staged")
  apply(sql, session, initial)
  eq(assert(db.query("SELECT output FROM items WHERE id=2", url)).rows, { { "known" } },
    "actual OUTPUT column changed")
end)

for _, case in ipairs({
  { sql = "/* target */ UPDATE items AS i SET value='changed' WHERE i.id=2", verb = "UPDATE" },
  { sql = "-- target\nDELETE FROM items AS i WHERE i.id=2", verb = "DELETE" },
}) do
  test("leading comments dispatch " .. case.verb, function()
    local session = preview(case.sql, 1)
    apply(case.sql, session, case.verb == "DELETE" and { { "1", "one" }, { "3", "three" } }
      or { { "1", "one" }, { "2", "changed" }, { "3", "three" } })
  end)
end

for _, begin in ipairs({ "BEGIN", "begin", "BEGIN IMMEDIATE" }) do
  test("transaction preview preserves complete original SQL: " .. begin, function()
    local sql = begin .. ";\nUPDATE items AS i SET value='changed' WHERE i.id=2;\ncommit; -- end"
    local session = preview(sql, 1)
    apply(sql, session, { { "1", "one" }, { "2", "changed" }, { "3", "three" } })
  end)
end

for _, sql in ipairs({
  "BEGIN; UPDATE items SET value='changed' WHERE id=2; ROLLBACK;",
  "begin; UPDATE items SET value='changed' WHERE id=2; rollback;",
  "BEGIN; UPDATE items SET value='changed'; DELETE FROM items; COMMIT;",
}) do
  test("transaction must not drop rollback or additional statements: " .. sql, function()
    grip.open(sql, url, { from_pad = true })
    eq(calls, {}, "rejected block never executes")
    eq(rows(), initial, "rejected block leaves database unchanged")
    assert(#notices > 0, "unsupported block must report rejection")
    for _, session in pairs(view._sessions) do
      eq(session.pending_mutation, nil, "no misleading pending statement")
    end
  end)
end

for _, sql in ipairs({
  'WITH "delete" AS (SELECT 1) SELECT * FROM "delete"',
  "WITH replace AS (SELECT 1) SELECT * FROM replace",
  "WITH t AS (SELECT 1 AS replace) SELECT replace FROM t",
  "WITH t AS (SELECT replace('update','up','down')) SELECT * FROM t",
  "WITH t AS (SELECT 1 /* INSERT INTO fake */) SELECT * FROM t",
}) do
  test("read-only CTE keywords are not mutation commands: " .. sql, function()
    local spec, _, _, mutation = grip._resolve_query(sql, 100, "sqlite")
    assert(spec and spec.is_raw, "ordinary CTE stays a query")
    eq(mutation, nil, "no false mutation")
  end)
end

test("WITH REPLACE retains confirmed original-SQL execution", function()
  local sql = "WITH src AS (SELECT 2 AS id, 'changed' AS value) REPLACE INTO items SELECT * FROM src;"
  local spec, _, _, mutation = grip._resolve_query(sql, 100, "sqlite")
  eq(spec, nil, "mutating CTE is not wrapped in SELECT")
  eq(mutation, sql, "complete CTE retained")
  grip.open(sql, url, { from_pad = true })
  eq(calls, { sql }, "confirmed CTE executes once")
  eq(rows(), { { "1", "one" }, { "2", "changed" }, { "3", "three" } }, "REPLACE result")
  eq(notices, {}, "CTE warnings/errors")
end)

for _, case in ipairs({
  { set = "value='fake', (value,output)=('actual','third')", expected = "actual" },
  { set = "(value,output)=('actual','third'), value='last'", staged = "last", expected = "last" },
}) do
  test("tuple assignments invalidate earlier scalar predictions: " .. case.set, function()
    assert(db.execute("ALTER TABLE items ADD COLUMN output TEXT", url))
    calls = {}
    local sql = "UPDATE items SET " .. case.set .. " WHERE id=2"
    local session = preview(sql, 1)
    eq(session.state.changes, case.staged and { { value = case.staged } } or {},
      "only a later scalar literal can be predicted after a tuple assignment")
    apply(sql, session, { { "1", "one" }, { "2", case.expected }, { "3", "three" } })
    eq(assert(db.query("SELECT output FROM items WHERE id=2", url)).rows, { { "third" } },
      "tuple's other column is evaluated by SQLite")
  end)
end

for _, case in ipairs({
  { sql = "UPDATE items SET items.value='composite' WHERE id=2", expected = {} },
  {
    sql = "UPDATE items SET value='scalar', items.value='composite' WHERE id=2",
    expected = { { column = "value", value = "scalar" } },
  },
  {
    sql = "UPDATE items AS i SET value='scalar', i.value='composite' WHERE id=2",
    expected = { { column = "value", value = "scalar" } },
  },
  {
    sql = 'UPDATE items AS "I" SET value=\'scalar\', "I".nested.value=\'composite\' WHERE id=2',
    expected = { { column = "value", value = "scalar" } },
  },
}) do
  test("PostgreSQL composite SET targets are not alias-qualified scalars: " .. case.sql, function()
    local tokens = require("dadbod-grip.sql_tokens").tokenize(case.sql, "postgresql", true)
    local parsed = assert(require("dadbod-grip.mutation").parse(case.sql, tokens, "postgresql", "UPDATE"))
    eq(parsed.assignments, case.expected, "composite updates must not stage a same-named scalar field")
  end)
end

for _, case in ipairs({
  {
    set = "items.value='property'",
    expected = { { column = "items", known = false } },
  },
  {
    set = "value='scalar', items.value='property'",
    expected = { { column = "value", value = "scalar" }, { column = "items", known = false } },
  },
  {
    set = "items='initial', items.value='property'",
    expected = { { column = "items", value = "initial" }, { column = "items", known = false } },
  },
  {
    set = "Value=1, value=2, Value=3",
    expected = {
      { column = "Value", value = "1" }, { column = "value", value = "2" },
      { column = "Value", value = "3" },
    },
  },
  {
    set = "Value='literal', value=UPPER(value)",
    expected = { { column = "Value", value = "literal" }, { column = "value", known = false } },
  },
  {
    set = "value=UPPER(value), Value='literal'",
    expected = { { column = "value", known = false }, { column = "Value", value = "literal" } },
  },
}) do
  test("SQL Server assignment order survives until metadata resolution: " .. case.set, function()
    local sql = "UPDATE items SET " .. case.set .. " WHERE id=2"
    local tokens = require("dadbod-grip.sql_tokens").tokenize(sql, "sqlserver", true)
    local parsed = assert(require("dadbod-grip.mutation").parse(sql, tokens, "sqlserver", "UPDATE"))
    eq(parsed.assignments, case.expected, "preserve exact columns and unknown assignments in order")
  end)
end

test("PostgreSQL subscripts invalidate earlier scalar predictions", function()
  local sql = "UPDATE items SET value='fake', value[1]='actual' WHERE id=2"
  local tokens = require("dadbod-grip.sql_tokens").tokenize(sql, "postgresql", true)
  local parsed = assert(require("dadbod-grip.mutation").parse(sql, tokens, "postgresql", "UPDATE"))
  eq(parsed.assignments, {}, "an array subscript can overwrite the earlier whole-column value")
end)

for _, case in ipairs({
  { begin = "BEGIN IMMEDIATE TRANSACTION", finish = "COMMIT TRANSACTION" },
  { begin = "BEGIN", finish = "END" },
}) do
  test("transaction keyword variants retain original SQL: " .. case.begin .. "/" .. case.finish, function()
    local sql = case.begin .. "; UPDATE items SET value='changed' WHERE id=2; " .. case.finish .. ";"
    local session = preview(sql, 1)
    apply(sql, session, { { "1", "one" }, { "2", "changed" }, { "3", "three" } })
  end)
end

cleanup()
db.execute, vim.notify, vim.fn.confirm = execute, notify, confirm
vim.cmd.cd(vim.fn.fnameescape(cwd))
vim.o.runtimepath = rtp
vim.fn.delete(fixture_dir, "rf")
print(string.format("\nmutation_parsing_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
