-- adapters/sqlite.lua: SQLite adapter (sqlite3 CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util = require("dadbod-grip.db")

local M = {}

local DEFAULT_TIMEOUT = 10000

--- Extract file path from dadbod's sqlite: URL format.
--- "sqlite:path/to/db.db"      -> "path/to/db.db"
--- "sqlite:/absolute/path.db"  -> "/absolute/path.db"
--- "sqlite:///absolute/path"   -> "/absolute/path"
local function extract_path(url)
  local path = url:match("^sqlite:///(.+)$")
  if path then return "/" .. path end
  path = url:match("^sqlite:(.+)$")
  if not path or path == "" then return nil end
  -- Expand ~ to home directory
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or ""
    path = home .. path:sub(2)
  end
  return path
end

local function sqlite3(db_path, sql_str, timeout_ms)
  local result = vim.system(
    { "sqlite3", "-csv", "-header", db_path, sql_str },
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()
  return result.stdout or "", result.stderr or "", result.code
end

function M.query(sql_str, url)
  if vim.fn.executable("sqlite3") == 0 then
    return nil, "sqlite3 not found. Install sqlite."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local stdout, stderr, code = sqlite3(db_path, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("sqlite3 exited with code " .. code)
    return nil, msg
  end

  local parsed, parse_err = db_util.parse_csv(stdout)
  if not parsed then return nil, parse_err end

  return {
    rows = parsed.rows,
    columns = parsed.columns,
    primary_keys = {},
  }, nil
end

function M.get_primary_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA table_info("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query primary keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
  -- pk > 0 means primary key; the value is position in composite key
  local pks = {}
  for _, row in ipairs(parsed.rows) do
    local pk_val = tonumber(row[6]) or 0
    if pk_val > 0 then
      table.insert(pks, { name = row[2], pos = pk_val })
    end
  end
  table.sort(pks, function(a, b) return a.pos < b.pos end)

  local result = {}
  for _, pk in ipairs(pks) do
    table.insert(result, pk.name)
  end
  return result, nil
end

function M.get_column_info(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA table_info("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse column info" end

  -- PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
  local cols = {}
  for _, row in ipairs(parsed.rows) do
    local pk_val = tonumber(row[6]) or 0
    table.insert(cols, {
      column_name    = row[2] or "",
      data_type      = row[3] or "",
      is_nullable    = (row[4] == "1") and "NO" or "YES",
      column_default = row[5] or "",
      constraints    = pk_val > 0 and "PRIMARY KEY" or "",
    })
  end
  return cols, nil
end

function M.get_foreign_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA foreign_key_list("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- PRAGMA foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match
  local fks = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(fks, {
      column = row[4] or "",      -- "from" column in this table
      ref_table = row[3] or "",   -- referenced table
      ref_column = row[5] or "",  -- referenced column ("to")
    })
  end
  return fks, nil
end

function M.explain(sql_str, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local stdout, stderr, code = sqlite3(db_path, "EXPLAIN QUERY PLAN " .. sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "EXPLAIN failed"
  end

  local lines = {}
  for line in stdout:gmatch("([^\n]+)") do
    table.insert(lines, line)
  end
  return { lines = lines }, nil
end

function M.list_tables(url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end
  local sql_str = [[
    SELECT name, type FROM sqlite_master
    WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
    ORDER BY type DESC, name
  ]]
  local stdout, stderr, code = sqlite3(db_path, sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to list tables"
  end
  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse table list" end
  local result = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(result, { name = row[1] or "", type = row[2] or "table" })
  end
  return result, nil
end

function M.get_indexes(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  -- Get index list
  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA index_list("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query indexes"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- PRAGMA index_list columns: seq, name, unique, origin, partial
  local indexes = {}
  for _, row in ipairs(parsed.rows) do
    local idx_name = row[2] or ""
    local is_unique = row[3] == "1"
    local origin = row[4] or ""
    local idx_type = origin == "pk" and "PRIMARY" or (is_unique and "UNIQUE" or "INDEX")

    -- Get columns for this index
    local col_stdout = sqlite3(db_path, string.format('PRAGMA index_info("%s")', idx_name:gsub('"', '""')))
    local col_parsed = db_util.parse_csv(col_stdout)
    local cols = {}
    if col_parsed then
      -- PRAGMA index_info columns: seqno, cid, name
      for _, crow in ipairs(col_parsed.rows) do
        table.insert(cols, crow[3] or "")
      end
    end

    table.insert(indexes, {
      name = idx_name,
      type = idx_type,
      columns = cols,
    })
  end
  return indexes, nil
end

-- SQLite stores constraints inline in the CREATE TABLE DDL; there is no constraint catalog.
-- Return the raw DDL as a single "constraint" row so users can inspect it.
function M.get_constraints(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  local stdout, stderr, code = sqlite3(db_path,
    string.format("SELECT sql FROM sqlite_master WHERE type='table' AND name='%s'",
      tbl:gsub("'", "''")))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query DDL"
  end

  -- Extract UNIQUE and CHECK clauses from CREATE TABLE SQL with a simple scan
  local ddl = stdout:gsub("^%s+", ""):gsub("%s+$", "")
  if ddl == "" then return {}, nil end

  local constraints = {}
  -- Match lines containing UNIQUE or CHECK (not column-level, those are simpler)
  for line in ddl:gmatch("[^\n]+") do
    local trimmed = vim.trim(line):gsub(",$", "")
    if trimmed:upper():match("^UNIQUE") or trimmed:upper():match("^CONSTRAINT.*UNIQUE")
      or trimmed:upper():match("^CHECK") or trimmed:upper():match("^CONSTRAINT.*CHECK") then
      local ctype = trimmed:upper():find("UNIQUE") and "UNIQUE" or "CHECK"
      table.insert(constraints, { name = "(inline)", type = ctype, definition = trimmed })
    end
  end

  -- Fallback: return the full DDL for manual inspection when no named constraints found
  if #constraints == 0 then
    table.insert(constraints, { name = "(see DDL)", type = "DDL", definition = ddl })
  end

  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  tbl = tbl:match("^[^.]+%.(.+)$") or tbl

  -- Row count (exact, SQLite doesn't have estimates)
  local stdout, _, code = sqlite3(db_path, string.format("SELECT COUNT(*) FROM \"%s\"", tbl:gsub('"', '""')))
  local row_count = 0
  if code == 0 then
    for line in stdout:gmatch("([^\n]+)") do
      local n = tonumber(line)
      if n then row_count = n end
    end
  end

  -- DB file size (page_count * page_size)
  local size_stdout = sqlite3(db_path, "SELECT page_count * page_size FROM pragma_page_count, pragma_page_size")
  local size_bytes = 0
  if size_stdout then
    for line in size_stdout:gmatch("([^\n]+)") do
      local n = tonumber(line)
      if n then size_bytes = n end
    end
  end

  return {
    row_estimate = row_count,
    size_bytes = size_bytes,
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlite3") == 0 then
    return nil, "sqlite3 not found. Install sqlite."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  -- Append changes() to get affected row count in a single invocation
  local wrapped = sql_str .. "; SELECT changes();"
  local stdout, stderr, code = sqlite3(db_path, wrapped)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("sqlite3 exited with code " .. code)
    return nil, msg
  end

  -- stdout from "SELECT changes()" with -csv -header:
  -- "changes()\nN\n"
  -- Parse last numeric line for the count.
  local n = 0
  for line in stdout:gmatch("([^\n]+)") do
    local num = tonumber(line)
    if num then n = num end
  end

  return { affected = n, message = n .. " row(s) affected" }, nil
end

-- Exposed for testing
M._extract_path = extract_path

return M
