-- adapters/duckdb.lua — DuckDB adapter (duckdb CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util = require("dadbod-grip.db")

local M = {}

local DEFAULT_TIMEOUT = 10000

--- Extract file path from dadbod's duckdb: URL format.
--- "duckdb:path/to/db.duckdb"    -> "path/to/db.duckdb"
--- "duckdb:/absolute/path.db"    -> "/absolute/path.db"
--- "duckdb:///absolute/path"     -> "/absolute/path"
--- "duckdb::memory:"             -> ":memory:"
--- "duckdb:"                     -> ":memory:"
local function extract_path(url)
  if url:match("^duckdb::memory:$") or url:match("^duckdb:$") then
    return ":memory:"
  end
  local path = url:match("^duckdb:///(.+)$")
  if path then return "/" .. path end
  path = url:match("^duckdb:(.+)$")
  if not path or path == "" then return nil end
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or ""
    path = home .. path:sub(2)
  end
  return path
end

local function duckdb(db_path, sql_str, timeout_ms)
  local args = { "duckdb", "-csv", "-header" }
  if db_path ~= ":memory:" then
    args[#args + 1] = db_path
  end
  args[#args + 1] = "-c"
  args[#args + 1] = sql_str

  local result = vim.system(
    args,
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()
  return result.stdout or "", result.stderr or "", result.code
end

--- Run DML without CSV mode (to get change count output).
local function duckdb_exec(db_path, sql_str, timeout_ms)
  local args = { "duckdb" }
  if db_path ~= ":memory:" then
    args[#args + 1] = db_path
  end
  args[#args + 1] = "-c"
  args[#args + 1] = sql_str

  local result = vim.system(
    args,
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()
  return result.stdout or "", result.stderr or "", result.code
end

function M.query(sql_str, url)
  if vim.fn.executable("duckdb") == 0 then
    return nil, "duckdb not found. Install duckdb."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local stdout, stderr, code = duckdb(db_path, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("duckdb exited with code " .. code)
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
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

  local sql_str = string.format([[
    SELECT kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    WHERE tc.constraint_type = 'PRIMARY KEY'
      AND tc.table_schema = '%s'
      AND tc.table_name = '%s'
    ORDER BY kcu.ordinal_position
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query primary keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local pks = {}
  for _, row in ipairs(parsed.rows) do
    if row[1] and row[1] ~= "" then
      table.insert(pks, row[1])
    end
  end
  return pks, nil
end

function M.get_column_info(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

  local info_sql = string.format([[
    SELECT
      c.column_name,
      c.data_type,
      c.is_nullable,
      COALESCE(c.column_default, '') AS column_default,
      COALESCE(
        (SELECT string_agg(tc.constraint_type, ', ')
         FROM information_schema.key_column_usage kcu
         JOIN information_schema.table_constraints tc
           ON tc.constraint_name = kcu.constraint_name
           AND tc.table_schema = kcu.table_schema
         WHERE kcu.table_schema = '%s'
           AND kcu.table_name = '%s'
           AND kcu.column_name = c.column_name),
        ''
      ) AS constraints
    FROM information_schema.columns c
    WHERE c.table_schema = '%s'
      AND c.table_name = '%s'
    ORDER BY c.ordinal_position
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"),
      schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, info_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse column info" end

  local cols = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(cols, {
      column_name    = row[1] or "",
      data_type      = row[2] or "",
      is_nullable    = row[3] or "",
      column_default = row[4] or "",
      constraints    = row[5] or "",
    })
  end
  return cols, nil
end

function M.get_foreign_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

  local fk_sql = string.format([[
    SELECT
      kcu.column_name,
      kcu2.table_name AS ref_table,
      kcu2.column_name AS ref_column
    FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage kcu
      ON rc.constraint_schema = kcu.constraint_schema
      AND rc.constraint_name = kcu.constraint_name
    JOIN information_schema.key_column_usage kcu2
      ON rc.unique_constraint_schema = kcu2.constraint_schema
      AND rc.unique_constraint_name = kcu2.constraint_name
      AND kcu.ordinal_position = kcu2.ordinal_position
    WHERE kcu.table_schema = '%s'
      AND kcu.table_name = '%s'
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local fks = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(fks, {
      column     = row[1] or "",
      ref_table  = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

function M.explain(sql_str, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local stdout, stderr, code = duckdb(db_path, "EXPLAIN " .. sql_str)
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
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end
  local sql_str = [[
    SELECT table_name,
      CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM information_schema.tables
    WHERE table_schema = 'main'
    ORDER BY table_type DESC, table_name
  ]]
  local stdout, stderr, code = duckdb(db_path, sql_str)
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
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

  local idx_sql = string.format([[
    SELECT
      index_name,
      CASE WHEN is_unique AND is_primary THEN 'PRIMARY'
           WHEN is_unique THEN 'UNIQUE'
           ELSE 'INDEX'
      END AS index_type,
      (SELECT string_agg(column_name, ', ')
       FROM information_schema.key_column_usage kcu
       JOIN information_schema.table_constraints tc
         ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
       WHERE tc.table_schema = di.schema_name
         AND tc.table_name = di.table_name
         AND tc.constraint_type = CASE WHEN di.is_primary THEN 'PRIMARY KEY' ELSE 'UNIQUE' END
      ) AS columns
    FROM duckdb_indexes() di
    WHERE di.schema_name = '%s' AND di.table_name = '%s'
    ORDER BY is_primary DESC, index_name
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, idx_sql)
  if code ~= 0 then
    -- DuckDB may not support duckdb_indexes() in all versions; fallback
    return {}, nil
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local indexes = {}
  for _, row in ipairs(parsed.rows) do
    local cols = {}
    for col in (row[3] or ""):gmatch("([^,]+)") do
      table.insert(cols, vim.trim(col))
    end
    table.insert(indexes, {
      name = row[1] or "",
      type = row[2] or "INDEX",
      columns = cols,
    })
  end
  return indexes, nil
end

function M.get_table_stats(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

  local stats_sql = string.format([[
    SELECT
      estimated_size,
      0 AS size_bytes
    FROM duckdb_tables()
    WHERE schema_name = '%s' AND table_name = '%s'
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, stats_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query table stats"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed or #parsed.rows == 0 then return nil, "No stats found" end

  return {
    row_estimate = tonumber(parsed.rows[1][1]) or 0,
    size_bytes = tonumber(parsed.rows[1][2]) or 0,
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("duckdb") == 0 then
    return nil, "duckdb not found. Install duckdb."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local stdout, stderr, code = duckdb_exec(db_path, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("duckdb exited with code " .. code)
    return nil, msg
  end

  -- DuckDB text mode outputs "Changes: N" or row counts
  local n = stdout:match("(%d+)") or "0"
  return { affected = tonumber(n) or 0, message = n .. " row(s) affected" }, nil
end

-- Exposed for testing
M._extract_path = extract_path

return M
