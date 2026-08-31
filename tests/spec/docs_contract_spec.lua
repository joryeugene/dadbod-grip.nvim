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
local walkthrough = read("demo/softrear-internal.md")
local grid_help = read("lua/dadbod-grip/view.lua")
local contributing = read("CONTRIBUTING.md")
local security = read("SECURITY.md")
local justfile = read("justfile")
local test_workflow = read(".github/workflows/test.yml")
local sqlserver_workflow = read(".github/workflows/sqlserver.yml")
local wordmark_path = "docs/brand/dadbod-grip-wordmark.png"

local contributors = table.concat({
  "## Contributors",
  "",
  "Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and open a focused pull request when you see something Dadbod Grip can do better.",
  "",
  "A special thank-you to [Gleb Yavorski (@GlebYavorski)](https://github.com/GlebYavorski).",
  "",
  "Dadbod Grip is available under the [MIT License](LICENSE), and I maintain the project.",
}, "\n")

test("public commands match lazy triggers and the help manual", function()
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
end)

test("README keeps the onboarding command path", function()
  assert(readme:find(wordmark_path, 1, true), "README fixed wordmark missing")
  assert(vim.fn.filereadable(wordmark_path) == 1, "README fixed wordmark asset missing")
  local hero = assert(readme:match("^(.-)\n%*%*Workflow%.%*%*"))
  assert(not hero:find("<table", 1, true), "README hero must remain table-free")
  assert(not hero:find("<picture", 1, true), "README hero must use the fixed PNG")
  assert(hero:find("mascot.gif", 1, true), "README hero lost Chonk")
  assert(readme:find(contributors, 1, true), "README contributor block changed")
  for _, name in ipairs({ "GripConnect", "GripStart", "Grip", "GripQuery" }) do
    assert(readme:find("`:" .. name, 1, true), "README onboarding missing :" .. name)
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

test("keymap documentation points to the catalog and runtime help stays complete", function()
  assert(readme:find("[`keymaps.json`](keymaps.json)", 1, true))
  assert(readme:find("AI keys remain registered", 1, true))
  assert(help:find("Pressing A or gA while AI is disabled shows an informational message", 1, true))
  assert(help:find("Press `gm` on any row", 1, true))
  assert(grid_help:find('"  gU        Set current column across all visible rows"', 1, true))
  assert(grid_help:find('"  gm        Open rows that reference the current row"', 1, true))
  assert(grid_help:find("Markdown, Grip Table", 1, true))
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
  assert(readme:find("`gA` generates SQL", 1, true))
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
  assert(todo:find("## Deferred", 1, true) and todo:find("## Product ideas", 1, true))
  assert(not todo:find("- [x]", 1, true), "completed checkbox retained")
  assert(not todo:find("v3.10.1", 1, true), "released version retained")
  assert(not todo:find("Docker assign", 1, true), "completed dynamic-port work retained")
  assert(not todo:find("README onboarding", 1, true), "completed README work retained")
  assert(not todo:find("SECURITY.md", 1, true), "completed security policy retained")
  assert(not todo:find("CONTRIBUTING.md", 1, true), "completed contributor guide retained")
  assert(not todo:find("TOP N pagination", 1, true), "stale SQL Server pagination claim retained")
  assert(not todo:find("`##temp`", 1, true), "stateless SQL Server temp-table scope retained as product work")
  assert(not todo:find("GripFill", 1, true), "shipped GripFill work retained")
  assert(not todo:find("Import CSV", 1, true), "shipped clipboard import retained")
end)

test("clipboard import documentation keeps its staging boundary", function()
  assert(readme:find("`:GripImport`", 1, true), "README import entry missing")
  assert(help:find(":GripImport [!command]", 1, true), "help import command missing")
  assert(help:find("stage the whole batch as one undoable edit", 1, true),
    "help import staging boundary missing")
  assert(help:find("press a separately to\n  apply it", 1, true),
    "help import apply boundary missing")
  for _, text in ipairs({ readme, help }) do
    assert(text:gsub("%s+", " "):find(
      "child commands retain normal shell argument visibility", 1, true),
      "import child-process boundary missing")
  end
end)

test("demo walkthrough uses cataloged keys and current data-source behavior", function()
  local claims = {
    qpad_execute = "`%s` to run it",
    grid_profile = "`%s` to see the full",
    grid_sort = "`%s` on any column",
    grid_sort_stack = "`%s` to stack",
    grid_col_stats = "`%s` shows severity statistics",
    grid_filter_cell = "Press `%s` on a",
    grid_edit = "with `%s`, navigate",
    grid_row_view = "Press `%s` on any row",
    grid_explain = "Press `%s` to inspect the query plan",
    grid_fk_follow = "Press `%s` on any FK column",
    grid_fk_referencing = "or `%s` on a referenced row",
    grid_export_clip = "Press `%s`\n> to export",
    ai = "press `%s` from the grid",
    editor_open_url = "press `%s`.",
    grid_preview_sql = "Press `%s` to inspect both",
    grid_undo = "press `%s` once",
    grid_apply = "press `%s`;",
    open_notebook = "Press `%s` from the query pad",
    help = "Press `%s` from any surface",
  }
  for action, claim in pairs(claims) do
    local key = assert(keymaps.defaults[action], "missing keymap action " .. action)
    claim = claim:format(key)
    assert(walkthrough:find(claim, 1, true),
      "demo walkthrough missing current " .. action .. " claim " .. claim)
  end

  assert(walkthrough:find("full 505-roll investigation", 1, true), "DuckDB dataset size missing")
  assert(walkthrough:find("compact 35-roll fixture", 1, true), "SQLite fallback size missing")
  assert(walkthrough:find("193 comments in the unreviewed queue", 1, true),
    "full unreviewed count drifted")
  assert(walkthrough:find(":GripImport !printf", 1, true), "demo import exercise missing")
  assert(walkthrough:find("Both rows appear with staged markers", 1, true),
    "demo import exercise does not prove batch staging")
  assert(walkthrough:find("https://jorypestorious.com/dadbod-grip-web/", 1, true),
    "demo canonical documentation URL missing")
  assert(not walkthrough:find("joryeugene.github.io/dadbod-grip-web", 1, true),
    "demo retained obsolete documentation URL")
  assert(not walkthrough:find(".grip/supplier_intel.db", 1, true),
    "demo retained project-local supplier database")
  assert(not walkthrough:find("Navigate between SQL blocks with `gn`", 1, true),
    "demo retained false notebook navigation claim")
end)

test("query-pad and SQL Server temp-table scope stay accurate", function()
  assert(help:find("blank-line-delimited SQL block under the cursor", 1, true),
    "query-pad block behavior missing")
  assert(help:find("Create and use #temp\nor ##temp tables in the same submitted block or visual selection", 1, true),
    "SQL Server temp-table session boundary missing")
  assert(help:find("GO-separated\nbatches in one submission share that session", 1, true),
    "SQL Server same-invocation GO behavior missing")
end)

test("contributor and vulnerability paths remain actionable", function()
  for _, command in ipairs({ "mise install", "just check", "just test-live", "just e2e-visual",
      "git config core.hooksPath .githooks", "gitleaks git --redact --verbose" }) do
    assert(contributing:find(command, 1, true), "CONTRIBUTING missing: " .. command)
  end
  assert(security:find("security/advisories/new", 1, true), "private report link missing")
  assert(security:find("Do not open a public issue", 1, true), "public disclosure warning missing")
end)

test("live dialect workflows use the shared required Just entry point", function()
  local live_images = {
    ["postgresql-16"] = "postgres:16-alpine",
    ["mysql-8.4"] = "mysql:8.4",
    ["mariadb-11.8"] = "mariadb:11.8",
  }
  for database, image in pairs(live_images) do
    assert(test_workflow:find(database, 1, true), "CI matrix missing " .. database)
    assert(justfile:find(database .. ")", 1, true), "test-live missing " .. database)
    assert(test_workflow:find(image, 1, true), "CI image drifted from " .. database)
  end
  assert(test_workflow:find('just test-live "${{ matrix.database }}"', 1, true),
    "live CI bypasses just test-live")
  assert(justfile:find("sqlserver-2025", 1, true), "test-live missing sqlserver-2025")
  assert(sqlserver_workflow:find("just test-live sqlserver-2025", 1, true),
    "SQL Server gate bypasses just test-live")
  assert(sqlserver_workflow:find("mcr.microsoft.com/mssql/server:2025-latest", 1, true),
    "SQL Server gate drifted from SQL Server 2025")
  assert(not sqlserver_workflow:find("GRIP_REQUIRE_LIVE", 1, true),
    "SQL Server CI duplicates Justfile required flags")
  assert(not test_workflow:find('echo "GRIP_REQUIRE_', 1, true),
    "live CI duplicates Justfile required flags")
end)

test("release version has matching changelog notes", function()
  local version = require("dadbod-grip.version")
  assert(version == "3.11.0", "unexpected release version: " .. tostring(version))
  assert(changelog:find("## [" .. version .. "] - 2026-08-31", 1, true),
    "changelog section missing for " .. version)
end)

print(string.format("\ndocs_contract_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
