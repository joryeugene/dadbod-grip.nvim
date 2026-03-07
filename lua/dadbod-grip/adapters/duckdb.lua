-- adapters/duckdb.lua: DuckDB adapter (duckdb CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util  = require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")

local M = {}

local DEFAULT_TIMEOUT = 10000
local HTTP_TIMEOUT    = 60000

--- Track whether httpfs has been loaded in this Neovim session.
--- INSTALL is only needed once; after that LOAD suffices.
--- Reset to nil if an httpfs error occurs so the next query retries INSTALL.
local _httpfs_state = nil  -- nil = unknown, "installed" = ready, "failed" = unavailable

--- Attachment registry: url -> { {dsn, alias, extension}, ... }
--- Populated by M.attach(), persisted via connections.lua.
local _attachments = {}

--- Catalog cache: url -> { db_name -> true }
--- Populated lazily by querying duckdb_databases() for persistently-attached DBs
--- not registered via M.attach() (e.g. ATTACH statements baked into the .duckdb file).
local _catalog_cache = {}

--- Forward declaration: body assigned after duckdb() is defined (Lua scoping).
local get_catalog_set

--- Map DSN scheme prefix to the DuckDB extension that handles it.
local function detect_extension(dsn)
  if dsn:find("^postgres:") or dsn:find("^postgresql:") then return "postgres_scanner" end
  if dsn:find("^mysql:") then return "mysql_scanner" end
  if dsn:find("^sqlite:") then return "sqlite_scanner" end
  if dsn:find("^md:") or dsn:find("^motherduck:") then return "motherduck" end
  return nil
end

--- Build SQL prefix that installs extensions and attaches databases.
--- Idempotent: safe to prepend to every query.
local function build_attach_prefix(url)
  local atts = _attachments[url]
  if not atts or #atts == 0 then return "" end
  local seen_ext = {}
  local parts = {}
  for _, a in ipairs(atts) do
    if a.extension and not seen_ext[a.extension] then
      seen_ext[a.extension] = true
      table.insert(parts, string.format("INSTALL %s; LOAD %s;", a.extension, a.extension))
    end
    table.insert(parts, string.format("ATTACH IF NOT EXISTS '%s' AS %s;", a.dsn, a.alias))
  end
  return table.concat(parts, "\n") .. "\n"
end

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

--- Split a DuckDB table name into (catalog, schema, table).
--- Distinguishes attached catalogs from native schemas by checking _attachments.
---   "supplier.shipments"  (supplier is an ATTACH alias) -> ("supplier", "main", "shipments")
---   "analytics.events"    (analytics is a native schema) -> (nil, "analytics", "events")
---   "employees"           (plain name)                   -> (nil, "main", "employees")
--- Callers use:
---   local is_prefix = catalog and (catalog .. ".") or ""   -- for information_schema
---   local db_filter = catalog and ("database_name = '" .. catalog .. "' AND ") or ""  -- for system fns
local function split_catalog_schema_table(url, table_name)
  local prefix, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not prefix then
    return nil, "main", table_name
  end
  -- Fast path: explicitly registered attachments.
  local atts = _attachments[url] or {}
  for _, att in ipairs(atts) do
    if att.alias == prefix then
      return prefix, "main", tbl
    end
  end
  -- Fallback: query duckdb_databases() for persistently-attached DBs not
  -- registered via M.attach() (e.g. ATTACH baked into the .duckdb file).
  -- Result is cached so this is at most one extra query per URL.
  local db_path = extract_path(url)
  if db_path then
    local cats = get_catalog_set(db_path, url)
    if cats[prefix] then
      return prefix, "main", tbl
    end
  end
  -- Not a catalog: treat as a native DuckDB schema in the main DB.
  return nil, prefix, tbl
end

local function duckdb(db_path, sql_str, timeout_ms, url)
  local effective_sql = sql_str
  local effective_timeout = timeout_ms or DEFAULT_TIMEOUT

  -- Prepend ATTACH statements for cross-database federation
  if url then
    effective_sql = build_attach_prefix(url) .. effective_sql
  end

  if sql_str:find("https?://") then
    -- Only run INSTALL on first use; LOAD on every subsequent query.
    local prefix
    if _httpfs_state == "installed" then
      prefix = "LOAD httpfs;\n"
    else
      prefix = "INSTALL httpfs; LOAD httpfs;\n"
    end
    effective_sql = prefix .. effective_sql
    effective_timeout = math.max(effective_timeout, HTTP_TIMEOUT)
  end

  local args = { "duckdb", "-csv", "-header" }
  if db_path ~= ":memory:" then
    args[#args + 1] = db_path
  end
  args[#args + 1] = "-c"
  args[#args + 1] = effective_sql

  local stdout, stderr, code = adapters.run_cmd(args, effective_timeout)

  -- Track httpfs install state from stderr output
  if sql_str:find("https?://") then
    if stderr:find("httpfs") and (stderr:find("[Ee]rror") or stderr:find("[Ff]ail")) then
      _httpfs_state = nil  -- Reset so next attempt retries INSTALL
    else
      _httpfs_state = "installed"
    end
  end

  return stdout, stderr, code
end

--- Assigned here (after duckdb() is in scope) so the upvalue resolves correctly.
--- Queries duckdb_databases() and returns a set of non-internal catalog names.
--- Result is cached per URL; invalidated when attachments change.
get_catalog_set = function(db_path, url)
  if _catalog_cache[url] then return _catalog_cache[url] end
  local stdout = duckdb(db_path,
    "SELECT database_name FROM duckdb_databases() WHERE NOT internal", nil, url)
  local cats = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    if line ~= "database_name" and line ~= "" then
      cats[line] = true
    end
  end
  _catalog_cache[url] = cats
  return cats
end

--- Non-blocking async variant: spawns DuckDB and calls callback(stdout, stderr, code)
--- from the main Neovim loop via vim.schedule. Used for schema pre-warming.
local function duckdb_async(db_path, sql_str, timeout_ms, url, callback)
  local effective_sql = url and (build_attach_prefix(url) .. sql_str) or sql_str
  local args = { "duckdb", "-csv", "-header" }
  if db_path ~= ":memory:" then
    args[#args + 1] = db_path
  end
  args[#args + 1] = "-c"
  args[#args + 1] = effective_sql
  vim.system(args, { text = true, timeout = timeout_ms or 8000 }, function(out)
    vim.schedule(function()
      callback(out.stdout or "", out.stderr or "", out.code)
    end)
  end)
end

--- Run DML without CSV mode (to get change count output).
local function duckdb_exec(db_path, sql_str, timeout_ms, url)
  local effective_sql = sql_str
  if url then
    effective_sql = build_attach_prefix(url) .. effective_sql
  end

  local args = { "duckdb" }
  if db_path ~= ":memory:" then
    args[#args + 1] = db_path
  end
  args[#args + 1] = "-c"
  args[#args + 1] = effective_sql

  return adapters.run_cmd(args, timeout_ms or DEFAULT_TIMEOUT)
end

function M.query(sql_str, url)
  if vim.fn.executable("duckdb") == 0 then
    return nil, "duckdb not found. Install duckdb."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local stdout, stderr, code = duckdb(db_path, sql_str, nil, url)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("duckdb exited with code " .. code)
    -- Surface actionable hint for httpfs / remote URL failures
    if sql_str:find("https?://") then
      if msg:find("[Hh]ttpfs") or msg:find("[Ee]xtension") then
        msg = msg .. "\nHint: run `duckdb -c 'INSTALL httpfs'` once to install the extension."
      elseif msg:find("[Uu]nable to connect") or msg:find("[Hh]TTP [Ee]rror") then
        msg = msg .. "\nHint: check the URL is reachable and the file exists."
      end
    end
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

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)
  local sql_str

  if catalog then
    -- Attached catalog: duckdb_constraints() spans all catalogs.
    sql_str = string.format([[
      SELECT UNNEST(constraint_column_names) AS column_name
      FROM duckdb_constraints()
      WHERE database_name = '%s'
        AND schema_name = '%s'
        AND table_name = '%s'
        AND constraint_type = 'PRIMARY KEY'
    ]], catalog:gsub("'", "''"), schema:gsub("'", "''"), tbl:gsub("'", "''"))
  else
    -- Main DB: use duckdb_constraints() with a string-literal database_name filter
    -- (same reason as get_column_info — information_schema fails with attachments).
    local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
    sql_str = string.format([[
      SELECT UNNEST(constraint_column_names) AS column_name
      FROM duckdb_constraints()
      WHERE database_name = '%s'
        AND schema_name = '%s'
        AND table_name = '%s'
        AND constraint_type = 'PRIMARY KEY'
    ]], main_catalog:gsub("'", "''"), schema:gsub("'", "''"), tbl:gsub("'", "''"))
  end

  local stdout, stderr, code = duckdb(db_path, sql_str, nil, url)
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

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)
  local info_sql

  if catalog then
    -- Attached catalog: use duckdb_columns() which works for all attachment types
    -- (SQLite, PostgreSQL, etc.) — they may not expose information_schema.
    info_sql = string.format([[
      SELECT
        column_name,
        data_type,
        '' AS is_nullable,
        COALESCE(column_default, '') AS column_default,
        '' AS constraints
      FROM duckdb_columns()
      WHERE database_name = '%s'
        AND schema_name = '%s'
        AND table_name = '%s'
      ORDER BY column_index
    ]], catalog:gsub("'", "''"), schema:gsub("'", "''"), tbl:gsub("'", "''"))
  else
    -- Main DB: use duckdb_columns() with a string-literal database_name filter.
    -- information_schema.columns fails when attachments are present (DuckDB enumerates
    -- all catalogs including the SQLite one, which doesn't support duckdb_columns()).
    -- duckdb_columns() with WHERE database_name = '...' is immune to this.
    -- Catalog names from tempname-style paths may start with digits (invalid SQL identifiers),
    -- so string literals are required here rather than catalog-qualified syntax.
    local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
    info_sql = string.format([[
      SELECT
        column_name,
        data_type,
        CASE WHEN is_nullable THEN 'YES' ELSE 'NO' END AS is_nullable,
        COALESCE(column_default, '') AS column_default,
        '' AS constraints
      FROM duckdb_columns()
      WHERE database_name = '%s'
        AND schema_name = '%s'
        AND table_name = '%s'
      ORDER BY column_index
    ]], main_catalog:gsub("'", "''"), schema:gsub("'", "''"), tbl:gsub("'", "''"))
  end

  local stdout, stderr, code = duckdb(db_path, info_sql, nil, url)
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

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)

  if catalog then
    -- Attached catalogs (SQLite, PG, etc.) have no cross-catalog FK introspection.
    -- FK constraints within an attached DB are not surfaced by information_schema
    -- or duckdb_constraints() in all attachment types. Return empty gracefully.
    return {}, nil
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

  local stdout, stderr, code = duckdb(db_path, fk_sql, nil, url)
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

  local stdout, stderr, code = duckdb(db_path, "EXPLAIN " .. sql_str, nil, url)
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

  local has_attachments = _attachments[url] and #_attachments[url] > 0
  local sql_str
  if has_attachments then
    -- duckdb_tables()/duckdb_views() span all catalogs (including attached databases).
    -- Include schema_name so native schemas in the main DB are prefixed correctly.
    sql_str = [[
      SELECT database_name, schema_name, table_name, 'table' AS ttype
      FROM duckdb_tables()
      WHERE internal = false
      UNION ALL
      SELECT database_name, schema_name, view_name AS table_name, 'view' AS ttype
      FROM duckdb_views()
      WHERE internal = false
      ORDER BY database_name, schema_name, ttype DESC, table_name
    ]]
  else
    -- No attachments: include table_schema to surface native DuckDB schemas.
    sql_str = [[
      SELECT table_schema, table_name,
        CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
      FROM information_schema.tables
      WHERE table_schema NOT IN ('information_schema', 'pg_catalog')
      ORDER BY table_schema, table_type DESC, table_name
    ]]
  end

  local stdout, stderr, code = duckdb(db_path, sql_str, nil, url)
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to list tables"
  end
  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse table list" end

  local result = {}
  if has_attachments then
    -- Derive the main database's catalog name from the file path.
    -- DuckDB names catalogs after the filename (e.g., "softrear" for softrear.duckdb).
    local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
    for _, row in ipairs(parsed.rows) do
      local catalog    = row[1] or main_catalog
      local schema_name = row[2] or "main"
      local tname      = row[3] or ""
      local ttype      = row[4] or "table"
      local full_name, schema_group
      if catalog == main_catalog then
        -- Main database: plain name for main schema, schema-prefixed for native schemas.
        if schema_name == "main" then
          full_name    = tname
          schema_group = main_catalog
        else
          full_name    = schema_name .. "." .. tname
          schema_group = schema_name
        end
      else
        -- Attached catalog: always prefix with the catalog alias.
        full_name    = catalog .. "." .. tname
        schema_group = catalog
      end
      table.insert(result, { name = full_name, type = ttype, schema = schema_group })
    end
  else
    -- No attachments: surface native schemas with a schema-prefixed name.
    for _, row in ipairs(parsed.rows) do
      local schema_name = row[1] or "main"
      local tname = row[2] or ""
      local ttype = row[3] or "table"
      if schema_name == "main" then
        table.insert(result, { name = tname, type = ttype })
      else
        table.insert(result, { name = schema_name .. "." .. tname, type = ttype, schema = schema_name })
      end
    end
  end
  return result, nil
end

function M.get_indexes(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)
  local is_prefix = catalog and (catalog .. ".") or ""
  local db_filter = catalog and string.format("di.database_name = '%s' AND ", catalog:gsub("'", "''")) or ""

  local idx_sql = string.format([[
    SELECT
      index_name,
      CASE WHEN is_unique AND is_primary THEN 'PRIMARY'
           WHEN is_unique THEN 'UNIQUE'
           ELSE 'INDEX'
      END AS index_type,
      (SELECT string_agg(column_name, ', ')
       FROM %sinformation_schema.key_column_usage kcu
       JOIN %sinformation_schema.table_constraints tc
         ON tc.constraint_name = kcu.constraint_name
         AND tc.table_schema = kcu.table_schema
       WHERE tc.table_schema = di.schema_name
         AND tc.table_name = di.table_name
         AND tc.constraint_type = CASE WHEN di.is_primary THEN 'PRIMARY KEY' ELSE 'UNIQUE' END
      ) AS columns
    FROM duckdb_indexes() di
    WHERE %sdi.schema_name = '%s' AND di.table_name = '%s'
    ORDER BY is_primary DESC, index_name
  ]], is_prefix, is_prefix, db_filter, schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, idx_sql, nil, url)
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

function M.get_constraints(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)
  local db_filter = catalog and string.format("database_name = '%s' AND ", catalog:gsub("'", "''")) or ""

  -- duckdb_constraints() returns CHECK and UNIQUE with column lists and expressions
  local sql_str = string.format([[
    SELECT
      CASE constraint_type
        WHEN 'CHECK' THEN 'check_' || CAST(rowid AS VARCHAR)
        ELSE array_to_string(constraint_column_names, ', ')
      END AS constraint_name,
      constraint_type,
      COALESCE(expression, array_to_string(constraint_column_names, ', ')) AS definition
    FROM duckdb_constraints()
    WHERE %sschema_name = '%s'
      AND table_name = '%s'
      AND constraint_type IN ('CHECK', 'UNIQUE', 'NOT NULL')
    ORDER BY constraint_type, constraint_name
  ]], db_filter, schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, sql_str, nil, url)
  if code ~= 0 then
    -- duckdb_constraints() may not exist in older versions
    return {}, nil
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
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)
  local db_filter = catalog and string.format("database_name = '%s' AND ", catalog:gsub("'", "''")) or ""

  local stats_sql = string.format([[
    SELECT
      estimated_size,
      0 AS size_bytes
    FROM duckdb_tables()
    WHERE %sschema_name = '%s' AND table_name = '%s'
  ]], db_filter, schema:gsub("'", "''"), tbl:gsub("'", "''"))

  local stdout, stderr, code = duckdb(db_path, stats_sql, nil, url)
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

  local stdout, stderr, code = duckdb_exec(db_path, sql_str, nil, url)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("duckdb exited with code " .. code)
    return nil, msg
  end

  -- DuckDB text mode outputs "Changes: N" or row counts
  local n = stdout:match("(%d+)") or "0"
  return { affected = tonumber(n) or 0, message = n .. " row(s) affected" }, nil
end

--- Resolve relative file paths in a DSN to absolute paths.
--- "sqlite:.grip/foo.db" -> "sqlite:/abs/path/.grip/foo.db"
--- "postgres:dbname=x" -> "postgres:dbname=x" (unchanged, no file path)
local function resolve_dsn_path(dsn)
  local prefix, path = dsn:match("^(sqlite:)(.*)")
  if not prefix then return dsn end
  if path:sub(1, 1) ~= "/" then
    path = vim.fn.fnamemodify(path, ":p")
  end
  return prefix .. path
end

--- Convert a dadbod URL to a DuckDB ATTACH-compatible DSN.
--- "postgresql://user:pass@host:port/dbname" -> "postgres:dbname=dbname user=user password=pass host=host port=port"
--- "sqlite:path/to/db" -> "sqlite:path/to/db" (unchanged)
--- "mysql://user:pass@host/db" -> "mysql:host=host user=user password=pass database=db"
function M.url_to_dsn(url)
  -- SQLite: already in correct format
  if url:find("^sqlite:") then return url end

  -- Strip postgres(ql):// prefix: Lua ? only makes one char optional,
  -- so we match both schemes explicitly
  local pg_rest = url:match("^postgresql://(.+)") or url:match("^postgres://(.+)")
  if pg_rest then
    -- With credentials: user:pass@host:port/db
    local pg_user, pg_pass, pg_host, pg_port, pg_db =
      pg_rest:match("^([^:@]+):?([^@]*)@([^:/]+):?(%d*)/?(.*)")
    if pg_user then
      local parts = { "postgres:dbname=" .. (pg_db ~= "" and pg_db or pg_user) }
      table.insert(parts, "user=" .. pg_user)
      if pg_pass ~= "" then table.insert(parts, "password=" .. pg_pass) end
      table.insert(parts, "host=" .. pg_host)
      if pg_port ~= "" then table.insert(parts, "port=" .. pg_port) end
      return table.concat(parts, " ")
    end
    -- Without credentials: host:port/db
    local pg_host_only, pg_port_only, pg_db_only =
      pg_rest:match("^([^:/]+):?(%d*)/?(.*)")
    if pg_host_only then
      local parts = { "postgres:dbname=" .. (pg_db_only ~= "" and pg_db_only or "postgres") }
      table.insert(parts, "host=" .. pg_host_only)
      if pg_port_only ~= "" then table.insert(parts, "port=" .. pg_port_only) end
      return table.concat(parts, " ")
    end
  end

  -- MySQL URL -> mysql_scanner DSN
  local my_user, my_pass, my_host, my_port, my_db =
    url:match("^mysql://([^:@]+):?([^@]*)@([^:/]+):?(%d*)/?(.*)")
  if my_user then
    local parts = { "mysql:host=" .. my_host }
    table.insert(parts, "user=" .. my_user)
    if my_pass ~= "" then table.insert(parts, "password=" .. my_pass) end
    if my_db ~= "" then table.insert(parts, "database=" .. my_db) end
    if my_port ~= "" then table.insert(parts, "port=" .. my_port) end
    return table.concat(parts, " ")
  end

  -- Fallback: return as-is
  return url
end

--- Store an attachment without validation (used by tests and load_attachments).
local function store_attachment(url, dsn, alias)
  dsn = resolve_dsn_path(dsn)
  local ext = detect_extension(dsn)
  _attachments[url] = _attachments[url] or {}
  for _, a in ipairs(_attachments[url]) do
    if a.alias == alias then
      a.dsn = dsn
      a.extension = ext
      _catalog_cache[url] = nil  -- attachment list changed; re-query on next use
      return
    end
  end
  table.insert(_attachments[url], { dsn = dsn, alias = alias, extension = ext })
  _catalog_cache[url] = nil  -- attachment list changed; re-query on next use
end

--- Attach an external database to a DuckDB session.
--- Validates the connection before storing. Returns nil on success, error string on failure.
--- The attachment is prepended to every query via build_attach_prefix().
function M.attach(url, dsn, alias)
  dsn = resolve_dsn_path(dsn)
  local db_path = extract_path(url)
  if not db_path then return "Invalid DuckDB URL" end

  -- Validate: try the ATTACH before storing (a broken attachment kills all queries)
  local ext = detect_extension(dsn)
  local test_sql = ""
  if ext then
    test_sql = string.format("INSTALL %s; LOAD %s;\n", ext, ext)
  end
  test_sql = test_sql .. string.format("ATTACH IF NOT EXISTS '%s' AS %s;\n", dsn:gsub("'", "''"), alias)
  test_sql = test_sql .. "SELECT 42;"

  -- Validate in-memory: avoids acquiring a write lock on the main db file.
  -- If we opened db_path here, we'd race with list_tables / get_schema_batch_async
  -- (both also open the same file), causing "Failed to lock file" on connection switch.
  local args = { "duckdb", "-c", test_sql }

  local _, stderr_attach, code_attach = adapters.run_cmd(args, 10000)
  if code_attach ~= 0 then
    local msg = stderr_attach:gsub("%s+$", "")
    return msg ~= "" and msg or "Failed to attach database"
  end

  store_attachment(url, dsn, alias)
  -- warm_schema is NOT scheduled here: the caller (connections.switch or GripAttach)
  -- is responsible, so only one async duckdb process opens the file after connect.
  return nil
end

--- Detach a previously attached database.
function M.detach(url, alias)
  local atts = _attachments[url]
  if not atts then return end
  for i, a in ipairs(atts) do
    if a.alias == alias then
      table.remove(atts, i)
      _catalog_cache[url] = nil  -- attachment list changed
      return
    end
  end
end

--- Get all attachments for a DuckDB connection URL.
function M.get_attachments(url)
  return _attachments[url] or {}
end

--- Bulk-load attachments (called on connection switch from persisted data).
--- Runs DSNs through url_to_dsn and validates each via M.attach().
--- Skips attachments that fail validation (stale/unreachable).
function M.load_attachments(url, attachments)
  if not attachments or #attachments == 0 then
    _attachments[url] = nil
    _catalog_cache[url] = nil
    return
  end
  _attachments[url] = {}
  _catalog_cache[url] = nil
  for _, a in ipairs(attachments) do
    local dsn = M.url_to_dsn(a.dsn)
    local err = M.attach(url, dsn, a.alias)
    if err then
      vim.notify(string.format("Skipped attachment '%s': %s", a.alias, err), vim.log.levels.WARN)
    end
  end
end

--- Build the schema batch SQL for get_schema_batch / get_schema_batch_async.
--- With attachments: UNION ALL of main-catalog columns (full) + attached-catalog
--- table names only (fast: no remote column scan). One CLI spawn covers both.
--- Without attachments: plain information_schema.columns query.
local function _make_schema_batch_sql(has_attachments, main_catalog)
  if has_attachments then
    -- 6-column result: rtype, database_name, schema_name, table_name, column_name, data_type
    -- 'col' rows = all DB columns (main + attached catalogs via duckdb_columns())
    -- 'tbl' rows = views only (duckdb_columns() does not cover views)
    return [[
      SELECT 'col' AS rtype, database_name, schema_name, table_name, column_name, data_type
      FROM duckdb_columns()
      WHERE internal = false
      UNION ALL
      SELECT 'tbl' AS rtype, database_name, schema_name, view_name, '', ''
      FROM duckdb_views()
      WHERE internal = false
      ORDER BY 1, 2, 3
    ]]
  else
    -- No attachments: information_schema.columns covers main DB + native schemas.
    return [[
      SELECT table_schema, table_name, column_name, data_type
      FROM information_schema.columns
      WHERE table_schema NOT IN ('information_schema', 'pg_catalog')
      ORDER BY table_schema, table_name, ordinal_position
    ]]
  end
end

--- Parse CSV rows from _make_schema_batch_sql into the schema cache format.
--- Returns { [full_table_name] = [{column_name, data_type, is_nullable}] } or nil.
local function _parse_schema_batch_rows(parsed, has_attachments, main_catalog)
  if not parsed then return nil end
  local tables = {}
  if has_attachments then
    -- 6-column rows: rtype, database_name, schema_name, table_name, col_name, data_type
    for _, row in ipairs(parsed.rows) do
      local rtype       = row[1] or ""
      local catalog     = row[2] or main_catalog
      local schema_name = row[3] or "main"
      local tname       = row[4] or ""
      if rtype == "col" then
        -- Column row from duckdb_columns() — covers both main catalog and attached catalogs.
        local col_name  = row[5] or ""
        local data_type = row[6] or ""
        local full_name
        if catalog == main_catalog then
          full_name = (schema_name == "main") and tname or (schema_name .. "." .. tname)
        else
          -- Attached catalog: prefix with catalog alias (matches list_tables() output)
          full_name = catalog .. "." .. tname
        end
        tables[full_name] = tables[full_name] or {}
        table.insert(tables[full_name], { column_name = col_name, data_type = data_type, is_nullable = "" })
      else
        -- View row: duckdb_columns() does not include views, so register them name-only.
        local full_name
        if catalog == main_catalog then
          full_name = (schema_name == "main") and tname or (schema_name .. "." .. tname)
        else
          full_name = catalog .. "." .. tname
        end
        tables[full_name] = tables[full_name] or {}
      end
    end
  else
    -- 4-column rows: table_schema, table_name, column_name, data_type
    for _, row in ipairs(parsed.rows) do
      local schema_name = row[1] or "main"
      local tname       = row[2] or ""
      local col_name    = row[3] or ""
      local data_type   = row[4] or ""
      local full_name = (schema_name == "main") and tname or (schema_name .. "." .. tname)
      tables[full_name] = tables[full_name] or {}
      table.insert(tables[full_name], { column_name = col_name, data_type = data_type, is_nullable = "" })
    end
  end
  return tables
end

--- Fetch all table columns in a single DuckDB query (O(1) CLI spawns).
--- Returns { [full_table_name] = [{column_name, data_type, is_nullable}] } or nil on error.
--- full_table_name matches list_tables() output:
---   main-schema tables      -> "employees"
---   native DuckDB schemas   -> "analytics.events"
---   attached catalogs       -> "supplier.orders"
function M.get_schema_batch(url)
  local db_path = extract_path(url)
  if not db_path then return nil end

  local has_attachments = _attachments[url] and #_attachments[url] > 0
  local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
  local sql_str = _make_schema_batch_sql(has_attachments, main_catalog)

  local stdout, _, code = duckdb(db_path, sql_str, nil, url)
  if code ~= 0 then return nil end

  return _parse_schema_batch_rows(db_util.parse_csv(stdout), has_attachments, main_catalog)
end

--- Async variant: fetches schema batch without blocking. Calls callback(tables) when done.
--- Used for pre-warming the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  local db_path = extract_path(url)
  if not db_path then callback(nil); return end

  local has_attachments = _attachments[url] and #_attachments[url] > 0
  local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
  local sql_str = _make_schema_batch_sql(has_attachments, main_catalog)

  duckdb_async(db_path, sql_str, 8000, url, function(stdout, _, code)
    if code ~= 0 then callback(nil); return end
    callback(_parse_schema_batch_rows(db_util.parse_csv(stdout), has_attachments, main_catalog))
  end)
end

-- Exposed for testing
M._extract_path = extract_path
M._build_attach_prefix = build_attach_prefix
M._detect_extension = detect_extension
M._attach_unchecked = store_attachment

return M
