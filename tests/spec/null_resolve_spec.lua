-- null_resolve_spec.lua: editor NULL sentinel must resolve to real nil.
-- Regression for the `x and nil or y` trap that staged the literal string
-- "__GRIP_NULL__" into the database when a user set a cell to NULL.
local editor = require("dadbod-grip.editor")

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

test("resolve_null: NULL sentinel becomes real nil", function()
  eq(editor.resolve_null(editor.NULL_VALUE), nil, "sentinel -> nil")
end)

test("resolve_null: ordinary values pass through", function()
  eq(editor.resolve_null("done"), "done", "plain string")
  eq(editor.resolve_null(""), "", "empty string untouched (data layer maps it)")
  eq(editor.resolve_null(nil), nil, "nil stays nil")
end)

test("no and/or NULL traps remain in edit flows", function()
  for _, rel in ipairs({ "lua/dadbod-grip/view.lua", "lua/dadbod-grip/init.lua" }) do
    local f = assert(io.open(rel, "r"), "open " .. rel)
    local src = f:read("*a")
    f:close()
    assert(not src:find("editor.NULL_VALUE and nil or", 1, true),
      rel .. " reintroduced the `x == editor.NULL_VALUE and nil or x` trap")
    assert(not src:find("now_null and nil or", 1, true),
      rel .. " reintroduced the `now_null and nil or x` trap")
  end
end)

print(string.format("null_resolve_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
