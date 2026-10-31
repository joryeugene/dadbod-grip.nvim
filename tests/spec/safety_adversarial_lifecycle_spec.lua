-- Controlled client-completion fault model, not native outage evidence.
-- Exactly one real SQLite writer is held before COMMIT by a private barrier.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters, data = require("dadbod-grip.adapters"), require("dadbod-grip.data")
for _, refresh in ipairs({ "callback", "mapping" }) do
  H.test("E02 pending real writer survives pre-completion " .. refresh .. " refresh", function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT); INSERT INTO t VALUES(1,'same')")
    local buf, session = c.open("t")
    session.on_clone(buf, 1)
    local original, child, done, exit, calls = adapters.run_cmd, nil, false, nil, 0
    local marker, release = c.root .. "/writer-ready", c.root .. "/writer-release"
    adapters.run_cmd = function(argv, timeout, opts)
      if argv[1] == "sqlite3" and opts and opts.stdin and opts.stdin:find("COMMIT;", 1, true) then
        calls = calls + 1
        assert(calls == 1, "unexpected second writer")
        local barrier = ".shell touch " .. vim.fn.shellescape(marker)
          .. " && while [ ! -f " .. vim.fn.shellescape(release) .. " ]; do sleep 0.01; done\nCOMMIT;"
        local script, replacements = opts.stdin:gsub("COMMIT;", function() return "\n" .. barrier end, 1)
        assert(replacements == 1)
        child = vim.system(argv, { stdin = script, text = true, env = opts.env, timeout = 10000 }, function(result)
          exit, done = result, true
        end)
        assert(vim.wait(2000, function() return vim.fn.filereadable(marker) == 1 or done end, 5), "writer did not reach barrier")
        assert(not done, "writer completed before the modeled timeout")
        return "", "command timed out; process completion unknown", 1
      end
      return original(argv, timeout, opts)
    end
    local unknown_before, unknown_pending, staging_pending, pending_observed
    local ok, err = xpcall(function()
      c.action("grid_apply")
      unknown_before = session._write_unknown ~= nil and session._write_unknown ~= false
      H.eq(c.scalar("SELECT count(*) FROM t"), "1", "real write is not committed yet")
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
      end
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      if refresh == "callback" then session.on_refresh(buf) else c.action("grid_refresh") end
      pending_observed = not done
      unknown_pending = session._write_unknown ~= nil and session._write_unknown ~= false
      staging_pending = data.has_changes(session.state)
    end, debug.traceback)
    adapters.run_cmd = original
    -- Always release and reap this exact child before the fixture is removed,
    -- including when a candidate assertion or callback throws.
    vim.fn.writefile({ "release" }, release)
    if child and not vim.wait(5000, function() return done end, 5) then
      child:kill(15)
      vim.wait(2000, function() return done end, 5)
    end
    assert(ok, err)
    assert(done and exit and exit.code == 0, "controlled writer did not commit cleanly")
    H.eq(calls, 1, "no retry was attempted")
    H.eq(c.scalar("SELECT count(*) FROM t"), "2", "original single writer eventually committed")
    assert(unknown_before and pending_observed, "fault fixture did not observe an unknown live writer")
    assert(unknown_pending, "a pre-completion read forgot the original writer")
    if refresh == "callback" then assert(staging_pending, "unconfirmed callback refresh discarded pending input") end
  end)
end
H.finish("safety_adversarial_lifecycle_spec")
