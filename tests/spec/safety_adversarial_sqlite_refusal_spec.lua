-- Actual installed SQLite guard rejection, paired with E01 generic uncertainty.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters, data = require("dadbod-grip.adapters"), require("dadbod-grip.data")
for _, action in ipairs({ "grid_apply", "grid_undo" }) do
  H.test("E06 completed native SQLite guard refusal remains recoverable " .. action, function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'before')")
    local buf, session = c.open("t")
    c.edit(buf, session, 1, "payload", "ours")
    if action == "grid_undo" then c.action("grid_apply") end
    c.exec("UPDATE t SET payload='external' WHERE id=1")
    local original, calls, rejection = adapters.run_cmd, 0, nil
    adapters.run_cmd = function(argv, timeout, opts)
      local out, err, code = original(argv, timeout, opts)
      if argv[1] == "sqlite3" and opts and opts.stdin and opts.stdin:match("^BEGIN") then
        calls = calls + 1
        if code ~= 0 then rejection = err end
      end
      return out, err, code
    end
    local ok, err = pcall(c.action, action)
    adapters.run_cmd = original
    assert(ok, err)
    H.eq(calls, 1, "no automatic retry")
    H.eq(c.scalar("SELECT payload FROM t"), "external", "guard must preserve concurrent data")
    assert(rejection and rejection:find("CHECK constraint failed", 1, true), "native CHECK rejection not exercised")
    assert(not session._write_unknown, "confirmed native rollback was mislabeled as uncertain")
    if action == "grid_apply" then
      assert(data.has_changes(session.state), "safe refusal discarded pending edits")
    else
      H.eq(#session._txn_undo_stack, 1)
      assert(not session._txn_undo_stack[1].outcome_unknown, "known rollback permanently poisoned reversal")
      -- Explicit second user action only after restoring the expected row.
      c.exec("UPDATE t SET payload='ours' WHERE id=1")
      c.action("grid_undo")
      H.eq(c.scalar("SELECT payload FROM t"), "before")
      H.eq(#session._txn_undo_stack, 0)
    end
  end)
end
H.finish("safety_adversarial_sqlite_refusal_spec")
