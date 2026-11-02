-- Issue104 reproductions plus release-integration boundaries. Only disposable
-- SQLite fixtures are used; PostgreSQL routing cases are parser-level checks.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
local db, data = require("dadbod-grip.db"), require("dadbod-grip.data")

H.test("read-only CTE command-word alias remains a PostgreSQL query", function()
  local sql = "WITH src AS (SELECT 1 AS id) SELECT id AS update FROM src"
  local spec, _, _, mutation = grip._resolve_query(sql, 100, "postgresql")
  assert(spec and spec.is_raw and spec.base_sql == sql, "read-only CTE was not routed as the original query")
  H.eq(mutation, nil, "a column label is not a command")
end)

H.test("data-modifying CTE remains behind original-SQL confirmation", function()
  local sql = "WITH gone AS (DELETE FROM items RETURNING *) SELECT * FROM gone"
  local spec, _, _, mutation = grip._resolve_query(sql, 100, "postgresql")
  H.eq(spec, nil); H.eq(mutation, sql, "CTE body DELETE must not execute as a read")
end)

local function preview(c, sql)
  grip._mutation_preview(sql, c.url, "UPDATE", {})
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(view._sessions[buf], "no mutation preview session")
  assert(session.pending_mutation, "missing pending original SQL")
  return buf, session
end

H.test("aliased SQLite preview and cancel do not write; confirmed Apply runs original once", function(c)
  c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO items VALUES(1,'one'),(2,'two')")
  local sql = "UPDATE items AS i SET value='ready' WHERE i.id=2;"
  local real_execute, real_confirm = db.execute, vim.fn.confirm
  local writes = {}
  db.execute = function(statement, ...)
    writes[#writes + 1] = statement
    return real_execute(statement, ...)
  end
  local ok, err = xpcall(function()
    local buf, session = preview(c, sql)
    H.eq(#writes, 0); H.eq(#session.state.rows, 1); H.eq(session.state.rows[1][1], "2")
    H.eq(session.pending_mutation.sql, sql)
    H.eq(c.rows("SELECT id,value FROM items ORDER BY id"), { { "1", "one" }, { "2", "two" } })
    vim.fn.confirm = function() return 2 end
    H.key(buf, require("dadbod-grip.keymaps").get("grid_apply"))
    H.eq(#writes, 0); assert(session.pending_mutation, "cancel discarded original SQL")
    vim.fn.confirm = function() return 1 end
    H.key(buf, require("dadbod-grip.keymaps").get("grid_apply"))
    H.eq(writes, { sql }, "Apply must submit the complete original once")
    H.eq(c.rows("SELECT id,value FROM items ORDER BY id"), { { "1", "one" }, { "2", "ready" } })
  end, debug.traceback)
  db.execute, vim.fn.confirm = real_execute, real_confirm
  assert(ok, err)
end)

for _, case in ipairs({ { "NULL", nil }, { "''", "" } }) do
  H.test("literal UPDATE preview retains " .. case[1] .. " without a write", function(c)
    c.exec("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO items VALUES(1,'old')")
    local _, session = preview(c, "UPDATE items SET value=" .. case[1] .. " WHERE id=1")
    H.eq(data.effective_value(session.state, 1, "value"), case[2])
    H.eq(c.scalar("SELECT value FROM items"), "old")
  end)
end
H.finish("pr105_integration_spec")
