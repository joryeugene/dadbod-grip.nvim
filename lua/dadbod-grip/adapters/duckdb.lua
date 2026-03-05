-- adapters/duckdb.lua: DuckDB adapter (duckdb CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util = require("dadbod-grip.db")

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

  local result = vim.system(
    args,
    { text = true, timeout = effective_timeout }
  ):wait()

  local stderr = result.stderr or ""
  -- Track httpfs install state from stderr output
  if sql_str:find("https?://") then
    if stderr:find("httpfs") and (stderr:find("[Ee]rror") or stderr:find("[Ff]ail")) then
      _httpfs_state = nil  -- Reset so next attempt retries INSTALL
    else
      _httpfs_state = "installed"
    end
  end

  return result.stdout or "", stderr, result.code
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
    -- information_schema.tables only shows the current catalog.
    sql_str = [[
      SELECT database_name, table_name, 'table' AS ttype
      FROM duckdb_tables()
      WHERE internal = false
      UNION ALL
      SELECT database_name, view_name AS table_name, 'view' AS ttype
      FROM duckdb_views()
      WHERE internal = false
      ORDER BY database_name, ttype DESC, table_name
    ]]
  else
    sql_str = [[
      SELECT table_name,
        CASE table_type WHEN 'BASE TABLE' THEN 'table' ELSE 'view' END AS table_type
      FROM information_schema.tables
      WHERE table_schema = 'main'
      ORDER BY table_type DESC, table_name
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
    -- Main tables keep plain names so existing PK/column queries work unchanged.
    local main_catalog = db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
    for _, row in ipairs(parsed.rows) do
      local catalog = row[1] or main_catalog
      local tname = row[2] or ""
      local ttype = row[3] or "table"
      if catalog == main_catalog then
        table.insert(result, {
          name = tname,
          type = ttype,
          schema = catalog,
        })
      else
        table.insert(result, {
          name = catalog .. "." .. tname,
          type = ttype,
          schema = catalog,
        })
      end
    end
  else
    for _, row in ipairs(parsed.rows) do
      table.insert(result, { name = row[1] or "", type = row[2] or "table" })
    end
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

  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = "main"
    tbl = table_name
  end

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
    WHERE schema_name = '%s'
      AND table_name = '%s'
      AND constraint_type IN ('CHECK', 'UNIQUE', 'NOT NULL')
    ORDER BY constraint_type, constraint_name
  ]], schema:gsub("'", "''"), tbl:gsub("'", "''"))

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
      return
    end
  end
  table.insert(_attachments[url], { dsn = dsn, alias = alias, extension = ext })
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

  local args = { "duckdb" }
  if db_path ~= ":memory:" then args[#args + 1] = db_path end
  args[#args + 1] = "-c"
  args[#args + 1] = test_sql

  local result = vim.system(args, { text = true, timeout = 10000 }):wait()
  if result.code ~= 0 then
    local msg = (result.stderr or ""):gsub("%s+$", "")
    return msg ~= "" and msg or "Failed to attach database"
  end

  store_attachment(url, dsn, alias)
  return nil
end

--- Detach a previously attached database.
function M.detach(url, alias)
  local atts = _attachments[url]
  if not atts then return end
  for i, a in ipairs(atts) do
    if a.alias == alias then
      table.remove(atts, i)
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
    return
  end
  _attachments[url] = {}
  for _, a in ipairs(attachments) do
    local dsn = M.url_to_dsn(a.dsn)
    local err = M.attach(url, dsn, a.alias)
    if err then
      vim.notify(string.format("Skipped attachment '%s': %s", a.alias, err), vim.log.levels.WARN)
    end
  end
end

-- Exposed for testing
M._extract_path = extract_path
M._build_attach_prefix = build_attach_prefix
M._detect_extension = detect_extension
M._attach_unchecked = store_attachment

return M
