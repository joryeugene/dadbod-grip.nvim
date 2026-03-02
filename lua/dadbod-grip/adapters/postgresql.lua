-- adapters/postgresql.lua — PostgreSQL adapter (psql CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util = require("dadbod-grip.db")

local M = {}

local DEFAULT_TIMEOUT = 30000

local function psql(url, sql_str, timeout_ms)
  local result = vim.system(
    { "psql", url, "--no-password", "--csv", "-c", sql_str },
    { text = true, timeout = timeout_ms or DEFAULT_TIMEOUT }
  ):wait()
  return result.stdout or "", result.stderr or "", result.code
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
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
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
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
    tbl = table_name
  end

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
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"),
      schema:gsub("'", "''"), tbl:gsub("'", "''"))

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
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
    tbl = table_name
  end

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
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

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

function M.explain(sql_str, url)
  local explain_sql = "EXPLAIN (FORMAT TEXT, ANALYZE) " .. sql_str
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

function M.get_indexes(table_name, url)
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
    tbl = table_name
  end

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
  ]], schema:gsub("'", "''"), schema:gsub("'", "''"), tbl:gsub("'", "''"))

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

function M.get_table_stats(table_name, url)
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "public"
    tbl = table_name
  end

  local stats_sql = string.format([[
    SELECT
      COALESCE(c.reltuples::bigint, 0) AS row_estimate,
      COALESCE(pg_total_relation_size(c.oid), 0) AS size_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '%s' AND c.relname = '%s'
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

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

return M
