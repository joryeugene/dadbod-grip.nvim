-- blink_source_spec.lua: unit tests for the native blink.cmp source provider
local blink = require("dadbod-grip.completion.blink")
local completion = require("dadbod-grip.completion")

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

-- Module loads correctly

test("require returns a table", function()
  assert(type(blink) == "table", "should be a table")
end)

test("source.new() returns a provider instance", function()
  local s = blink.new()
  assert(type(s) == "table", "should be a table")
end)

-- source:enabled()

test("enabled returns false when vim.b.db is nil", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = nil
  local s = blink.new()
  eq(s:enabled(), false, "should be disabled")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("enabled returns false when vim.b.db is empty", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = ""
  local s = blink.new()
  eq(s:enabled(), false, "should be disabled")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("enabled returns true when vim.b.db is a URL", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "postgresql://localhost/test"
  local s = blink.new()
  eq(s:enabled(), true, "should be enabled")
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- source:get_trigger_characters()

test("trigger characters include dot", function()
  local s = blink.new()
  local tc = s:get_trigger_characters()
  eq(tc[1], ".", "first trigger char")
end)

-- source:get_completions() with mocked completion.complete

test("table item maps to CompletionItemKind.Module (6)", function()
  local orig = completion.complete
  completion.complete = function() return {{ word = "users", menu = "[table]" }} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "SELECT * FROM u", cursor = { 1, 15 }, bufnr = buf },
    function(r) result = r end
  )

  eq(result.items[1].kind, 6, "Module kind")
  eq(result.items[1].label, "users", "label")

  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("keyword item maps to CompletionItemKind.Keyword (14)", function()
  local orig = completion.complete
  completion.complete = function() return {{ word = "SELECT", menu = "[keyword]" }} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "SEL", cursor = { 1, 3 }, bufnr = buf },
    function(r) result = r end
  )

  eq(result.items[1].kind, 14, "Keyword kind")
  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("column item maps to CompletionItemKind.Field (5)", function()
  local orig = completion.complete
  completion.complete = function() return {{ word = "email", menu = "[column]" }} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "u.e", cursor = { 1, 3 }, bufnr = buf },
    function(r) result = r end
  )

  eq(result.items[1].kind, 5, "Field kind")
  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("items preserve word as label and insertText", function()
  local orig = completion.complete
  completion.complete = function() return {{ word = "orders", menu = "[table]" }} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "o", cursor = { 1, 1 }, bufnr = buf },
    function(r) result = r end
  )

  eq(result.items[1].label, "orders", "label")
  eq(result.items[1].insertText, "orders", "insertText")
  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("callback receives is_incomplete_backward = true", function()
  local orig = completion.complete
  completion.complete = function() return {{ word = "x", menu = "[table]" }} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "x", cursor = { 1, 1 }, bufnr = buf },
    function(r) result = r end
  )

  eq(result.is_incomplete_backward, true, "backward flag")
  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("empty result calls callback with empty items", function()
  local orig = completion.complete
  completion.complete = function() return {} end

  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = "sqlite:test.db"

  local result
  s:get_completions(
    { line = "zzz", cursor = { 1, 3 }, bufnr = buf },
    function(r) result = r end
  )

  eq(#result.items, 0, "no items")
  completion.complete = orig
  vim.b[buf].db = nil
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("no db URL calls callback with empty items", function()
  local s = blink.new()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].db = nil

  local result
  s:get_completions(
    { line = "x", cursor = { 1, 1 }, bufnr = buf },
    function(r) result = r end
  )

  eq(#result.items, 0, "no items without URL")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Summary
print(string.format("\nblink_source_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
