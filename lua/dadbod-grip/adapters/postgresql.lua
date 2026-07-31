-- adapters/postgresql.lua: PostgreSQL adapter (psql CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util  = require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")
local sql_util = require("dadbod-grip.sql")
local esc = sql_util.escape_literal

local M = {}

local DEFAULT_TIMEOUT = 30000

--- Split a possibly schema-qualified table name; unqualified names are "public".
local function split_table_name(table_name)
  return sql_util.split_table_name(table_name, "public")
end

--- Percent-decode a password component. libpq decodes URI percent-escapes
--- itself when a password is embedded in the connection string; once
--- strip_password below pulls the password out of the URL and hands it to
--- psql via PGPASSWORD instead, this restores that same decoding so libpq
--- still sees the password it would have seen (sql.lua:80-82 documents that
--- URLs otherwise go to CLI clients verbatim -- this is the one exception).
local function percent_decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Split url into (url-with-password-removed, percent-encoded-password-or-nil).
--- Same authority-parsing rule as sql_util.redact_url: the authority runs up
--- to the next "/", and inside it the split is on the LAST "@" so a password
--- that itself contains "@" is not mistaken for the host separator.
local function strip_password(url)
  local scheme, rest = url:match("^(%w+://)(.*)$")
  if not scheme then return url, nil end
  local authority, tail = rest:match("^([^/]*)(/.*)$")
  if not authority then authority, tail = rest, "" end

  local at = nil
  for i = #authority, 1, -1 do
    if authority:sub(i, i) == "@" then at = i; break end
  end
  if not at then return url, nil end

  local userpass, host = authority:sub(1, at - 1), authority:sub(at + 1)
  local colon = userpass:find(":", 1, true)
  if not colon then return url, nil end

  local user, pass = userpass:sub(1, colon - 1), userpass:sub(colon + 1)
  if pass == "" then return scheme .. user .. "@" .. host .. tail, nil end
  return scheme .. user .. "@" .. host .. tail, pass
end

--- argv for one psql invocation. Split out from psql() so the blocking and
--- non-blocking spawns run byte-identical command lines. The password never
--- appears here: strip_password removes it from the URL, and psql_env below
--- delivers it via PGPASSWORD instead, so it never shows up in a `ps` listing.
local function psql_args(url, sql_str)
  local stripped_url = strip_password(url)
  return { "psql", stripped_url, "-X", "--no-password", "--csv", "-c", sql_str }
end

--- opts.env for one psql invocation: PGPASSWORD carrying whatever
--- strip_password pulled out of the URL, decoded exactly once (see
--- percent_decode above). Returns an empty table -- not a PGPASSWORD key --
--- when the URL has no password, so --no-password falls through to
--- ~/.pgpass instead of authenticating with an empty password.
local function psql_env(url)
  local _, pass = strip_password(url)
  if not pass then return {} end
  return { PGPASSWORD = percent_decode(pass) }
end

local function psql(url, sql_str, timeout_ms)
  return adapters.run_cmd(psql_args(url, sql_str), timeout_ms or DEFAULT_TIMEOUT,
    { env = psql_env(url) })
end

local function split_routine_name(routine_name)
  local name = (routine_name or ""):gsub("%s*%b()%s*$", "")
  local schema, routine = name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
    routine = name
  end
  return sql_util.unquote_ident(schema), sql_util.unquote_ident(routine)
end

function M.query(sql_str, url)
  if vim.fn.executable("psql") == 0 then
    return nil, "psql not found. Install postgresql-client."
  end

  local stdout, stderr, code = psql(url, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("psql exited with code " .. code)
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
  local schema, tbl = split_table_name(table_name)

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
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, sql_str)
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
  local schema, tbl = split_table_name(table_name)

  local info_sql = string.format([[
    SELECT
      c.column_name,
      c.data_type || COALESCE('(' || c.character_maximum_length || ')', '') AS data_type,
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
  ]], esc(schema), esc(tbl),
      esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, info_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse column info" end

  local cols = {}
  for _, row in ipairs(parsed.rows) do
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

function M.get_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name)

  local fk_sql = string.format([[
    SELECT
      kcu.column_name,
      ccu.table_name AS ref_table,
      ccu.column_name AS ref_column
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
      AND tc.table_schema = ccu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = '%s'
      AND tc.table_name = '%s'
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local fks = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(fks, {
      column = row[1] or "",
      ref_table = row[2] or "",
      ref_column = row[3] or "",
    })
  end
  return fks, nil
end

--- Reverse FK lookup: which tables reference table_name?
--- Single information_schema query (no per-table scan).
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local schema, tbl = split_table_name(table_name)

  local fk_sql = string.format([[
    SELECT
      kcu.table_schema AS child_schema,
      kcu.table_name AS child_table,
      kcu.column_name AS fk_column,
      ccu.column_name AS ref_column,
      tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
      AND tc.table_schema = ccu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_schema = '%s'
      AND ccu.table_name = '%s'
    ORDER BY kcu.table_schema, kcu.table_name, tc.constraint_name, kcu.ordinal_position
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, fk_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query referencing foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local entries = {}
  for _, row in ipairs(parsed.rows) do
    local child_schema = row[1] or "public"
    local child_tbl    = row[2] or ""
    local full_name = (child_schema == "public") and child_tbl
      or (child_schema .. "." .. child_tbl)
    table.insert(entries, {
      table      = full_name,
      column     = row[3] or "",
      ref_column = row[4] or "",
      key        = row[5] or "",
    })
  end
  return db_util.group_referencing_fks(entries), nil
end

--- The one schema-batch statement, shared by get_schema_batch and
--- get_schema_batch_async so the two paths can never query different things.
local SCHEMA_BATCH_SQL = [[
    SELECT
      table_schema,
      table_name,
      column_name,
      data_type || COALESCE('(' || character_maximum_length || ')', '') AS data_type,
      is_nullable
    FROM information_schema.columns
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY table_schema, table_name, ordinal_position
  ]]

--- Parse SCHEMA_BATCH_SQL's CSV into the completion cache format.
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- public-schema tables use bare names ("users"); other schemas use "schema.table",
--- matching list_tables() output. The single parser for both the blocking and
--- non-blocking paths.
local function parse_schema_batch(stdout)
  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil end

  local tables = {}
  for _, row in ipairs(parsed.rows) do
    local schema_name = row[1] or "public"
    local tname       = row[2] or ""
    local col_name    = row[3] or ""
    local data_type   = row[4] or ""
    local nullable    = row[5] or ""
    local full_name = (schema_name == "public") and tname or (schema_name .. "." .. tname)
    tables[full_name] = tables[full_name] or {}
    table.insert(tables[full_name], { column_name = col_name, data_type = data_type, is_nullable = nullable })
  end
  return tables
end

--- Fetch all table columns in a single query (O(1) CLI spawns).
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
function M.get_schema_batch(url)
  local stdout, _, code = psql(url, SCHEMA_BATCH_SQL)
  if code ~= 0 then return nil end

  return parse_schema_batch(stdout)
end

--- Async variant: same statement, same parser, non-blocking spawn.
--- Calls callback(tables), or callback(nil) when psql fails.
--- Used to pre-warm the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  adapters.run_cmd_async(psql_args(url, SCHEMA_BATCH_SQL), DEFAULT_TIMEOUT, function(stdout, _, code)
    if code ~= 0 then callback(nil); return end
    callback(parse_schema_batch(stdout))
  end, { env = psql_env(url) })
end

function M.explain(sql_str, url)
  -- ANALYZE actually executes the statement, so it is only safe for plain
  -- read-only queries. DML (UPDATE/DELETE/INSERT/MERGE) and WITH (which may
  -- contain data-modifying CTEs) get a plain EXPLAIN so previewing a plan
  -- can never mutate data.
  local first_kw = (sql_str:match("^%s*(%a+)") or ""):upper()
  local read_only = first_kw == "SELECT" or first_kw == "TABLE" or first_kw == "VALUES"
  local explain_sql = (read_only and "EXPLAIN (FORMAT TEXT, ANALYZE) " or "EXPLAIN (FORMAT TEXT) ")
    .. sql_str
  local stdout, stderr, code = psql(url, explain_sql)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "EXPLAIN failed"
  end
  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse EXPLAIN output" end
  local lines = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(lines, row[1] or "")
  end
  return { lines = lines }, nil
end

function M.list_tables(url)
  local sql_str = [[
    SELECT
      CASE WHEN table_schema = 'public' THEN table_name
           ELSE table_schema || '.' || table_name END AS table_name,
      CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY table_schema, table_type DESC, table_name
  ]]
  local stdout, stderr, code = psql(url, sql_str)
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

function M.list_routines(url)
  if vim.fn.executable("psql") == 0 then
    return nil, "psql not found. Install postgresql-client."
  end

  local sql_str = [[
    SELECT
      p.oid::text AS source_id,
      n.nspname AS schema,
      p.proname AS name,
      pg_get_function_identity_arguments(p.oid) AS identity_arguments,
      CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS kind
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND p.prokind IN ('f', 'p')
    ORDER BY n.nspname, kind, p.proname, identity_arguments
  ]]

  local stdout, stderr, code = psql(url, sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to list routines"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse routine list" end

  local result = {}
  for _, row in ipairs(parsed.rows) do
    local source_id = row[1] or ""
    local schema_name = row[2] or "public"
    local routine_name = row[3] or ""
    local args = row[4] or ""
    local kind = row[5] or "function"
    -- PostgreSQL 14+ prefixes procedure arguments with an explicit "IN" mode
    -- ("IN order_id integer, IN new_status text") while functions omit it.
    -- Strip the bare IN so functions and procedures display consistently;
    -- meaningful modes (INOUT/OUT/VARIADIC) are kept.
    args = args:gsub("^IN ", ""):gsub(", IN ", ", ")
    local qualified = (schema_name == "public") and routine_name or (schema_name .. "." .. routine_name)
    table.insert(result, {
      name = qualified,
      display = qualified .. "(" .. args .. ")",
      type = kind,
      schema = schema_name,
      arguments = args,
      source_id = source_id,
    })
  end
  return result, nil
end

function M.get_routine_source(routine_name, url)
  if vim.fn.executable("psql") == 0 then
    return nil, "psql not found. Install postgresql-client."
  end

  local sql_str
  if tostring(routine_name):match("^%d+$") then
    sql_str = string.format([[
    SELECT pg_get_functiondef(p.oid) AS source
    FROM pg_proc p
    WHERE p.oid = %s::oid
    LIMIT 1
  ]], tostring(routine_name))
  else
    local schema, routine = split_routine_name(routine_name)
    sql_str = string.format([[
    SELECT pg_get_functiondef(p.oid) AS source
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = '%s'
      AND p.proname = '%s'
    ORDER BY p.oid
    LIMIT 1
  ]], esc(schema), esc(routine))
  end

  local stdout, stderr, code = psql(url, sql_str)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to get routine source"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed or not parsed.rows[1] or not parsed.rows[1][1] or parsed.rows[1][1] == "" then
    return nil, "Routine not found: " .. routine_name
  end

  return parsed.rows[1][1], nil
end

function M.get_indexes(table_name, url)
  local schema, tbl = split_table_name(table_name)

  local idx_sql = string.format([[
    SELECT
      indexname,
      CASE WHEN indisunique AND indisprimary THEN 'PRIMARY'
           WHEN indisunique THEN 'UNIQUE'
           ELSE 'INDEX'
      END AS index_type,
      array_to_string(ARRAY(
        SELECT a.attname
        FROM unnest(i.indkey) AS k
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k
      ), ', ') AS columns
    FROM pg_indexes pi
    JOIN pg_class c ON c.relname = pi.indexname AND c.relnamespace = (
      SELECT oid FROM pg_namespace WHERE nspname = '%s'
    )
    JOIN pg_index i ON i.indexrelid = c.oid
    WHERE pi.schemaname = '%s' AND pi.tablename = '%s'
    ORDER BY indisprimary DESC, indexname
  ]], esc(schema), esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, idx_sql)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query indexes"
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

function M.get_constraints(table_name, url)
  local schema, tbl = split_table_name(table_name)

  local sql_str = string.format([[
    SELECT
      tc.constraint_name,
      tc.constraint_type,
      COALESCE(
        cc.check_clause,
        (SELECT string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position)
         FROM information_schema.key_column_usage kcu
         WHERE kcu.constraint_name = tc.constraint_name
           AND kcu.table_schema = tc.table_schema)
      ) AS definition
    FROM information_schema.table_constraints tc
    LEFT JOIN information_schema.check_constraints cc
      ON cc.constraint_name = tc.constraint_name
      AND cc.constraint_schema = tc.table_schema
    WHERE tc.table_schema = '%s'
      AND tc.table_name = '%s'
      AND tc.constraint_type IN ('CHECK', 'UNIQUE')
    ORDER BY tc.constraint_type, tc.constraint_name
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query constraints"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local constraints = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(constraints, {
      name       = row[1] or "",
      type       = row[2] or "",
      definition = row[3] or "",
    })
  end
  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local schema, tbl = split_table_name(table_name)

  local stats_sql = string.format([[
    SELECT
      COALESCE(c.reltuples::bigint, 0) AS row_estimate,
      COALESCE(pg_total_relation_size(c.oid), 0) AS size_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '%s' AND c.relname = '%s'
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = psql(url, stats_sql)
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
  if vim.fn.executable("psql") == 0 then
    return nil, "psql not found. Install postgresql-client."
  end

  local stdout, stderr, code = psql(url, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("psql exited with code " .. code)
    return nil, msg
  end

  local n = stdout:match("UPDATE (%d+)") or
            stdout:match("INSERT %d+ (%d+)") or
            stdout:match("DELETE (%d+)") or
            "0"
  return { affected = tonumber(n) or 0, message = stdout:gsub("%s+$", "") }, nil
end

--- Ping the server by running SELECT 1. Returns true on success, false on any error.
function M.ping(url)
  if vim.fn.executable("psql") == 0 then return false end
  local _, _, code = adapters.run_cmd(psql_args(url, "SELECT 1"), 5000, { env = psql_env(url) })
  return code == 0
end

M._psql_args = psql_args
M._psql_env = psql_env

return M
