-- INSERT previews through real SQLite, including exact apply/cancel behavior.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data = require("dadbod-grip.db"), require("dadbod-grip.data")
local keys = require("dadbod-grip.keymaps")
local pass, fail = 0, 0
local cwd, rtp = vim.fn.getcwd(), vim.o.runtimepath
local confirm, notify, execute = vim.fn.confirm, vim.notify, db.execute
local fixture_dir = vim.fn.tempname() .. "-insert-preview"
vim.fn.mkdir(fixture_dir, "p")
vim.opt.rtp:prepend(cwd)
vim.cmd.cd(vim.fn.fnameescape(fixture_dir))
local fixture = fixture_dir .. "/probe.sqlite"
local url = "sqlite:" .. fixture
local calls, notices, prompts = {}, {}, {}
local answer = 1
local initial = { { "1", "one", "first" }, { "2", "two", "second" } }

vim.fn.confirm = function(prompt)
  prompts[#prompts + 1] = prompt
  return answer
end
vim.notify = function(message, level)
  if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
end
db.execute = function(sql, ...)
  calls[#calls + 1] = sql
  return execute(sql, ...)
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected),
    message .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
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
CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT, note TEXT DEFAULT 'default');
INSERT INTO items VALUES(1,'one','first'),(2,'two','second');
CREATE TABLE "odd""table"(id INTEGER PRIMARY KEY, value TEXT, note TEXT DEFAULT 'default');
INSERT INTO "odd""table" SELECT * FROM items;
]])
  assert(vim.v.shell_error == 0, "fixture seed failed")
  calls, notices, prompts, answer = {}, {}, {}, 1
  local ok, err = pcall(run)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function rows(source)
  return assert(db.query("SELECT id, coalesce(value,'<NULL>'), coalesce(note,'<NULL>') FROM "
    .. (source or "items") .. " ORDER BY id", url)).rows
