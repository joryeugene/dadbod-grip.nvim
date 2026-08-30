-- adapters/sqlserver.lua: SQL Server adapter (sqlcmd CLI).
-- Read-only grid support for v1. All functions return (result, err).

local adapters = require("dadbod-grip.adapters")
local db_util  = require("dadbod-grip.db")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = { readonly = true }

local DEFAULT_TIMEOUT = 30000

local function decode_query_value(value)
  return (value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Parse a dadbod-style SQL Server URL and its TLS query options.
--- Both sqlserver:// and mssql:// are accepted by the shared URL parser.
--- @return table|nil parsed
--- @return string|nil err
local function parse_url(url)
  local base, query = url:match("^(.-)%?(.*)$")
  local parsed = sql_util.parse_dadbod_url(base or url, "1433")
  if not parsed then return nil, "Invalid SQL Server URL: " .. sql_util.redact_url(url) end

  local params = {}
  for part in (query or ""):gmatch("[^&]+") do
    local key, value = part:match("^([^=]+)=?(.*)$")
    if key then params[decode_query_value(key):lower()] = decode_query_value(value) end
  end

  local encrypt = (params.encrypt or "mandatory"):lower()
  local encrypt_aliases = {
    optional = "optional", o = "optional", ["false"] = "optional", no = "optional", ["0"] = "optional",
    mandatory = "mandatory", m = "mandatory", ["true"] = "mandatory", yes = "mandatory", ["1"] = "mandatory",
    strict = "strict", s = "strict",
  }
  parsed.encrypt = encrypt_aliases[encrypt]
  if not parsed.encrypt then
    return nil, "SQL Server encrypt must be optional, mandatory, or strict"
  end

  local trust = (params.trust_server_certificate or "false"):lower()
  if trust == "true" or trust == "yes" or trust == "1" then
    parsed.trust_server_certificate = true
  elseif trust ~= "false" and trust ~= "no" and trust ~= "0" and trust ~= "" then
    return nil, "SQL Server trust_server_certificate must be true or false"
  end

  parsed.server_certificate = params.server_certificate
  if parsed.server_certificate == "" then parsed.server_certificate = nil end
  if parsed.server_certificate and parsed.encrypt == "optional" then
    return nil, "SQL Server server_certificate requires mandatory or strict encryption"
  end
  if parsed.server_certificate and parsed.trust_server_certificate then
    return nil, "SQL Server server_certificate cannot be combined with trust_server_certificate=true"
  end
  return parsed
end

--- Split a possibly schema-qualified table name; unqualified names are "dbo".
local function split_table_name(table_name, default_schema)
  return sql_util.split_table_name(table_name, default_schema or "dbo")
end

--- Build connection-only argv. Statements always arrive through stdin.
local function sqlcmd_args(parsed)
  local server = parsed.host or "127.0.0.1"
  if parsed.port and parsed.port ~= "" then
    server = server .. "," .. parsed.port
  end

  local args = {
    "sqlcmd",
    "-S", server,
    -- Supplying -N makes sqlcmd validate the server certificate unless the
    -- URL explicitly opts into -C. Mandatory is the secure default.
    "-N" .. ({ optional = "o", mandatory = "m", strict = "s" })[parsed.encrypt or "mandatory"],
    "-W",
    "-s", "\t",
    -- Without -b sqlcmd exits 0 even when the server rejects the statement, so
    -- every `code ~= 0` guard below would be dead and a refused DROP would be
    -- reported as a success.
    "-b",
  }

  if parsed.trust_server_certificate then args[#args + 1] = "-C" end
  if parsed.server_certificate then
    args[#args + 1] = "-J"
    args[#args + 1] = parsed.server_certificate
  end

  if parsed.dbname and parsed.dbname ~= "" then
    table.insert(args, 4, parsed.dbname)
    table.insert(args, 4, "-d")
  end

  if parsed.user and parsed.user ~= "" then
    table.insert(args, 4, parsed.user)
    table.insert(args, 4, "-U")
  else
    table.insert(args, 4, "-E")
  end

  return args
end

--- Prefix the session settings required by ordinary query execution.
local function sqlcmd_stdin(sql_str, opts)
  opts = opts or {}
  local session = "SET QUOTED_IDENTIFIER ON;\n"
  if opts.nocount ~= false then session = session .. "SET NOCOUNT ON;\n" end
  return session .. sql_str
end

--- opts.env for one sqlcmd invocation: SQLCMDPASSWORD carrying the password so
--- it never appears in argv (visible via `ps`) -- the env-var equivalent of the
--- -P flag this replaces. No percent-decoding, same verbatim contract as
--- sqlcmd_args. Set (even to "") whenever a user is given, mirroring the old
--- -P/-P "" pairing with -U; empty when there is no user, since that means
--- -E integrated auth, which ignores any password.
local function sqlcmd_env(parsed)
  if not parsed.user or parsed.user == "" then return {} end
  return { SQLCMDPASSWORD = parsed.pass or "" }
end

--- Build and run the sqlcmd command, blocking.
local function sqlcmd(parsed, sql_str, timeout_ms, opts)
  return adapters.run_cmd(sqlcmd_args(parsed),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { stdin = sqlcmd_stdin(sql_str, opts), env = sqlcmd_env(parsed) })
end

--- Run GO-separated batches by feeding them to sqlcmd on stdin. `-Q` can only
--- carry one batch, and SET SHOWPLAN_TEXT has to be alone in its own.
local function sqlcmd_batch(parsed, batches, timeout_ms)
  local script = table.concat(batches, "\nGO\n") .. "\nGO\n"
  return adapters.run_cmd(sqlcmd_args(parsed),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { stdin = script, env = sqlcmd_env(parsed) })
end

--- Message for a non-zero sqlcmd exit. With -b the server's "Msg 208, ..." text
--- lands on stdout and stderr stays empty (stderr only carries client-side
--- failures), so stdout is the fallback before the bare exit code.
--- A batch that fails at run time (rather than at compile time) has already
--- printed the earlier statements' "(N rows affected)" by then, so report from
--- the server message onwards; output with no such line is passed through whole.
local function sqlcmd_error(stdout, stderr, code)
  if stderr and stderr ~= "" then return stderr end
  local out = vim.trim(stdout or "")
  if out ~= "" then
    local lines = vim.split(out, "\n", { plain = true })
    for i, line in ipairs(lines) do
      if line:match("^Msg %d") then
        return table.concat(lines, "\n", i)
      end
    end
    return out
  end
  return "sqlcmd exited with code " .. tostring(code)
end

local function parse_sqlcmd_table(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^%(%d+ rows? affected%)$") then
      table.insert(lines, line)
    end
  end
  if #lines == 0 then return { columns = {}, rows = {} } end

  local function split(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      field = vim.trim(field)
      if field == "NULL" then field = "" end
      table.insert(fields, field)
    end
    return fields
  end

  local columns = split(lines[1])
  local rows = {}
  for i = 2, #lines do
    local sep_probe = lines[i]:gsub("[\t%s%-]", "")
    if not (sep_probe == "" and lines[i]:find("-", 1, true)) then
      local row = split(lines[i])
      while #row < #columns do table.insert(row, "") end
      table.insert(rows, row)
    end
  end

  return { columns = columns, rows = rows }
end

--- Translate the LIMIT/OFFSET tail emitted by the shared query builder into
--- SQL Server's OFFSET/FETCH syntax. The adapter boundary is the only place
--- that knows the dialect, so every initial query and requery gets the fix.
local function normalize_query_sql(sql_str)
  local base, limit, offset = sql_str:match(
    "^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s+[Oo][Ff][Ff][Ss][Ee][Tt]%s+(%d+)%s*;?%s*$")
  if not base then
    base, limit = sql_str:match("^(.-)%s+[Ll][Ii][Mm][Ii][Tt]%s+(%d+)%s*;?%s*$")
    offset = "0"
  end
  if not base then return sql_str end

  -- OFFSET/FETCH requires an outer ORDER BY. Ignore any ORDER BY inside the
  -- raw-query wrapper; it does not satisfy SQL Server's outer SELECT.
  local lower = base:lower()
  local raw_alias_end = lower:find("%)%s+as%s+_grip")
  local outer = raw_alias_end and lower:sub(raw_alias_end) or lower
  if not outer:find("%sorder%s+by%s") then
    base = base .. " ORDER BY (SELECT NULL)"
  end
  return string.format("%s OFFSET %s ROWS FETCH NEXT %s ROWS ONLY", base, offset, limit)
end

local function run_query(sql_str, url, timeout_ms)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end

  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local stdout, stderr, code = sqlcmd(parsed, normalize_query_sql(sql_str), timeout_ms)
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  return parse_sqlcmd_table(stdout), nil
end

--- Non-blocking twin of run_query: same argv, same output parser, same guards.
--- Delivers (result, err) to `callback` instead of returning them.
local function run_query_async(sql_str, url, timeout_ms, callback)
  -- Both guards below deliver via vim.schedule: run_cmd_async's contract is
  -- that the callback never fires on the calling tick, and a caller must not
  -- be able to tell a guard rejection from a spawn failure by that timing
  -- difference.
  if vim.fn.executable("sqlcmd") == 0 then
    vim.schedule(function()
      callback(nil, "sqlcmd not found. Install Microsoft sqlcmd tools.")
    end)
    return
  end

  local parsed, parse_err = parse_url(url)
  if not parsed then
    vim.schedule(function() callback(nil, parse_err) end)
    return
  end

  adapters.run_cmd_async(sqlcmd_args(parsed),
    timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    function(stdout, stderr, code)
      if code ~= 0 then
        callback(nil, sqlcmd_error(stdout, stderr, code))
        return
      end
      callback(parse_sqlcmd_table(stdout), nil)
    end, { stdin = sqlcmd_stdin(normalize_query_sql(sql_str)), env = sqlcmd_env(parsed) })
end

function M.query(sql_str, url)
  local parsed, err = run_query(sql_str, url)
  if not parsed then return nil, err end
  return {
    rows = parsed.rows,
    columns = parsed.columns,
    primary_keys = {},
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end
  local stdout, stderr, code = sqlcmd(parsed, sql_str, nil, { nocount = false })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end
  local n = stdout:match("%((%d+) rows? affected%)") or stderr:match("%((%d+) rows? affected%)") or "0"
  return { affected = tonumber(n) or 0, message = stdout:gsub("%s+$", "") }, nil
end

function M.ping(url)
  if vim.fn.executable("sqlcmd") == 0 then return false end
  local parsed = parse_url(url)
  if not parsed then return false end
  local _, _, code = sqlcmd(parsed, "SELECT 1", 5000)
  return code == 0
end

function M.list_tables(url)
  local result, err = run_query([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      CASE TABLE_TYPE WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW')
    ORDER BY TABLE_SCHEMA, table_type DESC, TABLE_NAME
  ]], url)
  if not result then return nil, err end
  local out = {}
  for _, row in ipairs(result.rows) do
    table.insert(out, { name = row[1] or "", type = row[2] or "table" })
  end
  return out, nil
end

--- Reverse FK lookup: which tables reference table_name?
--- One schema-aware sys.foreign_keys query, so a qualified target
--- ("dbo.users") is resolved server-side instead of going through db.lua's
--- bare-name scan, which ddl._filter_referencing has to discard as ambiguous.
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      cs.name AS child_schema,
      ct.name AS child_table,
      cc.name AS fk_column,
      rc.name AS ref_column,
      fk.name AS constraint_name
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.tables ct ON ct.object_id = fk.parent_object_id
    JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
    JOIN sys.tables pt ON pt.object_id = fk.referenced_object_id
    JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
    JOIN sys.columns cc ON cc.object_id = fkc.parent_object_id
      AND cc.column_id = fkc.parent_column_id
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
      AND rc.column_id = fkc.referenced_column_id
    WHERE ps.name = '%s'
      AND pt.name = '%s'
    ORDER BY cs.name, ct.name, fk.name, fkc.constraint_column_id
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end

  local entries = {}
  for _, row in ipairs(result.rows) do
    local child_schema = row[1] or "dbo"
    local child_tbl = row[2] or ""
    -- Same naming as list_tables: dbo is implicit, other schemas are qualified.
    local full_name = (child_schema == "dbo") and child_tbl or (child_schema .. "." .. child_tbl)
    table.insert(entries, {
      table      = full_name,
      column     = row[3] or "",
      ref_column = row[4] or "",
      key        = row[5] or "",
    })
  end
  return db_util.group_referencing_fks(entries), nil
end

--- The length/precision-suffixed data_type expression, interpolated into both
--- get_column_info and SCHEMA_BATCH_SQL so the two can never drift: callers must
--- get the same string whether a table came from the batch or a per-table call.
--- SQL Server reports CHARACTER_MAXIMUM_LENGTH = -1 for the MAX types
--- (nvarchar(max), varbinary(max)), hence the dedicated arm ahead of the
--- positive-length one.
local DATA_TYPE_EXPR = [[
      DATA_TYPE +
        CASE
          WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN '(max)'
          WHEN CHARACTER_MAXIMUM_LENGTH IS NOT NULL AND CHARACTER_MAXIMUM_LENGTH > 0
            THEN '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS varchar(20)) + ')'
          WHEN NUMERIC_PRECISION IS NOT NULL AND DATA_TYPE NOT IN ('int','bigint','smallint','tinyint','bit')
            THEN '(' + CAST(NUMERIC_PRECISION AS varchar(20)) +
                 CASE WHEN NUMERIC_SCALE > 0 THEN ',' + CAST(NUMERIC_SCALE AS varchar(20)) ELSE '' END + ')'
          ELSE ''
        END AS data_type]]

function M.get_column_info(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      COLUMN_NAME,
%s,
      IS_NULLABLE,
      COALESCE(COLUMN_DEFAULT, '') AS column_default,
      ''
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '%s'
      AND TABLE_NAME = '%s'
    ORDER BY ORDINAL_POSITION
  ]], DATA_TYPE_EXPR, esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return nil, err end

  local cols = {}
  for _, row in ipairs(result.rows) do
    table.insert(cols, {
      column_name = row[1] or "",
      data_type = row[2] or "",
      is_nullable = row[3] or "",
      column_default = row[4] or "",
      constraints = row[5] or "",
    })
  end
  return cols, nil
end

function M.get_primary_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT kcu.COLUMN_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local pks = {}
  for _, row in ipairs(result.rows) do
    if row[1] and row[1] ~= "" then table.insert(pks, row[1]) end
  end
  return pks, nil
end

function M.get_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      kcu.COLUMN_NAME,
      ccu.TABLE_NAME AS ref_table,
      ccu.COLUMN_NAME AS ref_column
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
      ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
      AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
      ON rc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    JOIN INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE ccu
      ON ccu.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
      AND ccu.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
    WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
      AND tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
    ORDER BY kcu.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local fks = {}
  for _, row in ipairs(result.rows) do
    table.insert(fks, {
      column = row[1] or "",
      ref_table = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

--- The one schema-batch statement, shared by get_schema_batch and
--- get_schema_batch_async so the two paths can never query different things.
--- data_type comes from the same DATA_TYPE_EXPR get_column_info uses.
local SCHEMA_BATCH_SQL = string.format([[
    SELECT
      CASE WHEN TABLE_SCHEMA = 'dbo' THEN TABLE_NAME ELSE TABLE_SCHEMA + '.' + TABLE_NAME END AS table_name,
      COLUMN_NAME,
%s,
      IS_NULLABLE
    FROM INFORMATION_SCHEMA.COLUMNS
    ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
  ]], DATA_TYPE_EXPR)

--- Turn SCHEMA_BATCH_SQL's parsed rows into the completion cache format.
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- The single parser for both the blocking and non-blocking paths.
local function parse_schema_batch(result)
  if not result then return nil end
  local tables = {}
  for _, row in ipairs(result.rows) do
    local tname = row[1] or ""
    tables[tname] = tables[tname] or {}
    table.insert(tables[tname], {
      column_name = row[2] or "",
      data_type = row[3] or "",
      is_nullable = row[4] or "",
    })
  end
  return tables
end

function M.get_schema_batch(url)
  local result = run_query(SCHEMA_BATCH_SQL, url)
  return parse_schema_batch(result)
end

--- Async variant: same statement, same parser, non-blocking spawn.
--- Calls callback(tables), or callback(nil) when sqlcmd is missing or fails.
--- Used to pre-warm the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  run_query_async(SCHEMA_BATCH_SQL, url, nil, function(result)
    callback(parse_schema_batch(result))
  end)
end

function M.get_indexes(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      i.name AS index_name,
      CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY'
           WHEN i.is_unique = 1 THEN 'UNIQUE'
           ELSE 'INDEX' END AS index_type,
      STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS columns
    FROM sys.indexes i
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.objects o ON o.object_id = i.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND i.name IS NOT NULL
    GROUP BY i.name, i.is_primary_key, i.is_unique
    ORDER BY i.is_primary_key DESC, i.name
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local indexes = {}
  for _, row in ipairs(result.rows) do
    local cols = {}
    for col in (row[3] or ""):gmatch("([^,]+)") do table.insert(cols, vim.trim(col)) end
    table.insert(indexes, { name = row[1] or "", type = row[2] or "INDEX", columns = cols })
  end
  return indexes, nil
end

function M.get_constraints(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      tc.CONSTRAINT_NAME,
      tc.CONSTRAINT_TYPE,
      COALESCE(cc.CHECK_CLAUSE, '') AS definition
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    LEFT JOIN INFORMATION_SCHEMA.CHECK_CONSTRAINTS cc
      ON cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
    WHERE tc.TABLE_SCHEMA = '%s'
      AND tc.TABLE_NAME = '%s'
      AND tc.CONSTRAINT_TYPE IN ('CHECK', 'UNIQUE')
    ORDER BY tc.CONSTRAINT_TYPE, tc.CONSTRAINT_NAME
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result then return {}, err end
  local constraints = {}
  for _, row in ipairs(result.rows) do
    table.insert(constraints, { name = row[1] or "", type = row[2] or "", definition = row[3] or "" })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local schema, tbl = split_table_name(table_name, "dbo")
  local sql_str = string.format([[
    SELECT
      SUM(row_count) AS row_estimate,
      SUM(reserved_page_count) * 8192 AS size_bytes
    FROM sys.dm_db_partition_stats ps
    JOIN sys.objects o ON o.object_id = ps.object_id
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE s.name = '%s'
      AND o.name = '%s'
      AND ps.index_id IN (0, 1)
  ]], esc(schema), esc(tbl))

  local result, err = run_query(sql_str, url)
  if not result or not result.rows[1] then return nil, err or "No stats found" end
  return {
    row_estimate = tonumber(result.rows[1][1]) or 0,
    size_bytes = tonumber(result.rows[1][2]) or 0,
  }, nil
end

--- SHOWPLAN_TEXT has to be the only statement in its batch, so the plan cannot
--- go through run_query's single stdin script (which also prefixes SET NOCOUNT ON):
--- the server answers every such attempt with "The SET SHOWPLAN statements must
--- be the only statements in the batch". Two GO-separated batches on stdin.
function M.explain(sql_str, url)
  if vim.fn.executable("sqlcmd") == 0 then
    return nil, "sqlcmd not found. Install Microsoft sqlcmd tools."
  end
  local parsed, parse_err = parse_url(url)
  if not parsed then return nil, parse_err end

  local stdout, stderr, code = sqlcmd_batch(parsed,
    { "SET SHOWPLAN_TEXT ON", normalize_query_sql(sql_str) })
  if code ~= 0 then
    return nil, sqlcmd_error(stdout, stderr, code)
  end

  local result = parse_sqlcmd_table(stdout)
  local header = result.columns[1]
  local lines = {}
  for _, row in ipairs(result.rows) do
    local line = table.concat(row, " | ")
    -- SHOWPLAN emits one result set per statement and sqlcmd repeats the
    -- StmtText header for each, so the header shows up again mid-plan.
    if line ~= header then table.insert(lines, line) end
  end
  return { lines = lines }, nil
end

M._parse_url = parse_url
M._parse_sqlcmd_table = parse_sqlcmd_table
M._sqlcmd_args = sqlcmd_args
M._sqlcmd_env = sqlcmd_env
M._sqlcmd_stdin = sqlcmd_stdin
M._normalize_query_sql = normalize_query_sql

return M
