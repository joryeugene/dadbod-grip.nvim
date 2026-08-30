dofile("tests/minimal_init.lua")

local keymaps = require("dadbod-grip.keymaps")
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

local function includes(values, wanted)
  for _, value in ipairs(values) do
    if value == wanted then return true end
  end
  return false
end

test("catalog metadata, defaults, and JSON agree", function()
  local seen = {}
  local defaults = {}
  local valid_surfaces = { grid = true, query_pad = true, sidebar = true, cell_editor = true }
  local valid_modes = { n = true, i = true, x = true }
  for _, record in ipairs(keymaps.catalog) do
    assert(type(record.action) == "string" and record.action:match("^[a-z][a-z0-9_]*$"))
    assert(type(record.default) == "string" and record.default ~= "")
    assert(type(record.description) == "string" and record.description:match("^[A-Z].*[.!?]$"),
      "description is not a complete sentence: " .. tostring(record.description))
    assert(type(record.category) == "string" and record.category ~= "")
    assert(type(record.surfaces) == "table" and #record.surfaces > 0)
    assert(type(record.modes) == "table" and #record.modes > 0)
    assert(record.requires == nil or record.requires == "completion")
    assert(not seen[record.action], "duplicate action: " .. record.action)
    seen[record.action] = true
    defaults[record.action] = record.default
    for _, surface in ipairs(record.surfaces) do assert(valid_surfaces[surface], surface) end
    for _, mode in ipairs(record.modes) do assert(valid_modes[mode], mode) end
  end
  assert(vim.deep_equal(defaults, keymaps.defaults), "defaults were not derived from the catalog")

  local file = table.concat(vim.fn.readfile("keymaps.json"), "\n") .. "\n"
  assert(file == keymaps.to_json(), "keymaps.json is not the deterministic catalog export")
  local decoded = vim.json.decode(file)
  assert(decoded.version == 1 and vim.deep_equal(decoded.keymaps, keymaps.catalog),
    "decoded keymaps.json differs from the Lua catalog")
end)

test("default keys do not collide within a surface and mode", function()
  local seen = {}
  for _, record in ipairs(keymaps.catalog) do
    for _, surface in ipairs(record.surfaces) do
      for _, mode in ipairs(record.modes) do
        local slot = table.concat({ surface, mode, record.default }, "\0")
        assert(not seen[slot], string.format("%s collides with %s on %s %s %s",
          record.action, seen[slot], surface, mode, record.default))
        seen[slot] = record.action
      end
    end
  end
end)

test("binder rejects unknown actions and undeclared placements", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(keymaps.bind, "grid", buf, "missing_action", "n", function() end)
  assert(not ok and tostring(err):find("unknown Dadbod Grip keymap action", 1, true))
  ok, err = pcall(keymaps.bind, "sidebar", buf, "grid_apply", "n", function() end)
  assert(not ok and tostring(err):find("is not declared for sidebar", 1, true))
  ok, err = pcall(keymaps.bind, "grid", buf, "grid_apply", "i", function() end)
  assert(not ok and tostring(err):find("is not declared for mode i", 1, true))
end)

for _, scenario in ipairs({ "default", "remap", "disabled" }) do
  test("actual primary mappings match the catalog: " .. scenario, function()
    local result = vim.system({
      vim.g.grip_test_progpath,
      "--headless",
      "-u", "tests/minimal_init.lua",
      "-l", "tests/fixtures/keymap_contract_integration.lua",
    }, { text = true, env = vim.tbl_extend("force", vim.fn.environ(), {
      GRIP_KEYMAP_SCENARIO = scenario,
    }) }):wait()
    assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  end)
end

test("declared primary actions cover the corrected surfaces", function()
  local function record(action)
    for _, item in ipairs(keymaps.catalog) do
      if item.action == action then return item end
    end
  end
  assert(vim.deep_equal(record("welcome").surfaces, { "grid", "query_pad", "sidebar" }))
  assert(vim.deep_equal(record("schema_browser").surfaces, { "grid", "query_pad", "sidebar" }))
  assert(vim.deep_equal(record("goto_grid").surfaces, { "query_pad", "sidebar" }))
  assert(vim.deep_equal(record("open_notebook").surfaces, { "query_pad", "sidebar" }))
  assert(vim.deep_equal(record("ai").surfaces, { "grid" }))
  assert(includes(record("qpad_complete").modes, "i"))
end)

print(string.format("\nkeymaps_contract_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
