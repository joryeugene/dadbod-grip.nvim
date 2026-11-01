-- Metadata-sensitive preview mapping. SQL Server identifiers can differ only
-- by case; these mocked catalogs exercise both collations without a live server.
local grip, db = require("dadbod-grip"), require("dadbod-grip.db")
local view, data = require("dadbod-grip.view"), require("dadbod-grip.data")
local original = {
  query = db.query, execute = db.execute, is_readonly = db.is_readonly,
}
local notify = vim.notify
local pass, fail = 0, 0

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected),
    message .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function cleanup()
  local buffers = {}
  for buf in pairs(view._sessions) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    view._sessions[buf] = nil
  end
  while #vim.api.nvim_list_wins() > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_list_wins()[2], true)
  end
end

local function test(case)
  cleanup()
  local queries, writes, notices = {}, {}, {}
  db.query = function(statement)
    queries[#queries + 1] = statement
    local row = {}
    for idx in ipairs(case.columns) do row[idx] = "old" end
    return { columns = vim.deepcopy(case.columns), rows = { row } }
  end
  db.execute = function(statement) writes[#writes + 1] = statement; error("unexpected write") end
  db.is_readonly = function() return true end
  vim.notify = function(message, level)
    if level and level >= vim.log.levels.WARN then notices[#notices + 1] = message end
  end
  local ok, err = pcall(function()
    local kind = case.kind or "sqlserver"
    grip._mutation_preview(case.sql, kind .. "://unused/fixture", case.sql:match("^%u+"), {}, case.execution_sql)
    local session = assert(view._sessions[vim.api.nvim_get_current_buf()], table.concat(notices, "; "))
    eq(session.pending_mutation.sql, case.execution_sql or case.sql, "retained SQL")
    eq(session.pending_mutation.affected_count_unavailable, case.affected_count_unavailable,
      "mutation count availability")
    eq(session.state.changes[1] or {}, case.changes or {}, "predicted UPDATE columns")
    local inserts = {}
    for _, row in pairs(session.state.inserted) do inserts[#inserts + 1] = row.values end
    eq(inserts, case.inserts or {}, "predicted INSERT columns")
    eq(session.pending_mutation.current_state or false, case.current_state or false, "preview mode")
    eq(#queries, 1, "one preview query")
    eq(writes, {}, "preview does not write")
    eq(notices, {}, "preview errors")
  end)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. case.name .. ": " .. tostring(err)) end
end

local case_sensitive = { "ID", "Value", "value" }
local case_insensitive = { "ID", "Value" }

for _, case in ipairs({
  { name = "exact upper-case column", columns = case_sensitive,
    sql = "UPDATE items SET Value='upper new' WHERE ID=2", changes = { Value = "upper new" } },
  { name = "exact lower-case column", columns = case_sensitive,
    sql = "UPDATE items SET value='lower new' WHERE ID=2", changes = { value = "lower new" } },
  { name = "distinct case-sensitive assignments", columns = case_sensitive,
    sql = "UPDATE items SET Value='upper', value='lower' WHERE ID=2",
    changes = { Value = "upper", value = "lower" } },
  { name = "quoted case-sensitive columns", columns = case_sensitive,
    sql = "UPDATE items SET [Value]='upper', [value]='lower' WHERE ID=2",
    changes = { Value = "upper", value = "lower" } },
  { name = "ambiguous folded name is not guessed", columns = case_sensitive,
    sql = "UPDATE items SET VALUE='unknown' WHERE ID=2" },
  { name = "unique folded name still resolves", columns = case_insensitive,
    sql = "UPDATE items SET value='new' WHERE ID=2", changes = { Value = "new" } },
  { name = "case-insensitive expression invalidates earlier literal", columns = case_insensitive,
    sql = "UPDATE items SET Value='stale', value=UPPER(Value) WHERE ID=2" },
  { name = "case-sensitive expression leaves other column prediction", columns = case_sensitive,
    sql = "UPDATE items SET Value='upper', value=UPPER(value) WHERE ID=2",
    changes = { Value = "upper" } },
  { name = "case-insensitive assignment order", columns = case_insensitive,
    sql = "UPDATE items SET Value='first', value='second', Value='last' WHERE ID=2",
    changes = { Value = "last" } },
  { name = "case-sensitive NULL and empty string", columns = case_sensitive,
    sql = "UPDATE items SET Value=NULL, value='' WHERE ID=2",
    changes = { Value = data.NULL_SENTINEL, value = "" } },
  { name = "UDT property does not name the scalar column", columns = { "id", "Location", "X" },
    sql = "UPDATE Location SET X=7, Location.X=23.5 WHERE id=2", changes = { X = "7" } },
  { name = "UDT property invalidates only whole UDT prediction", columns = { "id", "Location", "X" },
    sql = "UPDATE Location SET Location='stale', X=7, Location.X=23.5 WHERE id=2", changes = { X = "7" } },
  { name = "explicit INSERT exact case", columns = case_sensitive,
    sql = "INSERT items(ID,Value) VALUES(3,'upper')", inserts = { { ID = "3", Value = "upper" } } },
  { name = "explicit INSERT both cases", columns = case_sensitive,
    sql = "INSERT items(ID,value,Value) VALUES(3,'lower','upper')",
    inserts = { { ID = "3", Value = "upper", value = "lower" } } },
  { name = "implicit INSERT catalog order", columns = case_sensitive,
    sql = "INSERT items VALUES(3,'upper','lower')",
    inserts = { { ID = "3", Value = "upper", value = "lower" } } },
  { name = "unique folded INSERT", columns = case_insensitive,
    sql = "INSERT items(id,value) VALUES(3,'new')", inserts = { { ID = "3", Value = "new" } } },
  { name = "ambiguous INSERT falls back to current data", columns = case_sensitive,
    sql = "INSERT items(ID,VALUE) VALUES(3,'unknown')", current_state = true },
  { name = "duplicate resolved INSERT falls back", columns = case_insensitive,
    sql = "INSERT items(Value,value) VALUES('first','second')", current_state = true },
  { name = "PostgreSQL quoted case stays exact", kind = "postgresql", columns = case_sensitive,
    sql = 'UPDATE items SET "Value"=\'upper\', value=\'lower\' WHERE "ID"=2',
    changes = { Value = "upper", value = "lower" } },
  { name = "PostgreSQL composite target leaves scalar prediction", kind = "postgresql",
    columns = { "id", "items", "value" },
    sql = "UPDATE items SET value='scalar', items.value='composite' WHERE id=2",
    changes = { value = "scalar" } },
  { name = "SQLite column case still folds", kind = "sqlite", columns = case_insensitive,
    sql = "UPDATE items SET value='new' WHERE id=2", changes = { Value = "new" } },
  { name = "DuckDB column case still folds", kind = "duckdb", columns = case_insensitive,
    sql = "INSERT INTO items(id,value) VALUES(3,'new')", inserts = { { ID = "3", Value = "new" } } },
}) do
  test(case)
end

for _, kind in ipairs({ "postgresql", "mysql", "mariadb", "sqlite", "duckdb", "sqlserver" }) do
  for _, wrapped in ipairs({ false, true }) do
    local statement = "UPDATE items SET value='new' WHERE id=2"
    local begin = kind == "sqlserver" and "BEGIN TRANSACTION;" or "BEGIN;"
    test({
      name = kind .. (wrapped and " committed count" or " direct count"),
      kind = kind, columns = { "id", "value" }, sql = statement, changes = { value = "new" },
      execution_sql = wrapped and (begin .. statement .. ";COMMIT;") or nil,
      affected_count_unavailable = wrapped and (kind == "mysql" or kind == "mariadb") or nil,
    })
  end
end

cleanup()
for key, fn in pairs(original) do db[key] = fn end
vim.notify = notify
print(string.format("\nmutation_columns_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
