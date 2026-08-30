-- palette_spec.lua: unit tests for palette.lua
-- Verifies action registry, context filtering, and M.register extension.

local palette = require("dadbod-grip.palette")

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

local function gt(a, b, msg)
  assert(a > b, (msg or "") .. ": expected > " .. tostring(b) .. ", got " .. tostring(a))
end

-- ── M.register ────────────────────────────────────────────────────────────

test("register: accepts valid action", function()
  -- Should not throw
  palette.register({
    label    = "[test]    Custom action",
    key      = "gZ",
    desc     = "A test action",
    contexts = { "grid" },
    fn       = function() end,
  })
end)

test("register: requires label", function()
  local ok = pcall(palette.register, { fn = function() end })
  eq(ok, false, "should error without label")
end)

test("register: requires fn", function()
  local ok = pcall(palette.register, { label = "test" })
  eq(ok, false, "should error without fn")
end)

-- ── M.open: action shape verification ─────────────────────────────────────
-- We intercept grip_picker.open to inspect the actions list without opening UI.

local captured = nil
local original_picker_open

-- Monkey-patch grip_picker.open for inspection
local grip_picker = require("dadbod-grip.grip_picker")
original_picker_open = grip_picker.open
grip_picker.open = function(opts)
  captured = opts
end

test("open('grid'): returns actions table", function()
  captured = nil
  palette.open("grid")
  assert(captured ~= nil, "grip_picker.open should have been called")
  assert(type(captured.items) == "table", "items should be a table")
  gt(#captured.items, 0, "grid actions count")
end)

test("open('query'): returns actions table", function()
  captured = nil
  palette.open("query")
  assert(captured ~= nil, "grip_picker.open should have been called")
  gt(#captured.items, 0, "query actions count")
end)

test("open('sidebar'): returns actions table", function()
  captured = nil
  palette.open("sidebar")
  assert(captured ~= nil, "grip_picker.open should have been called")
  gt(#captured.items, 0, "sidebar actions count")
end)

test("grid has more actions than query (grid-specific actions)", function()
  captured = nil
  palette.open("grid")
  local grid_count = #captured.items

  captured = nil
  palette.open("query")
  local query_count = #captured.items

  assert(grid_count > query_count,
    "grid should have more actions than query: grid=" .. grid_count .. " query=" .. query_count)
end)

test("all actions have label, key, desc, fn", function()
  captured = nil
  palette.open("grid")
  for i, a in ipairs(captured.items) do
    assert(type(a.label) == "string" and #a.label > 0,
      "action[" .. i .. "].label must be a non-empty string")
    assert(type(a.key) == "string",
      "action[" .. i .. "].key must be a string")
    assert(type(a.desc) == "string",
      "action[" .. i .. "].desc must be a string")
    assert(type(a.fn) == "function",
      "action[" .. i .. "].fn must be a function")
  end
end)

test("display function returns string", function()
  captured = nil
  palette.open("grid")
  local a = captured.items[1]
  local disp = captured.display(a)
  assert(type(disp) == "string" and #disp > 0, "display() must return non-empty string")
end)

test("preview function returns table of strings", function()
  captured = nil
  palette.open("grid")
  for _, a in ipairs(captured.items) do
    local lines = captured.preview(a)
    assert(type(lines) == "table", "preview() must return table for: " .. a.label)
    for _, l in ipairs(lines) do
      assert(type(l) == "string", "preview() lines must be strings for: " .. a.label)
    end
  end
end)

test("on_select calls action fn", function()
  captured = nil
  palette.open("grid")
  local called = false
  local test_action = {
    label    = "[test]    Spy action",
    key      = "gZ",
    desc     = "Spy",
    contexts = { "grid" },
    fn       = function() called = true end,
  }
  -- Directly invoke on_select with the test action
  captured.on_select(test_action)
  eq(called, true, "on_select should call action.fn")
end)

test("'all' context actions appear in every context", function()
  -- Help (?) uses contexts={"all"} - should appear in grid, query, sidebar
  local found = { grid = false, query = false, sidebar = false }
  for _, ctx in ipairs({ "grid", "query", "sidebar" }) do
    captured = nil
    palette.open(ctx)
    for _, a in ipairs(captured.items) do
      if a.key == "?" then
        found[ctx] = true
        break
      end
    end
  end
  assert(found.grid,    "Help (?) should appear in grid context")
  assert(found.query,   "Help (?) should appear in query context")
  assert(found.sidebar, "Help (?) should appear in sidebar context")
end)

test("grid-only actions do not appear in query context", function()
  -- Export to file (gX) is grid-only
  captured = nil
  palette.open("query")
  for _, a in ipairs(captured.items) do
    assert(a.key ~= "gX", "gX (export to file) should NOT appear in query context")
  end
end)

test("grid AI action is not offered in the sidebar", function()
  captured = nil
  palette.open("grid")
  local grid_has_ai = false
  for _, action in ipairs(captured.items) do
    if action.key == "A" then grid_has_ai = true end
  end
  assert(grid_has_ai, "grid AI action is missing")

  captured = nil
  palette.open("sidebar")
  for _, action in ipairs(captured.items) do
    assert(action.key ~= "A", "grid-only AI action appeared in the sidebar")
  end
end)

test("M.register: custom action appears in correct context", function()
  palette.register({
    label    = "[test]    Registered test action",
    key      = "gZ",
    desc     = "Custom registered action",
    contexts = { "grid" },
    fn       = function() end,
  })

  -- Should appear in grid
  captured = nil
  palette.open("grid")
  local found_grid = false
  for _, a in ipairs(captured.items) do
    if a.key == "gZ" and a.label:find("Registered test action") then
      found_grid = true
      break
    end
  end
  assert(found_grid, "Registered action should appear in grid context")

  -- Should NOT appear in query (context = {"grid"})
  captured = nil
  palette.open("query")
  local found_query = false
  for _, a in ipairs(captured.items) do
    if a.key == "gZ" and a.label:find("Registered test action") then
      found_query = true
      break
    end
  end
  assert(not found_query, "Grid-only registered action should NOT appear in query context")
end)

-- Restore original
grip_picker.open = original_picker_open

-- ── summary ───────────────────────────────────────────────────────────────

print(string.format("palette_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
