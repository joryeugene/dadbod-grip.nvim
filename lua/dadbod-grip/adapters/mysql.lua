-- adapters/mysql.lua: MySQL/MariaDB adapter (mysql CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util  = require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = {}

local DEFAULT_TIMEOUT = 10000

--- Split a possibly schema-qualified table name; callers pass the connected
--- database as the default schema.
local split_table_name = sql_util.split_table_name

--- Parse a dadbod-style MySQL URL into connection components.
--- "mysql://user:pass@host:port/dbname" → {user, pass, host, port, dbname}
local function parse_url(url)
  return sql_util.parse_dadbod_url(url, "3306")
end

--- Parse query output from mysql --batch (tab-separated).
local function parse_output(stdout)
  return db_util.parse_batch(stdout)
end

--- MariaDB still reports deprecated integer display widths (for example
--- bigint(20) unsigned). They are formatting hints, not type precision.
local function normalize_column_type(column_type)
  local name, _, rest = column_type:match("^(%a+)%((%d+)%)%s*(.*)$")
  local integer = name and ({
    tinyint = true, smallint = true, mediumint = true,
    int = true, integer = true, bigint = true,
  })[name:lower()]
  if not integer then return column_type end
  return name .. (rest ~= "" and (" " .. rest) or "")
end

--- Build mysql CLI args for a statement, query or DML alike.
--- Both MySQL and MariaDB use --batch (tab-separated output; --csv is not a
--- mysql CLI flag). --batch reports no affected-row count for DML, which is why
--- execute() asks for ROW_COUNT() explicitly.
--- Split out from mysql_query() so the blocking and non-blocking spawns run
--- byte-identical command lines.
---
--- opts.readonly is merged *into* the existing --init-command rather than
--- added as a second one: the mysql CLI keeps only the last --init-command it
--- is given, so a second flag would silently drop the sql_mode the whole
--- adapter depends on (ANSI_QUOTES) instead of adding to it.
--- @param opts table|nil  { readonly = boolean }
local function mysql_args(parsed, sql_str, opts)
  local init = { "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES'" }
  if opts and opts.readonly then
    init[#init + 1] = "SET SESSION TRANSACTION READ ONLY"
  end
  local args = { "mysql", "--batch", "--init-command=" .. table.concat(init, "; ") }
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
  if parsed.dbname then
    args[#args + 1] = parsed.dbname
  end
  args[#args + 1] = "-e"
  args[#args + 1] = sql_str
  return args
end

--- opts.env for one mysql invocation: MYSQL_PWD carrying the password so it
--- never appears in argv (visible via `ps`). No percent-decoding -- sql.lua's
--- parse_dadbod_url hands mysql URLs to the CLI verbatim, and MYSQL_PWD is
--- just the argv `-p<pass>` this replaces, so it gets the same verbatim value.
--- Returns an empty table -- not a MYSQL_PWD key -- when there is no password,
--- matching mysql_args' old behavior of omitting -p entirely (falls through
--- to any password configured in a defaults file).
local function mysql_env(parsed)
  if not parsed.pass or parsed.pass == "" then return {} end
  return { MYSQL_PWD = parsed.pass }
end

--- Run a statement, blocking.
local function mysql_query(parsed, sql_str, timeout_ms)
  return adapters.run_cmd(mysql_args(parsed, sql_str, adapters.session_opts()),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT), { env = mysql_env(parsed) })
end

--- Run a statement without blocking; same argv and same env as mysql_query.
local function mysql_query_async(parsed, sql_str, timeout_ms, callback)
  adapters.run_cmd_async(mysql_args(parsed, sql_str, adapters.session_opts()),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT), callback, { env = mysql_env(parsed) })
end

function M.query(sql_str, url)
  if vim.fn.executable("mysql") == 0 then
    return nil, "mysql not found. Install mysql-client."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("mysql exited with code " .. code)
    return nil, msg
  end

  local result, parse_err = parse_output(stdout)
  if not result then return nil, parse_err end

  return {
    rows = result.rows,
    columns = result.columns,
    primary_keys = {},
  }, nil
end

function M.get_primary_keys(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return {}, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed.dbname)

  local sql_str = string.format([[
    SELECT column_name
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE constraint_name = 'PRIMARY'
      AND table_schema = '%s'
      AND table_name = '%s'
    ORDER BY ordinal_position
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query primary keys"
  end

  local result = parse_output(stdout)
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
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed.dbname)

  -- COLUMN_TYPE is the type as spelled in the DDL: enum('a','b'), varchar(100),
  -- decimal(10,2), bigint unsigned. Rebuilding it from DATA_TYPE plus
  -- CHARACTER_MAXIMUM_LENGTH / NUMERIC_PRECISION instead yields labels that are
  -- shaped like DDL but lie: enum(7) is the longest value's length, float(12) is
  -- the type's precision, longtext(4294967295) is the format's limit.
  local info_sql = string.format([[
    SELECT
      c.COLUMN_NAME AS column_name,
      c.COLUMN_TYPE AS data_type,
      c.IS_NULLABLE AS is_nullable,
      COALESCE(c.COLUMN_DEFAULT, '') AS column_default,
      COALESCE(c.COLUMN_KEY, '') AS constraints
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA = '%s'
      AND c.TABLE_NAME = '%s'
    ORDER BY c.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed, info_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local result = parse_output(stdout)
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
      data_type      = normalize_column_type(row[2] or ""),
      is_nullable    = row[3] or "",
      column_default = row[4] or "",
      constraints    = constraint_str,
    })
  end
  return cols, nil
end

function M.get_foreign_keys(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return {}, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed.dbname)

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
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local result = parse_output(stdout)
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

--- Reverse FK lookup: which tables reference table_name?
--- Single information_schema query (no per-table scan).
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local parsed_url = parse_url(url)
  if not parsed_url then return {}, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed_url.dbname)

  local fk_sql = string.format([[
    SELECT
      kcu.TABLE_NAME AS child_table,
      kcu.COLUMN_NAME AS fk_column,
      kcu.REFERENCED_COLUMN_NAME AS ref_column,
      kcu.CONSTRAINT_NAME AS constraint_name
    FROM information_schema.KEY_COLUMN_USAGE kcu
    WHERE kcu.REFERENCED_TABLE_SCHEMA = '%s'
      AND kcu.REFERENCED_TABLE_NAME = '%s'
    ORDER BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed_url, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query referencing foreign keys"
  end

  local result = parse_output(stdout)
  if not result then return {} end

  local entries = {}
  for _, row in ipairs(result.rows) do
    table.insert(entries, {
      table      = row[1] or "",
      column     = row[2] or "",
      ref_column = row[3] or "",
      key        = row[4] or "",
    })
  end
  return db_util.group_referencing_fks(entries), nil
end

--- The one schema-batch statement, shared by get_schema_batch and
--- get_schema_batch_async so the two paths can never query different things.
local SCHEMA_BATCH_SQL = [[
    SELECT
      c.TABLE_NAME AS table_name,
      c.COLUMN_NAME AS column_name,
      c.COLUMN_TYPE AS data_type, -- DDL spelling; see get_column_info
      c.IS_NULLABLE AS is_nullable
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA = DATABASE()
    ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
  ]]

--- Parse SCHEMA_BATCH_SQL's --batch output into the completion cache format.
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- The single parser for both the blocking and non-blocking paths.
local function parse_schema_batch(stdout)
  local result = parse_output(stdout)
  if not result then return nil end

  local tables = {}
  for _, row in ipairs(result.rows) do
    local tname     = row[1] or ""
    local col_name  = row[2] or ""
    local data_type = normalize_column_type(row[3] or "")
    local nullable  = row[4] or ""
    tables[tname] = tables[tname] or {}
    table.insert(tables[tname], { column_name = col_name, data_type = data_type, is_nullable = nullable })
  end
  return tables
end

--- Fetch all table columns in a single query (O(1) CLI spawns).
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
function M.get_schema_batch(url)
  local parsed = parse_url(url)
  if not parsed then return nil end

  local stdout, _, code = mysql_query(parsed, SCHEMA_BATCH_SQL)
  if code ~= 0 then return nil end

  return parse_schema_batch(stdout)
end

--- Async variant: same statement, same parser, non-blocking spawn.
--- Calls callback(tables), or callback(nil) on a bad URL or a failed mysql.
--- Used to pre-warm the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  local parsed = parse_url(url)
  -- Deliver via vim.schedule even on this guard path: run_cmd_async's contract
  -- is that the callback never fires on the calling tick, and a caller must not
  -- be able to tell a bad URL from a spawn failure by that timing difference.
  if not parsed then vim.schedule(function() callback(nil) end); return end

  mysql_query_async(parsed, SCHEMA_BATCH_SQL, nil, function(stdout, _, code)
    if code ~= 0 then callback(nil); return end
    callback(parse_schema_batch(stdout))
  end)
end

function M.explain(sql_str, url)
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  -- Try FORMAT=TREE (MySQL 8.0.16+), fallback to plain EXPLAIN. This stderr is
  -- dropped on purpose: a failure here only means the server predates 8.0.16, and
  -- the plain-EXPLAIN retry below produces the error worth showing.
  -- luacheck: ignore 311
  local stdout, stderr, code = mysql_query(parsed, "EXPLAIN FORMAT=TREE " .. sql_str)
  if code ~= 0 then
    stdout, stderr, code = mysql_query(parsed, "EXPLAIN " .. sql_str)
    if code ~= 0 then
      return nil, stderr ~= "" and stderr or "EXPLAIN failed"
    end
  end

  local result = parse_output(stdout)
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
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end
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
  local result_csv = parse_output(stdout)
  if not result_csv then return nil, "Failed to parse table list" end
  local result = {}
  for _, row in ipairs(result_csv.rows) do
    table.insert(result, { name = row[1] or "", type = row[2] or "table" })
  end
  return result, nil
end

function M.get_indexes(table_name, url)
  local parsed_url = parse_url(url)
  if not parsed_url then return {}, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed_url.dbname)

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
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed_url, idx_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query indexes"
  end

  local result = parse_output(stdout)
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

function M.get_constraints(table_name, url)
  local parsed = parse_url(url)
  if not parsed then return {}, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed.dbname)

  -- MySQL 8.0+ supports CHECK constraints; older versions silently return no rows
  local sql_str = string.format([[
    SELECT
      tc.CONSTRAINT_NAME,
      tc.CONSTRAINT_TYPE,
      CASE
        WHEN tc.CONSTRAINT_TYPE = 'CHECK' THEN (
          SELECT cc.CHECK_CLAUSE
          FROM information_schema.CHECK_CONSTRAINTS cc
          WHERE cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            AND cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
        )
        ELSE (
          SELECT GROUP_CONCAT(kcu.COLUMN_NAME ORDER BY kcu.ORDINAL_POSITION SEPARATOR ', ')
          FROM information_schema.KEY_COLUMN_USAGE kcu
          WHERE kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
        )
      END AS definition
    FROM information_schema.TABLE_CONSTRAINTS tc
    WHERE tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
      AND tc.CONSTRAINT_TYPE IN ('CHECK', 'UNIQUE')
    ORDER BY tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query constraints"
  end

  local result = parse_output(stdout)
  if not result then return {} end

  local constraints = {}
  for _, row in ipairs(result.rows) do
    table.insert(constraints, {
      name       = row[1] or "",
      type       = row[2] or "",
      definition = row[3] or "",
    })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local parsed_url = parse_url(url)
  if not parsed_url then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  local schema, tbl = split_table_name(table_name, parsed_url.dbname)

  local stats_sql = string.format([[
    SELECT
      TABLE_ROWS,
      DATA_LENGTH + INDEX_LENGTH AS size_bytes
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '%s' AND TABLE_NAME = '%s'
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed_url, stats_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query table stats"
  end

  local result = parse_output(stdout)
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
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  -- MySQL doesn't support DEFAULT VALUES; rewrite for compatibility
  sql_str = sql_str:gsub("DEFAULT VALUES", "() VALUES ()")

  -- mysql --batch prints no "N rows affected" line anywhere (that needs -vv), so
  -- ask the server for the count instead, the way sqlite appends changes().
  -- ROW_COUNT() reports on the statement right before it, so it must come last;
  -- for a multi-statement batch that means the count is the last statement's.
  -- The newline before ";" keeps a trailing line comment from swallowing it.
  local wrapped = (sql_str:gsub("[%s;]+$", "")) .. "\n; SELECT ROW_COUNT();"

  local stdout, stderr, code = mysql_query(parsed, wrapped)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("mysql exited with code " .. code)
    return nil, msg
  end

  -- The appended SELECT prints "ROW_COUNT()\nN". Scan from the end so a result
  -- set produced by an earlier statement can't be mistaken for the count.
  -- ROW_COUNT() is -1 when the last statement was no DML; report that as 0.
  local n = 0
  local lines = vim.split(stdout, "\n", { plain = true })
  for i = #lines - 1, 1, -1 do
    if lines[i] == "ROW_COUNT()" then
      n = math.max(tonumber(lines[i + 1]) or 0, 0)
      break
    end
  end

  return { affected = n, message = n .. " row(s) affected" }, nil
end

--- Ping the server by running SELECT 1. Returns true on success, false on any error.
function M.ping(url)
  if vim.fn.executable("mysql") == 0 then return false end
  local parsed = parse_url(url)
  if not parsed then return false end
  local _, _, code = mysql_query(parsed, "SELECT 1", 5000)
  return code == 0
end

-- Exposed for testing
M._parse_url = parse_url
M._mysql_args = mysql_args
M._mysql_env = mysql_env
M._normalize_column_type = normalize_column_type

return M
