-- Controlled native-process capability denial, NOT a reduced-privilege server.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapter, adapters = require("dadbod-grip.adapters.mysql"), require("dadbod-grip.adapters")
H.test("T01 denied temp capability does not submit original read or fallback", function(c)
  local script, marker = c.root .. "/denied.py", "GRIP_REVIEW_ORIGINAL_MUST_NOT_RUN"
  vim.fn.writefile({ "import sys", "sys.stdin.buffer.readline()",
    "sys.stderr.write('ERROR 1044 (42000): synthetic TEMP capability denied\\n')", "sys.exit(1)" }, script)
  local system, run, executable = vim.system, adapters.run_cmd, vim.fn.executable
  local calls, fallback, written = 0, 0, {}
  vim.fn.executable = function(name) return name == "mysql" and 1 or executable(name) end
  adapters.run_cmd = function(...)
    fallback = fallback + 1
    return run(...)
  end
  vim.system = function(argv, opts, callback)
    if argv[1] ~= "mysql" then return system(argv, opts, callback) end
    calls = calls + 1
    if type(opts.stdin) == "string" then written[#written + 1] = opts.stdin end
    local child = system({ "python3", script }, opts, callback)
    return setmetatable({ write = function(_, payload)
      if type(payload) == "string" then written[#written + 1] = payload end
      return child:write(payload)
    end }, { __index = function(_, key)
      if type(child[key]) ~= "function" then return child[key] end
      return function(_, ...) return child[key](child, ...) end
    end })
  end
  local ok, result, err = pcall(adapter.query, "SELECT '" .. marker .. "' AS value", "mysql://fixture@127.0.0.1/review")
  vim.system, adapters.run_cmd, vim.fn.executable = system, run, executable
  assert(ok, result)
  H.eq(result, nil)
  assert(tostring(err):find("synthetic TEMP capability denied", 1, true), "capability failure reason lost")
  H.eq(calls, 1, "do not reconnect/retry a failed native capability probe")
  H.eq(fallback, 0, "do not fall back to the lossy custom path")
  assert(not table.concat(written):find(marker, 1, true), "original read was sent before capability validation")
end)
H.finish("safety_adversarial_mysql_read_fault_spec")
