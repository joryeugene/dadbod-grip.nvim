-- Exercise the actual preview apply handler with mocked database boundaries.
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, history = require("dadbod-grip.db"), require("dadbod-grip.history")
local original = { execute = db.execute, open = grip.open, record = history.record,
  confirm = vim.fn.confirm, notify = vim.notify }
local pass, fail = 0, 0
local function test(name, run)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local sql = "INSERT INTO items(value) VALUES(1)"
  local pending = { sql = sql, type = "INSERT", table_name = "items", row_count = 1 }
  local session = { state = {}, url = "sqlite:unused", pending_mutation = pending }
  view._sessions[bufnr] = session
  local maps, writes, prompts, reopens = {}, {}, 0, 0
  require("dadbod-grip.view.keymaps_edit").setup(bufnr, {
    view = view, kmap = function(action, callback) maps[action] = callback end,
    session = function() return session end, session_is_editable = function() return false end,
  })
  vim.notify = function() end
  vim.fn.confirm = function() prompts = prompts + 1; return 1 end
  history.record = function() end
  grip.open = function() reopens = reopens + 1 end
  db.execute = function(statement) writes[#writes + 1] = statement; return { affected = 1 } end
  local ok, err = pcall(run, maps, session, writes, function() return prompts, reopens end)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
  view._sessions[bufnr] = nil
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

for _, unavailable in ipairs({ false, true }) do
  test("affected-count availability: " .. tostring(unavailable), function(maps, session)
    session.pending_mutation.affected_count_unavailable = unavailable
    local message
    vim.notify = function(text) message = text end
    db.execute = function() return { affected = 0 } end
    maps.grid_apply()
    assert(message and message:find("INSERT executed", 1, true), "execution message missing")
    assert((message:find("0 rows affected", 1, true) ~= nil) == not unavailable,
      "unavailable count was reported, or an available count was hidden")
  end)
end

for _, statement in ipairs({
  "UPDATE items SET value=value+1 WHERE id=7; -- trailing",
  "UPDATE items SET value=value+1 WHERE id=7 RETURNING id -- trailing",
}) do
  test("SQLite Apply reports the actual count after a line comment: " .. statement, function(maps, session)
    local sqlite = require("dadbod-grip.adapters.sqlite")
    local path = vim.fn.tempname() .. ".db"
    local setup = vim.system({ "sqlite3", path,
      "CREATE TABLE items(id INTEGER PRIMARY KEY, value INTEGER); INSERT INTO items VALUES(7,1);"
    }, { text = true }):wait()
    assert(setup.code == 0, setup.stderr)
    local ok, err = pcall(function()
      session.url = "sqlite:" .. path
      session.pending_mutation.sql = statement
      session.pending_mutation.type = "UPDATE"
      local message, executions = nil, 0
      vim.notify = function(text) message = text end
      db.execute = function(...)
        executions = executions + 1
        return original.execute(...)
      end
      maps.grid_apply()
      assert(executions == 1, "Apply must execute the mutation once")
      assert(message and message:find("1 row affected", 1, true), message or "missing execution message")
      assert(session.pending_mutation == nil, "successful Apply must consume pending SQL")
      local rows = assert(sqlite.query("SELECT value FROM items WHERE id=7", session.url))
      assert(rows.rows[1][1] == "2", "the mutation must commit exactly once")
    end)
    vim.fn.delete(path)
    assert(ok, err)
  end)
end

db.execute, grip.open, history.record = original.execute, original.open, original.record
vim.fn.confirm, vim.notify = original.confirm, original.notify
print(string.format("\nmutation_result_count_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
