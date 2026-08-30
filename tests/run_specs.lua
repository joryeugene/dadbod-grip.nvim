-- run_specs.lua: test runner for headless Neovim
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/run_specs.lua
--
-- Runs all *_spec.lua files in tests/spec/ and exits with non-zero on failure.

-- Override os.exit so individual specs don't kill the runner
local any_failure = false
local real_exit = os.exit
-- luacheck: push ignore 122
os.exit = function(code)
  if code and code ~= 0 then any_failure = true end
end

-- Specs that hit sqlite need a seeded tests/seed_sqlite.db (0 bytes = unseeded)
local db = "tests/seed_sqlite.db"
if vim.fn.getfsize(db) <= 0 then
  print("WARNING: " .. db .. " is missing or empty; DB-backed specs will fail.")
  print("Seed it first:  just seed-sqlite   (or: sqlite3 " .. db .. " < tests/seed_sqlite.sql)\n")
end

local spec_dir = vim.fn.fnamemodify("tests/spec", ":p")
local files = vim.fn.glob(spec_dir .. "/*_spec.lua", false, true)
table.sort(files)

print("Running " .. #files .. " spec file(s)...\n")

for _, file in ipairs(files) do
  local short = vim.fn.fnamemodify(file, ":t")
  print("── " .. short .. " ──")
  local ok, err = pcall(dofile, file)
  if not ok then
    print("ERROR loading " .. short .. ": " .. tostring(err))
    any_failure = true
  end
  print("")
end

os.exit = real_exit
-- luacheck: pop

-- Neovim's :qall does not run LuaCov's ordinary Lua-process finalizer, so CI
-- must flush explicitly before either success or failure exits the editor.
if vim.env.GRIP_COVERAGE == "1" then require("luacov.runner").shutdown() end

print("═══════════════════════════════════")
if any_failure then
  print("RESULT: SOME TESTS FAILED")
  vim.cmd("cquit 1")
else
  print("RESULT: ALL TESTS PASSED")
  vim.cmd("qall!")
end
