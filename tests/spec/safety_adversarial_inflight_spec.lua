-- Controlled response-order model, not a native outage reproduction.
-- A real SELECT's already-read result is held while one real write commits;
-- its native completion is attested, but its returned response is faulted.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters, data = require("dadbod-grip.adapters"), require("dadbod-grip.data")
for _, action in ipairs({ "grid_apply", "grid_undo" }) do
  H.test("E05 older refresh cannot settle later uncertain " .. action, function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT); INSERT INTO t VALUES(1,'same')")
    local buf, session = c.open("t")
    session.on_clone(buf, 1)
    if action == "grid_undo" then c.action("grid_apply") end
    local original, captured, writes, observed = adapters.run_cmd, false, 0, false
    adapters.run_cmd = function(argv, timeout, opts)
      if argv[1] == "sqlite3" and opts and opts.stdin then
        if not captured and opts.stdin:find("CREATE TEMP VIEW", 1, true) then
          captured = true
          -- Read the old committed snapshot, but hold the API response.
          local out, err, code = original(argv, timeout, opts)
          assert(code == 0, err)
          vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
          c.action(action)
          observed = session._write_unknown and session._write_lifecycle and session._write_lifecycle.settled
          return out, err, code
        elseif opts.stdin:match("^BEGIN") then
          local out, err, code = original(argv, timeout, opts)
          assert(code == 0, err)
          writes = writes + 1
          return out, "synthetic response failure after real commit", 1
        end
      end
      return original(argv, timeout, opts)
    end
    local ok, err = pcall(session.on_refresh, buf)
    adapters.run_cmd = original
    assert(ok, err)
    assert(captured and observed, "fixture did not interleave stale read with an attested uncertain write")
    H.eq(writes, 1, "only one original write, no retry")
    H.eq(c.scalar("SELECT count(*) FROM t"), action == "grid_apply" and "2" or "1")
    assert(session._write_unknown, "older SELECT cleared a newer unknown-outcome marker")
    if action == "grid_apply" then
      H.eq(data.has_changes(session.state), true, "older SELECT discarded the uncertain input")
    else
      H.eq(#session._txn_undo_stack, 1)
      assert(session._txn_undo_stack[1].outcome_unknown, "older SELECT removed uncertain reversal ownership")
    end
  end)
end
H.finish("safety_adversarial_inflight_spec")
