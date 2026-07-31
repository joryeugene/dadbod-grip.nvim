-- adapters/duckdb.lua: DuckDB adapter (duckdb CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util  = require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")
local sql_util = require("dadbod-grip.sql")
local esc      = sql_util.escape_literal

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

-- ── credential masking ────────────────────────────────────────────────────
-- Defined up here, above everything that spawns the CLI, because every one of
-- those paths carries an attachment DSN into DuckDB and can get it echoed
-- back in stderr. See redact_query_error at the end of this block.

--- Keys whose value is a credential in a "key=value ..." DSN.
---
--- Audited against the DSN dialects DuckDB's scanners actually accept rather
--- than grown one entry at a time:
---   * libpq (postgres_scanner) -- `password` and `sslpassword`, the client
---     key passphrase. Deliberately NOT `passfile` or `sslkey`: those are
---     paths, and masking a path only makes the error unactionable without
---     protecting anything.
---   * mysql_scanner and the other key=value dialects -- `passwd`, `pwd`.
---   * token-bearing DSNs (MotherDuck, DuckDB secrets, object stores).
local DSN_SECRET_KEYS = {
  password = true, sslpassword = true, passwd = true, pwd = true,
  token = true, motherduck_token = true, access_token = true,
  auth_token = true, session_token = true,
  api_key = true, apikey = true,
  secret = true, secret_access_key = true,
}

--- Walk the `key=value` pairs of a libpq/DuckDB-style DSN, calling
--- fn(key, raw_value) for each. `raw_value` is the span exactly as it appears
--- in the DSN, backslash escapes included, because that is the form the CLI
--- echoes back and therefore the form that has to be masked.
---
--- Not a gmatch("([%w_]+)=(%S+)"): libpq conninfo lets a value be quoted and
--- contain spaces, and lets a quote inside a quoted value be backslash
--- escaped. :GripAttach hands the DSN through verbatim (init.lua rejoins its
--- argv with spaces), so both forms are two keystrokes away. A
--- whitespace-terminated scan truncates `password='hun ter2'` to `'hun`, and
--- a scan that stops at the first quote truncates `password='hun\'ter2'` to
--- `hun\` -- both verified against DuckDB v1.5.5, which echoes the whole
--- quoted value back.
--- @param dsn string
--- @param fn fun(key: string, raw_value: string)
local function each_dsn_pair(dsn, fn)
  local pos = 1
  while pos <= #dsn do
    local s, e, key = dsn:find("([%w_]+)=", pos)
    if not s then return end
    local quote = dsn:sub(e + 1, e + 1)
    local value
    if quote == "'" or quote == '"' then
      -- Scan to the real closing quote, stepping over "\<any>" escapes.
      local i = e + 2
      while i <= #dsn do
        local ch = dsn:sub(i, i)
        if ch == "\\" then
          i = i + 2
        elseif ch == quote then
          break
        else
          i = i + 1
        end
      end
      -- Unterminated quote: the rest of the DSN is the value. Erring long is
      -- the safe direction -- it can only mask more, never less.
      value = dsn:sub(e + 2, math.min(i, #dsn + 1) - 1)
      pos = i + 1
    else
      value = dsn:match("^%S*", e + 1) or ""
      pos = e + 1 + #value
    end
    fn(key, value)
    pos = math.max(pos, e + 1)
  end
end

--- Strip the credentials of `dsn` out of a DuckDB error message.
---
--- The CLI echoes the DSN back in its own stderr, so a credentialed
--- postgres/mysql/MotherDuck DSN reappears in the error text we hand to
--- vim.notify(). What it echoes is NOT the string we passed, though: DuckDB
--- v1.5.5 rewrites it first. "postgresql://u:pw@h/db" comes back as
---
---   IO Error: Cannot open file "<cwd>/postgresql:/u:pw@h/db": ...
---
--- -- one slash gone, the process cwd prepended -- and a "postgres:k=v ..."
--- DSN comes back with the "postgres:" prefix stripped. So masking by
--- whole-DSN substitution does not fire on the messages that actually occur.
---
--- This masks the credential *values* instead, wherever they appear and
--- whatever surrounds them, which survives that rewriting as well as
--- re-quoting, line-splitting and truncation:
---   1. the password out of a URL-shaped DSN's authority (sql_util shares the
---      last-"@" authority rule with redact_url and url_to_dsn);
---   2. every `password=` / `token=`-style value of a key=value DSN --
---      redact_url cannot see those at all, since a DuckDB DSN has no
---      "user:pass@" run for it to match. Both the raw span and its
---      backslash-unescaped form are masked, since which one the CLI echoes
---      depends on how far into libpq the DSN got before it failed.
---
--- The message as a whole is deliberately NOT run through redact_url(): its
--- doc comment warns that a free-form message can over-mask on an incidental
--- "word:word@word". Working from the known secret material instead means a
--- genuine diagnostic ("Extension not found") survives untouched.
--- @param msg string
--- @param dsn string|nil
--- @return string
local function redact_attach_error(msg, dsn)
  if not dsn or dsn == "" then return msg end
  local function mask(value)
    if value and value ~= "" then
      -- Function replacement, so a "%1" in a password is not expanded.
      msg = msg:gsub(vim.pesc(value), function() return "***" end)
    end
  end
  mask(sql_util.url_password(dsn))
  each_dsn_pair(dsn, function(key, value)
    if DSN_SECRET_KEYS[key:lower()] then
      mask(value)
      local unescaped = value:gsub("\\(.)", "%1")
      if unescaped ~= value then mask(unescaped) end
    end
  end)
  return msg
end

--- Strip the credentials of every DSN attached to `url` out of a DuckDB
--- error message.
---
--- redact_attach_error only guards M.attach(). But build_attach_prefix() puts
--- those same DSNs at the head of *every* query, so the moment an attached
--- server becomes unreachable -- a restart, a dropped VPN -- the password
--- comes back in the stderr of an ordinary SELECT and goes to vim.notify via
--- view.lua. Applied inside the three functions that spawn the CLI with a
--- prefix (duckdb, duckdb_async, duckdb_exec), so no individual error-return
--- site has to remember.
--- @param msg string|nil
--- @param url string|nil
--- @return string
local function redact_query_error(msg, url)
  if not msg or msg == "" or not url then return msg or "" end
  for _, a in ipairs(_attachments[url] or {}) do
    msg = redact_attach_error(msg, a.dsn)
  end
  return msg
end

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
    -- Escape single quotes in the DSN: it is a string literal here, and an
    -- unescaped quote breaks every subsequent query on this connection.
    -- Matches the validation path in M.attach().
    local dsn_lit = (esc(a.dsn))
    table.insert(parts, string.format("ATTACH IF NOT EXISTS '%s' AS %s;", dsn_lit, a.alias))
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

--- Name DuckDB gives the main catalog: the file's basename without its
--- extension ("softrear" for /data/softrear.duckdb), or "memory" for the
--- in-memory instance. Every catalog query that has to name the main database
--- in a string literal goes through here -- the path patterns alone never
--- yield "memory", because ":memory:" has no dot-extension and falls through
--- to the basename branch, which returns ":memory:" itself and matches nothing.
local function main_catalog_name(db_path)
  if db_path == ":memory:" then return "memory" end
  return db_path:match("([^/]+)%.[^.]+$") or db_path:match("([^/]+)$") or "memory"
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

--- argv prefix for one duckdb invocation: the executable, the caller's output
--- flags, an optional -readonly, and the database path. Callers append their
--- own "-c <sql>".
---
--- `db` may be a duckdb: URL or an already-extracted path, so the three spawn
--- sites (which hold a path) and the tests (which hold a URL) share one
--- builder. A path never starts with "duckdb:".
---
--- -readonly is applied only to a file-backed database that already exists,
--- and both halves of that condition are load-bearing rather than defensive:
---   * "duckdb -readonly" on :memory: aborts with "Cannot launch in-memory
---     database in read-only mode!", and :memory: is both the default starter
---     connection and the engine behind file-as-table;
---   * on a not-yet-existing file it aborts with "Cannot open database ... in
---     read-only mode: database does not exist" rather than creating it.
--- @param db string  a duckdb: URL or a database path
--- @param opts table|nil  { readonly = boolean }
--- @param flags string[]|nil  output flags for this call site
local function duckdb_args(db, opts, flags)
  local db_path = (type(db) == "string" and db:match("^duckdb:")) and extract_path(db) or db
  local args = { "duckdb" }
  for _, f in ipairs(flags or {}) do
    args[#args + 1] = f
  end
  local file_backed = db_path and db_path ~= ":memory:"
  if opts and opts.readonly and file_backed and vim.fn.filereadable(db_path) == 1 then
    args[#args + 1] = "-readonly"
  end
  if file_backed then
    args[#args + 1] = db_path
  end
  return args
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

  local args = duckdb_args(db_path, adapters.session_opts(), { "-csv", "-header" })
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

  -- The ATTACH prefix carried the attachment DSNs into this process; a failing
  -- attachment gets them quoted back. Masked here rather than at each of the
  -- ~15 places that return this stderr onwards.
  return stdout, redact_query_error(stderr, url), code
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
  local args = duckdb_args(db_path, adapters.session_opts(), { "-csv", "-header" })
  args[#args + 1] = "-c"
  args[#args + 1] = effective_sql
  vim.system(args, { text = true, timeout = timeout_ms or 8000 }, function(out)
    vim.schedule(function()
      -- Same reason as in duckdb(): the ATTACH prefix is in this SQL.
      callback(out.stdout or "", redact_query_error(out.stderr or "", url), out.code)
    end)
  end)
end

--- Run DML without CSV mode (to get change count output).
local function duckdb_exec(db_path, sql_str, timeout_ms, url)
  local effective_sql = sql_str
  if url then
    effective_sql = build_attach_prefix(url) .. effective_sql
  end

  local args = duckdb_args(db_path, adapters.session_opts())
  args[#args + 1] = "-c"
  args[#args + 1] = effective_sql

  -- Same reason as in duckdb(): the ATTACH prefix is in this SQL.
  local stdout, stderr, code = adapters.run_cmd(args, timeout_ms or DEFAULT_TIMEOUT)
  return stdout, redact_query_error(stderr, url), code
end

--- Statement kinds a subquery can hold. Everything else -- DESCRIBE (db.describe_file
--- and schema.lua's file-column probe both send one through M.query), SET, PRAGMA,
--- INSTALL -- runs unwrapped.
local WRAPPABLE_HEAD = {
  SELECT = true, WITH = true, FROM = true, VALUES = true, TABLE = true,
}

--- Strip leading whitespace and SQL comments so the first keyword is reachable.
local function strip_leading_noise(s)
  while true do
    local t = (s:gsub("^%s+", ""))
    if t:sub(1, 2) == "--" then
      t = (t:gsub("^%-%-[^\n]*\n?", ""))
    elseif t:sub(1, 2) == "/*" then
      local close = t:find("*/", 3, true)
      if not close then return t end
      t = t:sub(close + 2)
    end
    if t == s then return s end
    s = t
  end
end

--- In CSV mode DuckDB serialises STRUCT/LIST/MAP/UNION/ARRAY with its own literal
--- syntax -- single-quoted keys and *unquoted* string values: {'k': v}, and MAPs as
--- {a=1}. That is not JSON, and it cannot be recovered by parsing, because an
--- unquoted string may itself contain , { } ' -- so the answer has to come from
--- DuckDB. This rewrites the statement to route every nested column through
--- to_json(), which is what makes gK's tree, gB's pretty-printer and JSON export
--- see a real document instead of an unparsable literal.
---
--- COLUMNS('(.*)') AS "\1" expands positionally over the subquery's columns and
--- restores each original name, so no DESCRIBE round-trip is needed to learn the
--- types: typeof() picks the nested ones out per column. Positional expansion also
--- means duplicate column names cannot become an ambiguous reference.
--- The ELSE branch casts to VARCHAR only because both CASE arms must share a type;
--- CSV output is text either way and the rendering is byte-identical -- verified
--- across DOUBLE/REAL/DECIMAL/TIMESTAMP/TIMESTAMPTZ/TIME/DATE/INTERVAL/BLOB/
--- HUGEINT/inf/nan/NULL/embedded-comma-and-newline VARCHAR on duckdb 1.5.5, and
--- the whole rewrite also runs on 1.0.0 and 0.10.2.
--- Returns nil when the statement is not a wrappable query, in which case the
--- caller runs it unchanged.
local NESTED_JSON_TEMPLATE = [[
SELECT CASE WHEN regexp_matches(typeof(COLUMNS('(.*)')), '^(STRUCT|MAP|UNION)\(|\]$')
            THEN to_json(COLUMNS('(.*)'))::VARCHAR
            ELSE COLUMNS('(.*)')::VARCHAR
       END AS "\1"
FROM (
%s
) AS _grip_json]]

local function nested_json_sql(sql_str)
  if type(sql_str) ~= "string" then return nil end
  -- A trailing semicolon would land inside the subquery parens and fail to parse.
  -- Only trailing ones are touched: a ; inside a string literal is data.
  local body = (sql_str:gsub("[%s;]+$", ""))
  if body == "" then return nil end
  local head = strip_leading_noise(body):match("^(%a+)")
  if not head or not WRAPPABLE_HEAD[head:upper()] then return nil end
  return string.format(NESTED_JSON_TEMPLATE, body)
end

function M.query(sql_str, url)
  if vim.fn.executable("duckdb") == 0 then
    return nil, "duckdb not found. Install duckdb."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid DuckDB URL: " .. url end

  local wrapped = nested_json_sql(sql_str)
  local stdout, stderr, code
  if wrapped then
    stdout, stderr, code = duckdb(db_path, wrapped, nil, url)
  end
  -- The rewrite is an enhancement, never a new failure mode: a DuckDB too old for
  -- COLUMNS(...) AS "\1", or a statement the subquery cannot hold after all, falls
  -- back to the original query -- and to its own error message, so a genuinely
  -- broken user query still reports what is wrong with it, not with the wrapper.
  if not wrapped or code ~= 0 then
    stdout, stderr, code = duckdb(db_path, sql_str, nil, url)
  end
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
    -- No schema_name filter: schema is dropped by list_tables (same reason as get_column_info).
    sql_str = string.format([[
      SELECT UNNEST(constraint_column_names) AS column_name
      FROM duckdb_constraints()
      WHERE database_name = '%s'
        AND table_name = '%s'
        AND constraint_type = 'PRIMARY KEY'
    ]], esc(catalog), esc(tbl))
  else
    -- Main DB: use duckdb_constraints() with a string-literal database_name filter
    -- (same reason as get_column_info — information_schema fails with attachments).
    local main_catalog = main_catalog_name(db_path)
    sql_str = string.format([[
      SELECT UNNEST(constraint_column_names) AS column_name
      FROM duckdb_constraints()
      WHERE database_name = '%s'
        AND schema_name = '%s'
        AND table_name = '%s'
        AND constraint_type = 'PRIMARY KEY'
    ]], esc(main_catalog), esc(schema), esc(tbl))
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
    -- (SQLite, PostgreSQL, etc.). Do NOT filter by schema_name: list_tables drops
    -- the schema from attached catalog table names (returns "alias.table", not
    -- "alias.schema.table"), so the schema is unknown here. Filtering by
    -- database_name + table_name is correct because table names are unique within
    -- each attached catalog for practical use.
    info_sql = string.format([[
      SELECT
        column_name,
        data_type,
        '' AS is_nullable,
        COALESCE(column_default, '') AS column_default,
        '' AS constraints
      FROM duckdb_columns()
      WHERE database_name = '%s'
        AND table_name = '%s'
      ORDER BY schema_name, column_index
    ]], esc(catalog), esc(tbl))
  else
    -- Main DB: use duckdb_columns() with a string-literal database_name filter.
    -- information_schema.columns fails when attachments are present (DuckDB enumerates
    -- all catalogs including the SQLite one, which doesn't support duckdb_columns()).
    -- duckdb_columns() with WHERE database_name = '...' is immune to this.
    -- Catalog names from tempname-style paths may start with digits (invalid SQL identifiers),
    -- so string literals are required here rather than catalog-qualified syntax.
    local main_catalog = main_catalog_name(db_path)
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
    ]], esc(main_catalog), esc(schema), esc(tbl))
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
  ]], esc(schema), esc(tbl))

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

--- Reverse FK lookup: which tables reference table_name?
--- Single information_schema query (no per-table scan).
--- Returns { {table, column, ref_column, composite?}, ... }, err.
function M.get_referencing_foreign_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid DuckDB URL: " .. url end

  local catalog, schema, tbl = split_catalog_schema_table(url, table_name)

  if catalog then
    -- Attached catalogs: no cross-catalog FK introspection (same as forward FKs).
    return {}, nil
  end

  local fk_sql = string.format([[
    SELECT
      kcu.table_schema AS child_schema,
      kcu.table_name AS child_table,
      kcu.column_name AS fk_column,
      kcu2.column_name AS ref_column,
      rc.constraint_name
    FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage kcu
      ON rc.constraint_schema = kcu.constraint_schema
      AND rc.constraint_name = kcu.constraint_name
    JOIN information_schema.key_column_usage kcu2
      ON rc.unique_constraint_schema = kcu2.constraint_schema
      AND rc.unique_constraint_name = kcu2.constraint_name
      AND kcu.ordinal_position = kcu2.ordinal_position
    WHERE kcu2.table_schema = '%s'
      AND kcu2.table_name = '%s'
    ORDER BY kcu.table_schema, kcu.table_name, rc.constraint_name, kcu.ordinal_position
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = duckdb(db_path, fk_sql, nil, url)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query referencing foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  local entries = {}
  for _, row in ipairs(parsed.rows) do
    local child_schema = row[1] or "main"
    local child_tbl    = row[2] or ""
    local full_name = (child_schema == "main") and child_tbl
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
    local main_catalog = main_catalog_name(db_path)
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
  local db_filter = catalog and string.format("di.database_name = '%s' AND ", esc(catalog)) or ""

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
  ]], is_prefix, is_prefix, db_filter, esc(schema), esc(tbl))

  local stdout, _, code = duckdb(db_path, idx_sql, nil, url)
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
  local db_filter = catalog and string.format("database_name = '%s' AND ", esc(catalog)) or ""

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
  ]], db_filter, esc(schema), esc(tbl))

  local stdout, _, code = duckdb(db_path, sql_str, nil, url)
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
  local db_filter = catalog and string.format("database_name = '%s' AND ", esc(catalog)) or ""

  local stats_sql = string.format([[
    SELECT
      estimated_size,
      0 AS size_bytes
    FROM duckdb_tables()
    WHERE %sschema_name = '%s' AND table_name = '%s'
  ]], db_filter, esc(schema), esc(tbl))

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

--- Split "user:pass@host:port/dbname" into its pieces, using the shared
--- last-"@" authority rule from sql_util.
---
--- Emphatically NOT a `([^:@]+):?([^@]*)@([^:/]+)` pattern, which is what this
--- used to be: that splits on the FIRST "@", so a perfectly legal password
--- containing "@" ("P@ssw0rd") came out as password=P with the rest of the
--- password stuffed into host=. Besides producing a DSN that cannot connect,
--- it defeated redact_attach_error downstream -- the mask dutifully masked
--- "P" and DuckDB echoed the remaining seven characters to the screen.
--- @param rest string  everything after "scheme://"
--- @return string|nil user
--- @return string password  "" when absent
--- @return string host
--- @return string port  "" when absent
--- @return string dbname  "" when absent
local function split_url_rest(rest)
  local authority = rest:match("^([^/]*)") or ""
  local dbname = rest:match("^[^/]*/(.*)") or ""
  local user, password, hostport = sql_util.split_authority(authority)
  local host, port = hostport:match("^([^:]*):?(%d*)$")
  if not host or host == "" then return nil end
  return user, password or "", host, port or "", dbname
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
    local pg_user, pg_pass, pg_host, pg_port, pg_db = split_url_rest(pg_rest)
    if pg_host then
      -- With credentials: user[:pass]@host[:port]/db
      if pg_user then
        local parts = { "postgres:dbname=" .. (pg_db ~= "" and pg_db or pg_user) }
        table.insert(parts, "user=" .. pg_user)
        if pg_pass ~= "" then table.insert(parts, "password=" .. pg_pass) end
        table.insert(parts, "host=" .. pg_host)
        if pg_port ~= "" then table.insert(parts, "port=" .. pg_port) end
        return table.concat(parts, " ")
      end
      -- Without credentials: host:port/db
      local parts = { "postgres:dbname=" .. (pg_db ~= "" and pg_db or "postgres") }
      table.insert(parts, "host=" .. pg_host)
      if pg_port ~= "" then table.insert(parts, "port=" .. pg_port) end
      return table.concat(parts, " ")
    end
  end

  -- MySQL URL -> mysql_scanner DSN
  local my_rest = url:match("^mysql://(.+)")
  if my_rest then
    local my_user, my_pass, my_host, my_port, my_db = split_url_rest(my_rest)
    if my_user then
      local parts = { "mysql:host=" .. my_host }
      table.insert(parts, "user=" .. my_user)
      if my_pass ~= "" then table.insert(parts, "password=" .. my_pass) end
      if my_db ~= "" then table.insert(parts, "database=" .. my_db) end
      if my_port ~= "" then table.insert(parts, "port=" .. my_port) end
      return table.concat(parts, " ")
    end
  end

  -- Fallback: return as-is
  return url
end

--- Store an attachment without validation (used by tests and load_attachments).
--- `template` is the still-templated form of the DSN, when the caller
--- resolved a "${VAR}" placeholder to build `dsn`. It is carried purely so
--- connections.save_attachments() can write the placeholder back to disk
--- instead of the expanded, password-bearing DSN; nothing here reads it.
local function store_attachment(url, dsn, alias, template)
  dsn = resolve_dsn_path(dsn)
  local ext = detect_extension(dsn)
  _attachments[url] = _attachments[url] or {}
  for _, a in ipairs(_attachments[url]) do
    if a.alias == alias then
      a.dsn = dsn
      a.extension = ext
      a.template = template
      _catalog_cache[url] = nil  -- attachment list changed; re-query on next use
      return
    end
  end
  table.insert(_attachments[url], { dsn = dsn, alias = alias, extension = ext, template = template })
  _catalog_cache[url] = nil  -- attachment list changed; re-query on next use
end


--- URL schemes a DuckDB scanner can be pointed at. url_to_dsn() rewrites the
--- postgres/mysql URL forms into scanner DSNs; sqlite/duckdb/motherduck URLs
--- it hands through because ATTACH takes those as-is.
local ATTACHABLE_SCHEMES = {
  postgres = true, postgresql = true, mysql = true,
  sqlite = true, duckdb = true, md = true, motherduck = true,
}

--- Reject a DSN whose scheme has no DuckDB scanner behind it, before it ever
--- reaches the CLI. Returns an error string, or nil when the DSN is fine.
---
--- DuckDB does not fail such an ATTACH with "unknown scheme": it falls
--- through to its file reader and reports `Cannot open file
--- "<cwd>/sqlserver:/sa:hunter2@host/db"` -- an error that says nothing
--- useful and quotes the credentials back. The picker offers `a:attach` on
--- every non-DuckDB connection (SQL Server included) and :GripAttach takes
--- whatever is typed, so this is two keystrokes away; catching it here keeps
--- both paths honest. The message names only the scheme -- never the DSN.
--- @param dsn string
--- @return string|nil err
local function unsupported_attach_scheme(dsn)
  local scheme = dsn:match("^(%a[%w%+%.%-]*)://")
  if not scheme or ATTACHABLE_SCHEMES[scheme:lower()] then return nil end
  return string.format(
    "DuckDB has no scanner for %s:// -- it cannot ATTACH that database. "
    .. "Attachable: postgres, mysql, sqlite, motherduck.", scheme)
end

--- Attach an external database to a DuckDB session.
--- Validates the connection before storing. Returns nil on success, error string on failure.
--- The attachment is prepended to every query via build_attach_prefix().
--- `url` and `dsn` must both already be expanded (callers of this function
--- bypass db.resolve()); `template` is the pre-expansion DSN, kept only so
--- the placeholder is what gets persisted. See store_attachment().
function M.attach(url, dsn, alias, template)
  dsn = resolve_dsn_path(dsn)
  local db_path = extract_path(url)
  if not db_path then return "Invalid DuckDB URL" end
  local scheme_err = unsupported_attach_scheme(dsn)
  if scheme_err then return scheme_err end

  -- Validate: try the ATTACH before storing (a broken attachment kills all queries)
  local ext = detect_extension(dsn)
  local test_sql = ""
  if ext then
    test_sql = string.format("INSTALL %s; LOAD %s;\n", ext, ext)
  end
  test_sql = test_sql .. string.format("ATTACH IF NOT EXISTS '%s' AS %s;\n", esc(dsn), alias)
  test_sql = test_sql .. "SELECT 42;"

  -- Validate in-memory: avoids acquiring a write lock on the main db file.
  -- If we opened db_path here, we'd race with list_tables / get_schema_batch_async
  -- (both also open the same file), causing "Failed to lock file" on connection switch.
  local args = { "duckdb", "-c", test_sql }

  local _, stderr_attach, code_attach = adapters.run_cmd(args, 10000)
  if code_attach ~= 0 then
    -- The DSN is in the SQL the CLI just rejected, so its stderr can quote
    -- the credentials straight back at us. Never return it raw.
    local msg = redact_attach_error(stderr_attach:gsub("%s+$", ""), dsn)
    return msg ~= "" and msg or "Failed to attach database"
  end

  store_attachment(url, dsn, alias, template)
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
--- Each entry is { dsn, alias, template? }; connections.switch() has already
--- resolved any "${VAR}" in dsn and put the original in template.
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
    local err = M.attach(url, dsn, a.alias, a.template)
    if err then
      vim.notify(string.format("Skipped attachment '%s': %s", a.alias, err), vim.log.levels.WARN)
    end
  end
end

--- Build the schema batch SQL for get_schema_batch / get_schema_batch_async.
--- Always the same 8-column shape (rtype, database_name, schema_name, table_name,
--- column_name, data_type, is_nullable, column_index) sourced from duckdb_columns() /
--- duckdb_views() -- the exact tables get_column_info itself reads, so batch and
--- per-table fallback can never disagree on data_type/is_nullable formatting again.
--- 'col' rows = real columns. duckdb_columns() covers views too, as long as the
--- view lives in a DuckDB catalog -- verified on the CLI (v1.0.0 and v1.5.5):
--- a `CREATE VIEW v AS SELECT id, name, id*2 AS doubled` yields three 'col' rows
--- for v, the same three information_schema.columns used to return.
--- 'tbl' rows = view names, registered with column_index 0 so they sort first.
--- They are the only source for views in *attached non-DuckDB* catalogs, which
--- neither duckdb_columns() nor information_schema.columns knows the columns of
--- (also verified on the CLI, with a SQLite attachment); those views stay
--- name-only, exactly as before the two branches were unified.
--- Without attachments the scan is restricted to the main catalog (matches
--- get_column_info's main-catalog behavior exactly); with attachments it is left
--- unrestricted so duckdb_columns()/duckdb_views() also pick up attached catalogs.
--- column_index drives ORDER BY so a table's columns arrive in their real, stable
--- order -- UNION ALL alone gives no ordering guarantee within a group.
local function _make_schema_batch_sql(has_attachments, main_catalog)
  local catalog_filter = ""
  if not has_attachments then
    catalog_filter = string.format(" AND database_name = '%s'", esc(main_catalog))
  end
  return string.format([[
    SELECT 'col' AS rtype, database_name, schema_name, table_name, column_name, data_type,
           CASE WHEN is_nullable THEN 'YES' ELSE 'NO' END AS is_nullable,
           column_index
    FROM duckdb_columns()
    WHERE internal = false%s
    UNION ALL
    SELECT 'tbl' AS rtype, database_name, schema_name, view_name, '', '', '', 0
    FROM duckdb_views()
    WHERE internal = false%s
    ORDER BY 2, 3, 4, 8
  ]], catalog_filter, catalog_filter)
end

--- Parse CSV rows from _make_schema_batch_sql into the schema cache format.
--- Returns { [full_table_name] = [{column_name, data_type, is_nullable}] } or nil.
local function _parse_schema_batch_rows(parsed, main_catalog)
  if not parsed then return nil end
  local tables = {}
  -- 8-column rows: rtype, database_name, schema_name, table_name, col_name, data_type,
  -- is_nullable, column_index. ORDER BY in _make_schema_batch_sql guarantees rows for
  -- the same table arrive in column_index order, so table.insert below preserves it.
  for _, row in ipairs(parsed.rows) do
    local rtype       = row[1] or ""
    local catalog     = row[2] or main_catalog
    local schema_name = row[3] or "main"
    local tname       = row[4] or ""
    local full_name
    if catalog == main_catalog then
      full_name = (schema_name == "main") and tname or (schema_name .. "." .. tname)
    else
      -- Attached catalog: prefix with catalog alias (matches list_tables() output)
      full_name = catalog .. "." .. tname
    end
    if rtype == "col" then
      -- Column row from duckdb_columns() — covers both main catalog and attached catalogs.
      local col_name  = row[5] or ""
      local data_type = row[6] or ""
      -- Nullability for attached catalogs mirrors get_column_info's attached-catalog
      -- branch, which leaves it blank rather than trust duckdb_columns() there.
      local is_nullable = (catalog == main_catalog) and (row[7] or "") or ""
      tables[full_name] = tables[full_name] or {}
      table.insert(tables[full_name], { column_name = col_name, data_type = data_type, is_nullable = is_nullable })
    else
      -- View row. Registers the name without touching an existing entry: views in
      -- DuckDB catalogs already got their columns from duckdb_columns(), and this
      -- row sorts first (column_index 0), so it must never replace them. Views in
      -- attached non-DuckDB catalogs have no column source at all and stay empty.
      tables[full_name] = tables[full_name] or {}
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
  local main_catalog = main_catalog_name(db_path)
  local sql_str = _make_schema_batch_sql(has_attachments, main_catalog)

  local stdout, _, code = duckdb(db_path, sql_str, nil, url)
  if code ~= 0 then return nil end

  return _parse_schema_batch_rows(db_util.parse_csv(stdout), main_catalog)
end

--- Async variant: fetches schema batch without blocking. Calls callback(tables) when done.
--- Used for pre-warming the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  local db_path = extract_path(url)
  -- Deliver via vim.schedule even on this guard path: duckdb_async's own
  -- callback always arrives via vim.schedule, and a caller must not be able
  -- to tell a bad URL from a spawn failure by timing alone.
  if not db_path then vim.schedule(function() callback(nil) end); return end

  local has_attachments = _attachments[url] and #_attachments[url] > 0
  local main_catalog = main_catalog_name(db_path)
  local sql_str = _make_schema_batch_sql(has_attachments, main_catalog)

  duckdb_async(db_path, sql_str, 8000, url, function(stdout, _, code)
    if code ~= 0 then callback(nil); return end
    callback(_parse_schema_batch_rows(db_util.parse_csv(stdout), main_catalog))
  end)
end

-- Exposed for testing
--- Ping: memory instance is always reachable; file DBs require the file to be readable.
function M.ping(url)
  if vim.fn.executable("duckdb") == 0 then return false end
  if url == "duckdb::memory:" then return true end
  local path = extract_path(url)
  if not path then return false end
  return vim.fn.filereadable(path) == 1
end

M._extract_path = extract_path
M._args = duckdb_args
M._build_attach_prefix = build_attach_prefix
M._detect_extension = detect_extension
M._attach_unchecked = store_attachment
M._redact_attach_error = redact_attach_error
M._redact_query_error = redact_query_error
M._dsn_secret_keys = DSN_SECRET_KEYS
M._unsupported_attach_scheme = unsupported_attach_scheme
M._make_schema_batch_sql = _make_schema_batch_sql
M._main_catalog_name = main_catalog_name
M._nested_json_sql = nested_json_sql

return M
