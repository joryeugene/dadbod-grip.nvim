local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local data, view = require("dadbod-grip.data"), require("dadbod-grip.view")
local eq = H.eq

H.test("U01 generated nonmonotonic key Undo preserves original duplicate payload", function(c)
  c.exec([[CREATE TABLE t(id TEXT PRIMARY KEY NOT NULL DEFAULT 'aa-generated', payload TEXT);
    INSERT INTO t VALUES('zz-original','same')]])
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  c.action("grid_apply")
  eq(c.scalar("SELECT count(*) FROM t"), "2", "clone committed")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t ORDER BY id"), { { "zz-original", "same" } },
    "Undo must remove only the generated row")
end)

H.test("U02 primary-key edit Undo finds the post-write identity", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'first')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "id", "91")
  c.action("grid_apply")
  eq(c.scalar("SELECT id FROM t"), "91")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t"), { { "1", "first" } })
end)

H.test("U03 multiple inserts Undo excludes a concurrent duplicate payload", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'same')")
  local buf, session = c.open("t")
  view.apply_edit(buf, data.insert_rows_with_values(session.state, 1,
    { { id = "2", payload = "same" }, { id = "3", payload = "same" } }))
  c.action("grid_apply")
  c.exec("INSERT INTO t VALUES(99,'same')")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t ORDER BY id"), { { "1", "same" }, { "99", "same" } })
end)

H.test("U04 concurrent edit refuses destructive Undo and retains transaction", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "ours")
  c.action("grid_apply")
  local count = #(session._txn_undo_stack or {})
  assert(count > 0, "successful exact-key mutation needs an Undo entry")
  c.exec("UPDATE t SET payload='external' WHERE id=1")
  c.action("grid_undo")
  eq(c.scalar("SELECT payload FROM t"), "external", "concurrent value must not be overwritten")
  eq(#session._txn_undo_stack, count, "conflict retains the entry")
end)

H.test("U05 zero-effect Undo keeps stack and does not report success", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "ours")
  c.action("grid_apply")
  local count = #(session._txn_undo_stack or {})
  assert(count > 0, "successful exact-key mutation needs an Undo entry")
  c.exec("DELETE FROM t WHERE id=1")
  c.notices = {}
  c.action("grid_undo")
  eq(#session._txn_undo_stack, count, "zero-effect reversal must not consume history")
  assert(not table.concat(c.notices, "\n"):find("Undid transaction", 1, true), "false success notification")
  eq(c.scalar("SELECT count(*) FROM t"), "0")
end)

H.test("U06 composite key edit reverses through all post-write key parts", function(c)
  c.exec([[CREATE TABLE t(tenant TEXT NOT NULL,id TEXT NOT NULL,payload TEXT,PRIMARY KEY(tenant,id));
    INSERT INTO t VALUES('a','1','before'),('b','1','other')]])
  local buf, session = c.open("t")
  local row
  for i, values in ipairs(session.state.rows) do if values[1] == "a" then row = i end end
  assert(row)
  c.edit(buf, session, row, "id", "new")
  c.action("grid_apply")
  c.action("grid_undo")
  eq(c.rows("SELECT tenant,id,payload FROM t ORDER BY tenant"),
    { { "a", "1", "before" }, { "b", "1", "other" } })
end)

H.test("U07 conflicting batch Undo is atomic", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'first'),(2,'second')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "ours1")
  c.edit(buf, session, 2, "payload", "ours2")
  c.action("grid_apply")
  local count = #(session._txn_undo_stack or {})
  c.exec("UPDATE t SET payload='external' WHERE id=2")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t ORDER BY id"), { { "1", "ours1" }, { "2", "external" } })
  eq(#session._txn_undo_stack, count)
end)

H.test("U08 generated 64-bit integer key remains exact through committed Undo", function(c)
  c.exec([[CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT);
    INSERT INTO t VALUES(9007199254740992,'same')]])
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  c.action("grid_apply")
  eq(c.scalar("SELECT id FROM t WHERE id<>9007199254740992"), "9007199254740993", "generated key exceeds float precision")
  c.exec("INSERT INTO t VALUES(9007199254740994,'same')")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t ORDER BY id"),
    { { "9007199254740992", "same" }, { "9007199254740994", "same" } }, "never round or guess the inserted key")
end)

H.test("U09 delete Undo cannot replace a concurrently reused primary key", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
  local buf, session = c.open("t")
  session.on_delete(buf, 1)
  c.action("grid_apply")
  local count = #(session._txn_undo_stack or {})
  assert(count > 0, "committed deletion needs a reversal entry")
  c.exec("INSERT INTO t VALUES(1,'external')")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload FROM t"), { { "1", "external" } })
  eq(#session._txn_undo_stack, count, "conflicted reinsertion must retain history")
end)

H.test("N01 fetched NULL empty text and literal NULL remain distinct", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,''),(2,NULL),(3,'NULL')")
  local _, session = c.open("t")
  eq(data.effective_value(session.state, 1, "payload"), "", "empty text")
  eq(data.effective_value(session.state, 2, "payload"), nil, "SQL NULL")
  eq(data.effective_value(session.state, 3, "payload"), "NULL", "literal NULL")
end)

H.test("N02 blank edit commits empty text rather than NULL", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "")
  c.action("grid_apply")
  eq(c.scalar("SELECT payload IS NULL FROM t"), "0")
  eq(c.scalar("SELECT length(payload) FROM t"), "0")
end)

