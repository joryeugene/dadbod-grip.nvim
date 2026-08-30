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
local todo = read("TODO.md")
local changelog = read("CHANGELOG.md")

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

test("onboarding and process-privacy claims match current behavior", function()
  assert(readme:find("**AI SQL generation** via `gA` or `:GripAsk`", 1, true))
  assert(readme:find("`gA` in the query pad generates SQL", 1, true))
  assert(not readme:find("`A` in the query pad generates SQL", 1, true))

  for name, text in pairs({ README = readme, help = help }) do
    assert(text:find("all database SQL and AI request content through stdin", 1, true),
      name .. " must document the stdin boundary")
    assert(text:find("running as your user may still read those environment variables", 1, true),
      name .. " must document the same-user environment limit")
    assert(not text:find("--init-command", 1, true), name .. " still documents removed mysql argv setup")
  end

  assert(readme:find("no database server or manual setup", 1, true), "README demo requirements")
  assert(help:find("database server or manual setup", 1, true), "help demo requirements")
  assert(not readme:find("Only `db.lua` and adapters run shell commands", 1, true),
    "README still claims an incomplete process boundary")
end)

test("TODO contains only active or unshipped work", function()
  assert(todo:find("## Now", 1, true)
    and todo:find("## Deferred", 1, true) and todo:find("## Product ideas", 1, true))
  assert(not todo:find("- [x]", 1, true), "completed checkbox retained")
  assert(not todo:find("v3.10.1", 1, true), "released version retained")
  assert(not todo:find("Docker assign", 1, true), "completed dynamic-port work retained")
  assert(not todo:find("TOP N pagination", 1, true), "stale SQL Server pagination claim retained")
  assert(todo:find("`##temp`", 1, true), "unresolved SQL Server temp-table limitation missing")
  assert(not todo:find("GripFill", 1, true), "shipped GripFill work retained")
end)

test("release version has matching changelog notes", function()
  local version = require("dadbod-grip.version")
  assert(version == "3.10.1", "unexpected release version: " .. tostring(version))
  assert(changelog:find("## [" .. version .. "] - 2026-08-30", 1, true),
    "changelog section missing for " .. version)
end)

print(string.format("\ndocs_contract_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
