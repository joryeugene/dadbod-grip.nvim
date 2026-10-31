-- Fault model, not a native outage reproduction: allow a real fixture commit,
-- then model the client boundary returning an error instead of its receipt.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters, data = require("dadbod-grip.adapters"), require("dadbod-grip.data")
H.test("E01 fault model: after-start failure after real commit is reported unknown", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT); INSERT INTO t VALUES(1,'same')")
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  local original, calls = adapters.run_cmd, 0
  local cause = "synthetic client output failure after commit"
  adapters.run_cmd = function(argv, timeout, opts)
    local stdout, stderr, code = original(argv, timeout, opts)
    if argv[1] == "sqlite3" and opts and opts.stdin and opts.stdin:match("^BEGIN") then
      calls = calls + 1
      assert(code == 0, stderr)
      return stdout, cause, 1
    end
    return stdout, stderr, code
  end
  local ok, err = pcall(c.action, "grid_apply")
  adapters.run_cmd = original
  assert(ok, err)
  H.eq(calls, 1, "no automatic retry")
  H.eq(c.scalar("SELECT count(*) FROM t"), "2", "fixture really committed before injected failure")
  H.eq(data.has_changes(session.state), true, "pending input stays available")
  local errors = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      errors[#errors + 1] = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    end
  end
  local message = table.concat(errors, "\n")
  assert(message:lower():find("unknown", 1, true), "committed fixture was described as an ordinary refusal: " .. message)
  assert(message:find(cause, 1, true), "original failure reason was hidden")
end)
H.finish("safety_adversarial_unknown_outcome_spec")
