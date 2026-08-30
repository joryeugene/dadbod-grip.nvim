local grip = require("dadbod-grip")
local keymaps = require("dadbod-grip.keymaps")
local filetypes = require("dadbod-grip.filetypes")

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

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function sorted_keys(set)
  local values = {}
  for key in pairs(set) do values[#values + 1] = key end
  table.sort(values)
  return values
end

local function list_set(values)
  local set = {}
  for _, value in ipairs(values) do set[value] = true end
  return set
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected),
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local readme = read("README.md")
local help = read("doc/dadbod-grip.txt")

test("public commands match lazy triggers and both manuals", function()
  grip.setup({})
  local actual = {}
  for name in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    if name:match("^Grip") then actual[name] = true end
  end

  local lazy_commands = dofile("lazy.lua")[1].cmd
  eq(sorted_keys(actual), sorted_keys(list_set(lazy_commands)), "lazy command triggers")

  local help_commands = {}
  for name in help:gmatch("\n:(Grip[%a]*)[^%a]") do help_commands[name] = true end
  eq(sorted_keys(actual), sorted_keys(help_commands), "help command sections")

  for name in pairs(actual) do
    assert(readme:find("`:" .. name, 1, true), "README command table missing :" .. name)
  end
end)

test("documented default keymap registry exactly matches code", function()
  local start = assert(help:find("*grip-keymaps-cfg*", 1, true))
  local finish = assert(help:find("No default keymaps are set outside", start, true))
  local section = help:sub(start, finish)
  local documented = {}
  for action, key in section:gmatch("([a-z][a-z0-9_]*)%s*=%s*\"([^\"]+)\"") do
    documented[action] = key
  end
  eq(documented, keymaps.defaults, "default keymaps")
  eq(documented.grid_fill, "gA", "grid gA is row fill")
  eq(documented.qpad_ai, "gA", "query-pad gA is SQL generation")
end)

local function documented_extensions(text)
  local line = assert(text:match("Supported extensions:%s*([^\n]+)"))
  local extensions = {}
  for ext in line:gmatch("%.[%w]+") do extensions[#extensions + 1] = ext end
  return extensions
end

test("supported extension lists match the shared code registry", function()
  eq(documented_extensions(readme), filetypes.extensions, "README extensions")
  eq(documented_extensions(help), filetypes.extensions, "help extensions")
end)

test("removed commands and stale installation/security claims stay gone", function()
  for _, stale in ipairs({ "GripPick", "GripNew", 'version = "*"',
      "password IS visible", "committed to the repo" }) do
    assert(not readme:find(stale, 1, true), "README contains stale text: " .. stale)
    assert(not help:find(stale, 1, true), "help contains stale text: " .. stale)
  end
  assert(readme:find("invocation-scoped DuckDB secret", 1, true), "DuckDB secret behavior missing")
  assert(help:find("invocation-scoped temporary DuckDB secrets", 1, true), "help secret behavior missing")
end)

test("README uses the repository's canonical documentation URL", function()
  assert(readme:find("https://jorypestorious.com/dadbod-grip-web/", 1, true))
  assert(not readme:find("joryeugene.github.io/dadbod-grip-web", 1, true))
end)

print(string.format("\ndocs_contract_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