end
local function added(...)
  local expected = vim.deepcopy(initial)
  for _, row in ipairs({ ... }) do expected[#expected + 1] = row end
  return expected
end
local function staged(session)
  local result, indices = {}, {}
  for index in pairs(session.state.inserted) do indices[#indices + 1] = index end
  table.sort(indices)
  for _, index in ipairs(indices) do result[#result + 1] = session.state.inserted[index].values end
  return result
end
local function preview(sql, values, source, verb)
  grip.open(sql, url, { from_pad = true })
  local session = assert(view._sessions[vim.api.nvim_get_current_buf()],
    "no preview: " .. table.concat(notices, "; "))
  local pending = assert(session.pending_mutation, "no pending mutation")
  eq(pending.sql, sql, "original SQL retained")
  eq(pending.type, verb or "INSERT", "original statement type")
  eq(rows(source), initial, "preview must not write")
  eq(calls, {}, "preview must not execute")
  eq(notices, {}, "preview warnings/errors")
  eq(staged(session), values or {}, "only known input values are staged")
  if values then
    eq(pending.row_count, #values, "known input row count")
  else
    eq(pending.row_count, nil, "unknown affected count must not become zero")
    eq(pending.current_state, true, "current-state preview marked explicitly")
    assert(session._mutation_title:find("current state", 1, true), "title must identify current state")
  end
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
  { source = "items" },
  { source = "items AS i" },
  { source = "items AS values_alias" },
  { source = 'items AS "x(y)"' },
  { source = 'items AS "i""x"' },
  { source = '"main"."items" AS i', table_name = "main.items" },
  { source = '"odd""table" AS i', table_name = 'odd"table', read_source = '"odd""table"' },
  { source = "items /* VALUES (fake) */ AS /* target */ i" },
  { source = "items -- VALUES (fake)\n AS i" },
}) do
  test("literal INSERT source " .. case.source, function()
    local sql = "INSERT INTO " .. case.source .. " (value,id) VALUES ('three',3);"
    local session = preview(sql, { { value = "three", id = "3" } }, case.read_source)
    eq(session.pending_mutation.table_name, case.table_name or "items", "base-table metadata")
    apply(sql, session, added({ "3", "three", "default" }), case.read_source)
  end)
end

test("strings retain commas, escaped quotes, parentheses, and newlines", function()
  local value = "it's VALUES (not,a,tuple)\nWHERE next"
  local sql = "INSERT INTO items AS i(id,value,note) VALUES(3,'"
    .. value:gsub("'", "''") .. "','tail');"
  local session = preview(sql, { { id = "3", value = value, note = "tail" } })
  apply(sql, session, added({ "3", value, "tail" }))
end)

test("comments around VALUES and tuple fields do not become data", function()
  local sql = "INSERT INTO items AS i (id,value,note) -- VALUES(9,'fake','fake')\n"
    .. "VALUES (3, /* ignored, () */ 'three', -- keep newline\n 'tail');"
  local session = preview(sql, { { id = "3", value = "three", note = "tail" } })
  apply(sql, session, added({ "3", "three", "tail" }))
end)

test("NULL in the middle preserves the following column", function()
  local sql = "INSERT INTO items AS i VALUES(3,NULL,'tail');"
  local session = preview(sql, { { id = "3", value = data.NULL_SENTINEL, note = "tail" } })
  apply(sql, session, added({ "3", "<NULL>", "tail" }))
end)

test("NULL at the start preserves positional values", function()
  local sql = "INSERT INTO items VALUES(NULL,'three','tail');"
  local session = preview(sql, { { id = data.NULL_SENTINEL, value = "three", note = "tail" } })
  apply(sql, session, added({ "3", "three", "tail" }))
end)

test("multiple tuples retain source order", function()
  local sql = "INSERT INTO items(value,id,note) VALUES('three',3,NULL),('four',4,'last');"
  local session = preview(sql, {
    { id = "3", value = "three", note = data.NULL_SENTINEL },
    { id = "4", value = "four", note = "last" },
  })
  apply(sql, session, added({ "3", "three", "<NULL>" }, { "4", "four", "last" }))
end)

test("RETURNING expressions are not additional VALUES tuples", function()
  local sql = "INSERT INTO items AS i(id,value) VALUES(3,'three') RETURNING printf('%s',value);"
  local session = preview(sql, { { id = "3", value = "three" } })
  apply(sql, session, added({ "3", "three", "default" }))
end)

for _, case in ipairs({
  {
    name = "function with commas",
    sql = "INSERT INTO items(id,value) VALUES(3,printf('%s,%s','hello','world'));",
    expected = added({ "3", "hello,world", "default" }),
  },
  {
    name = "scalar subquery",
    sql = "INSERT INTO items(id,value) VALUES(3,(SELECT value FROM items WHERE id=1));",
    expected = added({ "3", "one", "default" }),
  },
  {
    name = "mixed literal and computed tuples",
    sql = "INSERT INTO items(id,value) VALUES(3,'three'),(4,upper('four'));",
    expected = added({ "3", "three", "default" }, { "4", "FOUR", "default" }),
  },
  {
    name = "VALUES compound query",
    sql = "INSERT INTO items(id,value) VALUES(3,'three') UNION ALL SELECT 4,'four';",
    expected = added({ "3", "three", "default" }, { "4", "four", "default" }),
  },
  {
    name = "VALUES compound query with ordering and limit",
    sql = "INSERT INTO items(id,value) VALUES(3,'three') UNION ALL SELECT 4,'four' ORDER BY 1 DESC LIMIT 1;",
    expected = added({ "4", "four", "default" }),
  },
  {
    name = "INSERT SELECT with VALUES-shaped alias",
    sql = "INSERT INTO items AS values_alias(value,id) SELECT s.value,s.id+2 FROM items AS s WHERE s.id=1;",
    expected = added({ "3", "one", "default" }),
  },
  {
    name = "DEFAULT VALUES",
    sql = "INSERT INTO items AS i DEFAULT VALUES;",
    expected = added({ "3", "<NULL>", "default" }),
  },
  {
    name = "UPSERT updates matching row",
    sql = "INSERT INTO items AS i(id,value) VALUES(2,'changed')"
      .. " ON CONFLICT(id) DO UPDATE SET value=excluded.value WHERE i.id=2;",
    expected = { { "1", "one", "first" }, { "2", "changed", "second" } },
  },
  {
    name = "UPSERT false predicate writes nothing",
    sql = "INSERT INTO items AS i(id,value) VALUES(2,'changed')"
      .. " ON CONFLICT(id) DO UPDATE SET value=excluded.value WHERE i.id=1;",
    expected = initial,
  },
  {
    name = "ON CONFLICT DO NOTHING",
    sql = "INSERT INTO items(id,value) VALUES(2,'changed') ON CONFLICT(id) DO NOTHING;",
    expected = initial,
  },
  {
    name = "INSERT OR IGNORE",
    sql = "INSERT OR IGNORE INTO items AS i(id,value) VALUES(2,'changed');",
    expected = initial,
  },
  {
    name = "INSERT OR REPLACE",
    sql = "INSERT OR REPLACE INTO items AS i(id,value) VALUES(2,'changed');",
    expected = { { "1", "one", "first" }, { "2", "changed", "default" } },
  },
  {
    name = "REPLACE with alias",
    sql = "REPLACE INTO items AS i(id,value) VALUES(2,'changed');",
    verb = "REPLACE",
    expected = { { "1", "one", "first" }, { "2", "changed", "default" } },
  },
  {
    name = "REPLACE without alias",
    sql = "REPLACE INTO items(id,value) VALUES(2,'changed');",
    verb = "REPLACE",
    expected = { { "1", "one", "first" }, { "2", "changed", "default" } },
  },
}) do
  test(case.name .. " uses current state until confirmation", function()
    local session = preview(case.sql, nil, nil, case.verb)
    apply(case.sql, session, case.expected)
    assert(#prompts > 0, "apply must require confirmation")
    assert(not prompts[1]:find("0 rows", 1, true), "unknown count must not claim zero affected rows")
    assert(not prompts[1]:find("nil", 1, true), "unknown count must not leak nil")
  end)
end

for _, sql in ipairs({
  "INSERT INTO items(id,value) VALUES(3,'three');",
  "REPLACE INTO items AS i(id,value) VALUES(2,'changed');",
}) do
  test("cancel does not execute: " .. sql, function()
    preview(sql, sql:match("^INSERT") and { { id = "3", value = "three" } } or nil,
      nil, sql:match("^%u+"))
    invoke("grid_undo")
    eq(rows(), initial, "cancel must leave database unchanged")
    eq(calls, {}, "cancel must not execute SQL")
    eq(notices, {}, "cancel warnings/errors")
  end)
end

test("declining confirmation keeps a current-state mutation pending", function()
  local sql = "REPLACE INTO items(id,value) VALUES(2,'changed');"
  local session = preview(sql, nil, nil, "REPLACE")
  answer = 2
  invoke("grid_apply")
  eq(calls, {}, "declined apply must not execute")
  eq(rows(), initial, "declined apply must not write")
  eq(session.pending_mutation.sql, sql, "declined mutation remains pending")
end)

for _, sql in ipairs({
  "INSERT INTO items VALUES(3,'three','tail'); DELETE FROM items;",
  "REPLACE INTO items VALUES(2,'changed','tail'); DELETE FROM items;",
  "INSERT INTO items VALUES(3,'unterminated);",
}) do
  test("reject unsafe statement: " .. sql, function()
    grip.open(sql, url, { from_pad = true })
    for _, session in pairs(view._sessions) do
      assert(not session.pending_mutation, "unsupported SQL must not open a guessed preview")
    end
    eq(calls, {}, "rejection must not execute")
    eq(rows(), initial, "rejection must not write")
    assert(#notices > 0, "rejection must explain why preview is unavailable")
  end)
end

cleanup()
db.execute, vim.notify, vim.fn.confirm = execute, notify, confirm
vim.cmd.cd(vim.fn.fnameescape(cwd))
vim.o.runtimepath = rtp
vim.fn.delete(fixture_dir, "rf")
print(string.format("\ninsert_preview_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
