-- Actual SQLite execution counts must survive trailing comments and RETURNING.
local sqlite = require("dadbod-grip.adapters.sqlite")
local pass, fail = 0, 0
local path = vim.fn.tempname() .. ".db"
local url = "sqlite:" .. path
local setup = vim.system({ "sqlite3", path,
  "CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT);"
    .. "INSERT INTO items VALUES(1,'old'),(2,'old'),(3,'old');"
}, { text = true }):wait()
assert(setup.code == 0, setup.stderr)

for _, case in ipairs({
  { "UPDATE items SET value='plain' WHERE id=1 -- trailing", 1 },
  { "UPDATE items SET value='terminated' WHERE id<3; -- trailing", 2 },
  { "UPDATE items SET value='new' WHERE id=3 RETURNING id -- trailing", 1 },
  { "BEGIN; UPDATE items SET value='transaction' WHERE id=1; COMMIT; -- trailing", 1 },
  { "INSERT INTO items VALUES(4,'literal -- text') -- trailing", 1 },
  { "DELETE FROM items WHERE id=4 -- trailing", 1 },
  { "UPDATE items SET value='none' WHERE id=99 -- no matches", 0 },
}) do
  local ok, err = pcall(function()
    local result, execution_err = sqlite.execute(case[1], url)
    assert(result and not execution_err, execution_err)
    assert(result.affected == case[2],
      "expected " .. case[2] .. " affected, got " .. tostring(result.affected))
  end)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. case[1] .. ": " .. tostring(err)) end
end
local rows = assert(sqlite.query("SELECT id,value FROM items ORDER BY id", url))
assert(vim.deep_equal(rows.rows, { { "1", "transaction" }, { "2", "terminated" }, { "3", "new" } }),
  "mutations must retain their original effect")
vim.fn.delete(path)
print(string.format("mutation_counts_spec: %d passed, %d failed", pass, fail))
if fail > 0 then vim.cmd("cquit 1") end