H.test("N03 empty key never targets the separate NULL-key row", function(c)
  c.exec("CREATE TABLE t(id TEXT PRIMARY KEY,payload TEXT); INSERT INTO t VALUES('','empty-key'),(NULL,'null-key')")
  local buf, session = c.open("t")
  local row
  for i, values in ipairs(session.state.rows) do if values[2] == "empty-key" then row = i end end
  assert(row)
  c.edit(buf, session, row, "payload", "changed")
  c.action("grid_apply")
  eq(c.scalar("SELECT payload FROM t WHERE id IS NULL"), "null-key", "never mutate the other row")
  eq(c.scalar("SELECT payload FROM t WHERE id=''"), "changed", "blank-key identity is exact")
end)

H.test("N04 committed Undo restores empty text rather than NULL", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "ours")
  c.action("grid_apply")
  c.action("grid_undo")
  eq(c.scalar("SELECT payload IS NULL FROM t"), "0")
  eq(c.scalar("SELECT length(payload) FROM t"), "0")
end)

H.test("N05 clone preserves empty text payload", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'')")
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  c.action("grid_apply")
  eq(c.scalar("SELECT count(*) FROM t WHERE payload=''"), "2")
  eq(c.scalar("SELECT count(*) FROM t WHERE payload IS NULL"), "0")
end)

H.test("N06 legacy data sentinel bytes are ordinary user text", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
  local _, session = c.open("t")
  local marker = "\0NULL\0"
  local staged = data.add_change(session.state, 1, "payload", marker)
  eq(data.effective_value(staged, 1, "payload"), marker)
end)

H.test("N07 exports distinguish fetched empty NULL and literal NULL", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,''),(2,NULL),(3,'NULL')")
  local _, session = c.open("t")
  local rows = {}
  for i = 1, 3 do rows[i] = { data.effective_value(session.state, i, "payload") } end
  local json = vim.json.decode(table.concat(view._format_export(rows, { "payload" }, "json", "t"), "\n"))
  eq(json[1].payload, "")
  eq(json[2].payload, vim.NIL)
  eq(json[3].payload, "NULL")
  local statements = view._format_export(rows, { "payload" }, "sql", "exported")
  c.exec("CREATE TABLE exported(payload TEXT); " .. table.concat(statements, "\n"))
  eq(c.scalar("SELECT count(*) FROM exported WHERE payload=''"), "1")
  eq(c.scalar("SELECT count(*) FROM exported WHERE payload IS NULL"), "1")
  eq(c.scalar("SELECT count(*) FROM exported WHERE payload='NULL'"), "1")
end)

H.test("N08 DuckDB fetch preserves empty text NULL and literal NULL", function(c)
  assert(vim.fn.executable("duckdb") == 1, "independent DuckDB acceptance needs its installed CLI")
  c.url = "duckdb:" .. c.root .. "/case.duckdb"
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload VARCHAR); INSERT INTO t VALUES(1,''),(2,NULL),(3,'NULL')")
  local _, session = c.open("t")
  eq(data.effective_value(session.state, 1, "payload"), "")
  eq(data.effective_value(session.state, 2, "payload"), nil)
  eq(data.effective_value(session.state, 3, "payload"), "NULL")
end)

H.test("N09 CSV exports encode empty NULL and literal NULL distinctly", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,''),(2,NULL),(3,'NULL')")
  local _, session = c.open("t")
  local rows = {}
  for i = 1, 3 do rows[i] = { data.effective_value(session.state, i, "payload") } end
  local lines = view._format_export(rows, { "payload" }, "csv", "t")
  assert(lines[2] ~= lines[3], "CSV conflates empty text with SQL NULL")
  assert(lines[3] ~= lines[4], "CSV conflates SQL NULL with literal NULL text")
  assert(lines[2] ~= lines[4], "CSV conflates empty text with literal NULL text")
end)

H.test("N10 delete Undo restores NULL empty text and literal NULL independently", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,NULL),(2,''),(3,'NULL')")
  local buf, session = c.open("t")
  for row = 1, 3 do session.on_delete(buf, row) end
  c.action("grid_apply")
  eq(c.scalar("SELECT count(*) FROM t"), "0")
  c.action("grid_undo")
  eq(c.rows("SELECT id,payload IS NULL,quote(payload) FROM t ORDER BY id"),
    { { "1", "1", "NULL" }, { "2", "0", "''" }, { "3", "0", "'NULL'" } })
end)

for _, undo in ipairs({ false, true }) do
  H.test("N11 quoted WHERE payload survives " .. (undo and "Undo" or "forward edit"), function(c)
    local literal = "plain WHERE text"
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'"
      .. (undo and literal or "before") .. "'),(2,'other')")
    local buf, session = c.open("t")
    c.edit(buf, session, 1, "payload", undo and "changed" or literal)
    c.action("grid_apply")
    if undo then c.action("grid_undo") end
    eq(c.rows("SELECT id,payload FROM t ORDER BY id"), { { "1", literal }, { "2", "other" } })
  end)
end

H.test("N12 quoted WHERE identifier remains a column name during edit", function(c)
  c.exec([[CREATE TABLE t(id INTEGER PRIMARY KEY,"field WHERE name" TEXT); INSERT INTO t VALUES(1,'before')]])
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "field WHERE name", "changed")
  c.action("grid_apply")
  eq(c.rows([[SELECT id,"field WHERE name" FROM t]]), { { "1", "changed" } })
end)

H.finish("safety_adversarial_spec")
