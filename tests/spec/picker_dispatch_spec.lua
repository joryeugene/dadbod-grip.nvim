--- picker_dispatch_spec.lua: tests for grip_picker.pick() dispatch logic

local grip = require("dadbod-grip")
local grip_picker = require("dadbod-grip.grip_picker")

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

--- Stub: tracks which function was called

local called_builtin = false
local called_backend = false
local orig_open = grip_picker.open

local function reset()
  called_builtin = false
  called_backend = false
end

--- Mock open to track calls without creating UI
local function mock_open()
  grip_picker.open = function()
    called_builtin = true
  end
end

local function restore_open()
  grip_picker.open = orig_open
end

--- Tests

test("pick() calls builtin open when picker=builtin", function()
  grip.setup({ picker = "builtin" })
  reset()
  mock_open()
  grip_picker.pick({ items = { "a", "b" } })
  restore_open()
  truthy(called_builtin, "builtin called")
end)

test("pick() falls back to builtin when backend not installed", function()
  grip.setup({ picker = "telescope" })
  reset()
  mock_open()
  grip_picker.pick({ items = { "a", "b" } })
  restore_open()
  truthy(called_builtin, "fallback to builtin")
end)

test("pick() falls back to builtin when opts.actions present", function()
  grip.setup({ picker = "telescope" })
  reset()
  mock_open()
  grip_picker.pick({
    items = { "a" },
    actions = { { key = "M", label = "M:mask", fn = function() end } },
  })
  restore_open()
  truthy(called_builtin, "actions force builtin")
end)

test("pick() dispatches to backend module when available", function()
  grip.setup({ picker = "telescope" })
  reset()
  mock_open()

  --- Temporarily inject a fake backend into package.loaded
  local fake_backend = {
    open = function()
      called_backend = true
    end,
  }
  package.loaded["dadbod-grip.pickers.telescope"] = fake_backend

  grip_picker.pick({ items = { "a", "b" } })

  package.loaded["dadbod-grip.pickers.telescope"] = nil
  restore_open()

  eq(called_backend, true, "backend dispatched")
  eq(called_builtin, false, "builtin not called")
end)

test("pick() with empty actions list dispatches to backend", function()
  grip.setup({ picker = "snacks" })
  reset()
  mock_open()

  local fake_backend = {
    open = function()
      called_backend = true
    end,
  }
  package.loaded["dadbod-grip.pickers.snacks"] = fake_backend

  grip_picker.pick({ items = { "x" }, actions = {} })

  package.loaded["dadbod-grip.pickers.snacks"] = nil
  restore_open()

  eq(called_backend, true, "empty actions dispatches to backend")
  eq(called_builtin, false, "builtin not called")
end)

--- Restore defaults
grip.setup({})

--- Summary
print(string.format("\npicker_dispatch_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
