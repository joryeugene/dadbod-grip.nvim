-- adapters/mysql.lua — MySQL/MariaDB adapter (mysql CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util = require("dadbod-grip.db")

local M = {}

local DEFAULT_TIMEOUT = 10000

--- Parse a dadbod-style MySQL URL into connection components.
--- "mysql://user:pass@host:port/dbname" → {user, pass, host, port, dbname}
local function parse_url(url)
  -- Strip scheme
  local rest = url:match("^%w+://(.+)$")
  if not rest then return nil end

  local user, pass, host, port, dbname

  -- Split auth@hostpath (match last @ to support passwords containing @)
  local auth, hostpath = rest:match("^(.+)@([^@]+)$")
  if not auth then
    hostpath = rest
  else
    user, pass = auth:match("^([^:]*):(.*)$")
    if not user then user = auth end
  end

  -- Split hostpath into host:port/dbname
  local hp, db = hostpath:match("^([^/]+)/(.+)$")
  if not hp then hp = hostpath end
  dbname = db

  host, port = hp:match("^([^:]+):(%d+)$")
  if not host then host = hp end

  return {
    user   = user,
    pass   = pass,
    host   = host or "127.0.0.1",
    port   = port or "3306",
    dbname = dbname,
  }
end

--- Build mysql CLI args and run a query.
local function mysql_query(parsed, sql_str, timeout_ms)
  local args = { "mysql", "--csv", "--init-command=SET sql_mode='ANSI_QUOTES'" }
  if parsed.host then
    args[#args + 1] = "-h"
    args[#args + 1] = parsed.host
  end
  if parsed.port then
    args[#args + 1] = "-P"
    args[#args + 1] = parsed.port
  end
  if parsed.user then
    args[#args + 1] = "-u"
    args[#args + 1] = parsed.user
  end
  if parsed.pass and parsed.pass ~= "" then
    args[#args + 1] = "-p" .. parsed.pass
  end
  if parsed.dbname then
    args[#args + 1] = parsed.dbname
  end
  args[#args + 1] = "-e"
  args[#args + 1] = sql_str

  local result = vim.system(
    args,
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""
  -- Strip the known password-on-CLI warning
  stderr = stderr:gsub("mysql: %[Warning%][^\n]*command line interface can be insecure%.?\n?", "")
  return stdout, stderr, result.code
end

--- Run a DML statement (uses --batch instead of --csv for affected-row output).
local function mysql_exec(parsed, sql_str, timeout_ms)
  local args = { "mysql", "--batch", "--init-command=SET sql_mode='ANSI_QUOTES'" }
  if parsed.host then
    args[#args + 1] = "-h"
    args[#args + 1] = parsed.host
  end
  if parsed.port then
    args[#args + 1] = "-P"
    args[#args + 1] = parsed.port
  end
  if parsed.user then
    args[#args + 1] = "-u"
    args[#args + 1] = parsed.user
  end
  if parsed.pass and parsed.pass ~= "" then
    args[#args + 1] = "-p" .. parsed.pass
  end
  if parsed.dbname then
    args[#args + 1] = parsed.dbname
  end
  args[#args + 1] = "-e"
  args[#args + 1] = sql_str

  local result = vim.system(
    args,
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""
  stderr = stderr:gsub("mysql: %[Warning%][^\n]*command line interface can be insecure%.?\n?", "")
  return stdout, stderr, result.code
end

function M.query(sql_str, url)
  if vim.fn.executable("mysql") == 0 then
    return nil, "mysql not found. Install mysql-client."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. url end

  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("mysql exited with code " .. code)
    return nil, msg
  end

  local result, parse_err = db_util.parse_csv(stdout)
  if not result then return nil, parse_err end

  return {
    rows = result.rows,
    columns = result.columns,
    primary_keys = {},
  }, nil
end

function M.get_primary_keys(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return {}, "Invalid MySQL URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = parsed.dbname
    tbl = table_name
  end

  local sql_str = string.format([[
    SELECT column_name
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE constraint_name = 'PRIMARY'
      AND table_schema = '%s'
      AND table_name = '%s'
    ORDER BY ordinal_position
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query primary keys"
  end

  local result = db_util.parse_csv(stdout)
  if not result then return {} end

  local pks = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then
      table.insert(pks, row[1])
    end
  end
  return pks, nil
end

function M.get_column_info(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = parsed.dbname
    tbl = table_name
  end

  local info_sql = string.format([[
    SELECT
      c.COLUMN_NAME AS column_name,
      CONCAT(c.DATA_TYPE,
             CASE WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL
                  THEN CONCAT('(', c.CHARACTER_MAXIMUM_LENGTH, ')')
                  WHEN c.NUMERIC_PRECISION IS NOT NULL
                       AND c.DATA_TYPE NOT IN ('int','bigint','smallint','tinyint','mediumint')
                  THEN CONCAT('(', c.NUMERIC_PRECISION,
                              CASE WHEN c.NUMERIC_SCALE > 0
                                   THEN CONCAT(',', c.NUMERIC_SCALE) ELSE '' END, ')')
                  ELSE ''
             END) AS data_type,
      c.IS_NULLABLE AS is_nullable,
      COALESCE(c.COLUMN_DEFAULT, '') AS column_default,
      COALESCE(c.COLUMN_KEY, '') AS constraints
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA = '%s'
      AND c.TABLE_NAME = '%s'
    ORDER BY c.ORDINAL_POSITION
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = mysql_query(parsed, info_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local result = db_util.parse_csv(stdout)
  if not result then return nil, "Failed to parse column info" end

  local cols = {}
  for _, row in ipairs(result.rows) do
    local key = row[5] or ""
    local constraint_str = ""
    if key == "PRI" then constraint_str = "PRIMARY KEY"
    elseif key == "UNI" then constraint_str = "UNIQUE"
    elseif key == "MUL" then constraint_str = "INDEX"
    end
    table.insert(cols, {
      column_name    = row[1] or "",
      data_type      = row[2] or "",
      is_nullable    = row[3] or "",
      column_default = row[4] or "",
      constraints    = constraint_str,
    })
  end
  return cols, nil
end

function M.get_foreign_keys(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return {}, "Invalid MySQL URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = parsed.dbname
    tbl = table_name
  end

  local fk_sql = string.format([[
    SELECT
      kcu.COLUMN_NAME AS column_name,
      kcu.REFERENCED_TABLE_NAME AS ref_table,
      kcu.REFERENCED_COLUMN_NAME AS ref_column
    FROM information_schema.KEY_COLUMN_USAGE kcu
    WHERE kcu.TABLE_SCHEMA = '%s'
      AND kcu.TABLE_NAME = '%s'
      AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
    ORDER BY kcu.ORDINAL_POSITION
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = mysql_query(parsed, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local result = db_util.parse_csv(stdout)
  if not result then return {} end

  local fks = {}
  for _, row in ipairs(result.rows) do
    table.insert(fks, {
      column     = row[1] or "",
      ref_table  = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

function M.explain(sql_str, url)
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. url end

  -- Try FORMAT=TREE (MySQL 8.0.16+), fallback to plain EXPLAIN
  local stdout, stderr, code = mysql_query(parsed, "EXPLAIN FORMAT=TREE " .. sql_str)
  if code ~= 0 then
    stdout, stderr, code = mysql_query(parsed, "EXPLAIN " .. sql_str)
    if code ~= 0 then
      return nil, stderr ~= "" and stderr or "EXPLAIN failed"
    end
  end

  local result = db_util.parse_csv(stdout)
  if not result then return nil, "Failed to parse EXPLAIN output" end

  local lines = {}
  if #result.columns == 1 then
    -- FORMAT=TREE: single column, each row is a line of the tree
    for _, row in ipairs(result.rows) do
      table.insert(lines, row[1] or "")
    end
  else
    -- Plain EXPLAIN: tabular output
    table.insert(lines, table.concat(result.columns, " | "))
    for _, row in ipairs(result.rows) do
      table.insert(lines, table.concat(row, " | "))
    end
  end
  return { lines = lines }, nil
end

function M.list_tables(url)
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. url end
  local sql_str = [[
    SELECT table_name,
      CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
    ORDER BY table_type DESC, table_name
  ]]
  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to list tables"
  end
  local result_csv = db_util.parse_csv(stdout)
  if not result_csv then return nil, "Failed to parse table list" end
  local result = {}
  for _, row in ipairs(result_csv.rows) do
    table.insert(result, { name = row[1] or "", type = row[2] or "table" })
  end
  return result, nil
end

function M.get_indexes(table_name, url)
  local parsed_url = parse_url(url)
  if not parsed_url then return {}, "Invalid MySQL URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = parsed_url.dbname
    tbl = table_name
  end

  local idx_sql = string.format([[
    SELECT
      INDEX_NAME,
      CASE
        WHEN INDEX_NAME = 'PRIMARY' THEN 'PRIMARY'
        WHEN NON_UNIQUE = 0 THEN 'UNIQUE'
        ELSE 'INDEX'
      END AS index_type,
      GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', ') AS columns
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = '%s' AND TABLE_NAME = '%s'
    GROUP BY INDEX_NAME, NON_UNIQUE
    ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = mysql_query(parsed_url, idx_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query indexes"
  end

  local result = db_util.parse_csv(stdout)
  if not result then return {} end

  local indexes = {}
  for _, row in ipairs(result.rows) do
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
  local parsed_url = parse_url(url)
  if not parsed_url then return nil, "Invalid MySQL URL: " .. url end

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = parsed_url.dbname
    tbl = table_name
  end

  local stats_sql = string.format([[
    SELECT
      TABLE_ROWS,
      DATA_LENGTH + INDEX_LENGTH AS size_bytes
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '%s' AND TABLE_NAME = '%s'
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = mysql_query(parsed_url, stats_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query table stats"
  end

  local result = db_util.parse_csv(stdout)
  if not result or #result.rows == 0 then return nil, "No stats found" end

  return {
    row_estimate = tonumber(result.rows[1][1]) or 0,
    size_bytes = tonumber(result.rows[1][2]) or 0,
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("mysql") == 0 then
    return nil, "mysql not found. Install mysql-client."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. url end

  -- MySQL doesn't support DEFAULT VALUES; rewrite for compatibility
  sql_str = sql_str:gsub("DEFAULT VALUES", "() VALUES ()")

  local stdout, stderr, code = mysql_exec(parsed, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("mysql exited with code " .. code)
    return nil, msg
  end

  -- mysql outputs affected-row info to stderr in batch mode
  local n = stderr:match("(%d+) rows? affected") or
            stdout:match("(%d+) rows? affected") or
            "0"
  return { affected = tonumber(n) or 0, message = n .. " row(s) affected" }, nil
end

-- Exposed for testing
M._parse_url = parse_url

return M
