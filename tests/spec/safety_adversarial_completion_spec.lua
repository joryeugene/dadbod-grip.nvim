-- Additive lifecycle controls. These are controlled client-response models,
-- with real disposable SQLite transactions, not native network outage proofs.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters, data = require("dadbod-grip.adapters"), require("dadbod-grip.data")
H.test("E03 confirmed original completion permits one explicit reconciliatory refresh", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT); INSERT INTO t VALUES(1,'same')")
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  local original, child, done, result, calls = adapters.run_cmd, nil, false, nil, 0
  local ready, release = c.root .. "/ready", c.root .. "/release"
  adapters.run_cmd = function(argv, timeout, opts)
    if argv[1] ~= "sqlite3" or not opts or not opts.stdin or not opts.stdin:find("COMMIT;", 1, true) then
      return original(argv, timeout, opts)
    end
    calls = calls + 1
    assert(calls == 1, "unexpected write retry")
    local barrier = ".shell touch " .. vim.fn.shellescape(ready) .. " && while [ ! -f "
      .. vim.fn.shellescape(release) .. " ]; do sleep 0.01; done\nCOMMIT;"
    local script = opts.stdin:gsub("COMMIT;", function() return "\n" .. barrier end, 1)
    child = vim.system(argv, { stdin = script, text = true, env = opts.env, timeout = 10000 }, function(r)
      result, done = r, true
      if opts.on_complete then opts.on_complete() end
    end)
    if opts.on_start then opts.on_start(child) end
    assert(vim.wait(2000, function() return vim.fn.filereadable(ready) == 1 or done end, 5))
    assert(not done, "writer did not remain pending")
    return "", "command timed out; process completion unknown", 1
  end
  local protected, staged, ok, err
  ok, err = xpcall(function()
    c.action("grid_apply")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
    end
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    session.on_refresh(buf)
    protected = session._write_unknown ~= nil and session._write_unknown ~= false and not done
    staged = data.has_changes(session.state)
  end, debug.traceback)
  adapters.run_cmd = original
  vim.fn.writefile({ "release" }, release)
  if child and not vim.wait(5000, function() return done end, 5) then
    child:kill(15)
    vim.wait(2000, function() return done end, 5)
  end
  assert(ok, err)
  assert(done and result and result.code == 0, "original writer was not cleanly reaped")
  H.eq(calls, 1)
  H.eq(c.scalar("SELECT count(*) FROM t"), "2")
  assert(protected and staged, "pre-completion refresh lost pending ownership/input")
  c.action("grid_refresh")
  assert(not session._write_unknown, "confirmed original exit plus explicit refresh cannot reconcile the grid")
  H.eq(data.has_changes(session.state), false)
  H.eq(#session.state.rows, 2, "refreshed rows must include the original committed write")
end)
H.test("E04 uncertain committed Undo retains its entry and cannot replay", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT); INSERT INTO t VALUES(1,'same')")
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  c.action("grid_apply")
  H.eq(c.scalar("SELECT count(*) FROM t"), "2")
  local count, original, calls = #session._txn_undo_stack, adapters.run_cmd, 0
  c.notices = {}
  adapters.run_cmd = function(argv, timeout, opts)
    local out, err, code = original(argv, timeout, opts)
    if argv[1] == "sqlite3" and opts and opts.stdin and opts.stdin:match("^BEGIN") then
      calls = calls + 1
      assert(code == 0, err)
      return out, "synthetic response failure after reversal commit", 1
    end
    return out, err, code
  end
  local ok, err = pcall(function() c.action("grid_undo"); c.action("grid_undo") end)
  adapters.run_cmd = original
  assert(ok, err)
  H.eq(calls, 1, "never replay an uncertain reversal")
  H.eq(c.scalar("SELECT count(*) FROM t"), "1", "original reversal really committed once")
  H.eq(#session._txn_undo_stack, count, "uncertain entry must not be consumed as success")
  assert(session._txn_undo_stack[count].outcome_unknown, "uncertain entry is still replayable")
  assert(session._write_unknown, "session lost its unknown-outcome marker")
  assert(not table.concat(c.notices, "\n"):find("Undid transaction", 1, true), "false reversal success")
end)
H.finish("safety_adversarial_completion_spec")
