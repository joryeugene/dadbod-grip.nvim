-- config_spec.lua: tests for setup config options (completion, connections_path, etc.)
local grip = require("dadbod-grip")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

-- Config defaults

test("default completion is true", function()
  grip.setup({})
  eq(grip.get_opts().completion, true, "default")
end)

test("explicit completion = true", function()
  grip.setup({ completion = true })
  eq(grip.get_opts().completion, true, "explicit true")
end)

test("completion = false", function()
  grip.setup({ completion = false })
  eq(grip.get_opts().completion, false, "set to false")
end)

test("completion persists across get_opts calls", function()
  grip.setup({ completion = false })
  eq(grip.get_opts().completion, false, "first call")
  eq(grip.get_opts().completion, false, "second call")
end)

test("setup with no args preserves previous completion value", function()
  grip.setup({ completion = true })
  grip.setup()
  eq(grip.get_opts().completion, true, "preserved after no-arg setup")
end)

-- get_opts returns all expected fields

test("get_opts returns limit", function()
  grip.setup({ limit = 50 })
  eq(grip.get_opts().limit, 50, "limit")
end)

test("get_opts returns max_col_width", function()
  grip.setup({ max_col_width = 60 })
  eq(grip.get_opts().max_col_width, 60, "max_col_width")
end)

test("get_opts returns timeout", function()
  grip.setup({ timeout = 5000 })
  eq(grip.get_opts().timeout, 5000, "timeout")
end)

-- connections_path config

test("connections_path defaults to nil", function()
  grip.setup({})
  eq(grip.get_opts().connections_path, nil, "default nil")
end)

test("connections_path accepts a string", function()
  grip.setup({ connections_path = "/home/user/.grip/connections.json" })
  eq(grip.get_opts().connections_path, "/home/user/.grip/connections.json", "string path")
end)

test("connections_path returned by get_opts", function()
  grip.setup({ connections_path = "/tmp/conns.json" })
  local opts = grip.get_opts()
  eq(opts.connections_path, "/tmp/conns.json", "get_opts returns path")
end)

test("connections_path resets to nil on empty setup", function()
  grip.setup({ connections_path = "/tmp/conns.json" })
  grip.setup({})
  eq(grip.get_opts().connections_path, nil, "reset to nil")
end)

--- picker config

test("picker defaults to builtin", function()
  grip.setup({})
  eq(grip.get_opts().picker, "builtin", "default builtin")
end)

test("picker accepts telescope", function()
  grip.setup({ picker = "telescope" })
  eq(grip.get_opts().picker, "telescope", "telescope")
end)

test("picker accepts snacks", function()
  grip.setup({ picker = "snacks" })
  eq(grip.get_opts().picker, "snacks", "snacks")
end)

test("picker resets to builtin on empty setup", function()
  grip.setup({ picker = "telescope" })
  grip.setup({})
  eq(grip.get_opts().picker, "builtin", "reset to builtin")
end)

--- Restore defaults
grip.setup({})

-- Summary
print(string.format("\nconfig_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
