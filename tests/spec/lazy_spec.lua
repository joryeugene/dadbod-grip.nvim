-- lazy_spec.lua: regression tests for lazy.nvim package spec shape.
dofile("tests/minimal_init.lua")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function has(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then return true end
  end
  return false
end

test("lazy.lua returns a list containing one valid plugin spec", function()
  local specs = dofile("lazy.lua")
  assert(type(specs) == "table", "lazy.lua must return a table")
  assert(type(specs[1]) == "table", "top-level lazy.lua return must be a list of plugin specs")
  assert(specs[1][1] == "joryeugene/dadbod-grip.nvim", "spec must include plugin source")
  assert(specs[1].optional == true, "package spec should remain optional")
end)

test("lazy.lua command triggers include every public Grip command", function()
  local specs = dofile("lazy.lua")
  local cmd = specs[1].cmd
  assert(type(cmd) == "table", "cmd must be a command trigger list")
  for _, name in ipairs({
    "Grip", "GripStart", "GripHome", "GripConnect", "GripSchema",
    "GripTables", "GripQuery", "GripSave", "GripLoad", "GripHistory",
    "GripProfile", "GripExplain", "GripAsk", "GripDiff", "GripCreate",
    "GripDrop", "GripRename", "GripProperties", "GripExport", "GripAttach",
    "GripDetach", "GripOpen", "GripToggle", "GripFill", "GripImport",
  }) do
    assert(has(cmd, name), "missing lazy command trigger: " .. name)
  end
end)

print(string.format("\nlazy_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
