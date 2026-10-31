-- Guard actual SQLite storage classes, not just their display spelling.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local eq = H.eq

for _, declared in ipairs({ "BLOB", "TEXT" }) do
  H.test("F01 untouched actual BLOB survives update Undo in " .. declared .. " column", function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload " .. declared .. ",note TEXT);"
      .. "INSERT INTO t VALUES(1,X'4142','before')")
    local buf, session = c.open("t")
    c.edit(buf, session, 1, "note", "ours")
    c.action("grid_apply")
    eq(c.rows("SELECT typeof(payload),hex(payload),note FROM t"), { { "blob", "4142", "ours" } })
    c.action("grid_undo")
    eq(c.rows("SELECT typeof(payload),hex(payload),note FROM t"), { { "blob", "4142", "before" } })
  end)
end

H.test("F02 untyped numeric storage classes survive unrelated batch edit Undo", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload,note TEXT);"
    .. "INSERT INTO t VALUES(1,7,'first'),(2,7.5,'second'),(3,'7','third')")
  local expected = c.rows("SELECT id,typeof(payload),quote(payload),note FROM t ORDER BY id")
  local buf, session = c.open("t")
  for row = 1, 3 do c.edit(buf, session, row, "note", "ours" .. row) end
  c.action("grid_apply")
  c.action("grid_undo")
  eq(c.rows("SELECT id,typeof(payload),quote(payload),note FROM t ORDER BY id"), expected)
end)

H.test("F03 deleted BLOB reinserted by Undo remains BLOB with exact bytes", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT,note TEXT);"
    .. "INSERT INTO t VALUES(1,X'004142ff','before')")
  local buf, session = c.open("t")
  session.on_delete(buf, 1)
  c.action("grid_apply")
  eq(c.scalar("SELECT count(*) FROM t"), "0")
  c.action("grid_undo")
  eq(c.rows("SELECT id,typeof(payload),hex(payload),note FROM t"), { { "1", "blob", "004142FF", "before" } })
end)

H.test("F04 storage-class-only concurrent change conflicts with committed Undo", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload BLOB,note TEXT);"
    .. "INSERT INTO t VALUES(1,X'4142','before')")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "note", "ours")
  c.action("grid_apply")
  local count = #(session._txn_undo_stack or {})
  assert(count > 0, "committed edit needs reversal history")
  c.exec("UPDATE t SET payload='AB' WHERE id=1")
  c.action("grid_undo")
  eq(c.rows("SELECT typeof(payload),hex(payload),note FROM t"), { { "text", "4142", "ours" } })
  eq(#session._txn_undo_stack, count, "storage type is part of the guarded snapshot")
end)

H.test("F05 REAL value precision survives edit and committed Undo", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload REAL);"
    .. "INSERT INTO t VALUES(1,0.84551240822557006)")
  local original = c.scalar("SELECT printf('%!.26g',payload) FROM t")
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "payload", "1.5")
  c.action("grid_apply")
  c.action("grid_undo")
  eq(c.scalar("SELECT printf('%!.26g',payload) FROM t"), original, "do not serialize the preimage through display precision")
end)

for _, declared in ipairs({ "BLOB", "TEXT" }) do
  H.test("F06 stale BLOB key cannot target same-byte TEXT replacement in " .. declared .. " column", function(c)
    c.exec("CREATE TABLE t(id " .. declared .. " PRIMARY KEY NOT NULL,payload TEXT);"
      .. "INSERT INTO t VALUES(X'4142','before')")
    local buf, session = c.open("t")
    c.exec("DELETE FROM t WHERE id=X'4142'; INSERT INTO t VALUES('AB','before')")
    c.edit(buf, session, 1, "payload", "ours")
    c.action("grid_apply")
    eq(c.rows("SELECT typeof(id),hex(id),payload FROM t"), { { "text", "4142", "before" } },
      "display spelling alone cannot prove primary-key storage identity")
  end)
end

H.finish("safety_adversarial_storage_spec")
