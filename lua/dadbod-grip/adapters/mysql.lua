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

--- Build the constant mysql CLI args for a statement, query or DML alike.
--- Both MySQL and MariaDB use --batch (tab-separated output; --csv is not a
--- mysql CLI flag). --batch reports no affected-row count for DML, which is why
--- execute() asks for ROW_COUNT() explicitly.
--- Split out from mysql_query() so the blocking and non-blocking spawns run
--- byte-identical command lines.
---
local function mysql_args(parsed)
  local args = { "mysql", "--batch" }
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
  return args
end

--- Session setup and statement delivered together through stdin.
local function mysql_stdin(sql_str, opts)
  local statements = { "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';" }
  if opts and opts.readonly then
    statements[#statements + 1] = "SET SESSION TRANSACTION READ ONLY;"
  end
  statements[#statements + 1] = sql_str
  return table.concat(statements, "\n")
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
local function mysql_query(parsed, sql_str, timeout_ms, xml, guarded, hooks)
  local opts = adapters.session_opts()
  local args = mysql_args(parsed)
  if xml then args[#args + 1] = "--xml" end
  if guarded then
    args[#args + 1] = "--skip-force"; args[#args + 1] = "--skip-reconnect"
    args[#args + 1] = "--default-character-set=utf8mb4"
  end
  return adapters.run_cmd(args, timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    { stdin = mysql_stdin(sql_str, opts), env = mysql_env(parsed), raw_output = xml,
      on_start = hooks and hooks.on_start, on_complete = hooks and hooks.on_complete,
      on_spawn_error = hooks and hooks.on_spawn_error, terminate_on_interrupt = hooks ~= nil })
end

--- Run a statement without blocking; same argv, stdin and env as mysql_query.
local function mysql_query_async(parsed, sql_str, timeout_ms, callback)
  local opts = adapters.session_opts()
  adapters.run_cmd_async(mysql_args(parsed), timeout_ms or adapters.configured_timeout(DEFAULT_TIMEOUT),
    callback, { stdin = mysql_stdin(sql_str, opts), env = mysql_env(parsed) })
end

function M.query(sql_str, url)
  if vim.fn.executable("mysql") == 0 then
    return nil, "mysql not found. Install mysql-client."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  return require("dadbod-grip.mysql_read").query(sql_str, {
    args = mysql_args(parsed), env = mysql_env(parsed),
    setup = mysql_stdin("", adapters.session_opts()),
    timeout = adapters.configured_timeout(DEFAULT_TIMEOUT),
    readonly = adapters.session_opts().readonly == true,
    identity = { schema = parsed.dbname, instance = (parsed.host or "localhost") .. ":"
      .. tostring(parsed.port or "3306") .. "/" .. (parsed.user or "") },
    source_provider = require("dadbod-grip.mysql_source"),
  })
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
      COALESCE(c.COLUMN_KEY, '') AS constraints, c.EXTRA AS extra,
      COALESCE(c.CHARACTER_SET_NAME, '') AS character_set, COALESCE(c.COLLATION_NAME, '') AS collation,
      c.ORDINAL_POSITION AS ordinal_position, COALESCE(c.GENERATION_EXPRESSION, '') AS generation_expression,
      c.TABLE_SCHEMA AS source_schema, c.TABLE_NAME AS source_table
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA = '%s'
      AND c.TABLE_NAME = '%s'
    ORDER BY c.ORDINAL_POSITION
  ]], esc(schema), esc(tbl))

  local stdout, stderr, code = mysql_query(parsed, info_sql, nil, false, true)
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
      generated      = (row[6] or ""):find("VIRTUAL GENERATED", 1, true) ~= nil
        or (row[6] or ""):find("STORED GENERATED", 1, true) ~= nil,
      character_set  = row[7] or "",
      collation      = row[8] or "",
      column_type    = row[2], -- exact server spelling; data_type remains UI-normalized
      extra          = row[6],
      ordinal        = tonumber(row[9]),
      ordinal_position = tonumber(row[9]),
      visible        = row[6] and (row[6]:upper():find('INVISIBLE',1,true) == nil),
      generation_expression = row[10],
      source_schema  = row[11],
      source_table   = row[12],
      metadata_source = row[9] and row[11] and row[12] and 'source_schema' or nil,
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

--- Translate INSERT [priority] [IGNORE] [INTO] table [PARTITION (...)] DEFAULT
--- VALUES, optionally followed by ON DUPLICATE KEY UPDATE or RETURNING.
--- Keep token offsets so comments, quoting, and all text
--- outside the two keyword edits survive byte-for-byte. This is deliberately
--- not a general SQL parser: ambiguous/session-dependent input passes through
--- unchanged so the server remains responsible for SQL errors.
local function rewrite_default_values(sql_str)
  local tokens, edits = {}, {}
  local i, n = 1, #sql_str
  local word_part = "[%w_$\128-\255]"

  local function keyword(index, word)
    local token = tokens[index]
    return token and token.kind == "word" and token.text == word
  end

  local function identifier(index)
    local token = tokens[index]
    return token and (token.kind == "quoted"
      or (token.kind == "word" and token.text:match("^[%a_$\128-\255]")))
  end

  local function statement()
    -- Later statements can change quote interpretation after a mode change;
    -- mysql's DELIMITER command also changes the meaning of semicolons.
    if keyword(1, "DELIMITER") then return false end
    if keyword(1, "SET") then
      for _, token in ipairs(tokens) do
        if token.text == "SQL_MODE" then return false end
      end
    end
    if keyword(1, "INSERT") then
      local at = 2
      if keyword(at, "LOW_PRIORITY") or keyword(at, "HIGH_PRIORITY")
          or keyword(at, "DELAYED") then at = at + 1 end
      if keyword(at, "IGNORE") then at = at + 1 end
      if keyword(at, "INTO") then at = at + 1 end
      if identifier(at) then
        at = at + 1
        if tokens[at] and tokens[at].text == "." and identifier(at + 1) then at = at + 2 end
        if keyword(at, "PARTITION") and tokens[at + 1] and tokens[at + 1].text == "(" then
          local part = at + 2
          while identifier(part) do
            part = part + 1
            if tokens[part] and tokens[part].text == ")" then at = part + 1; break end
            if not tokens[part] or tokens[part].text ~= "," then break end
            part = part + 1
          end
        end
        local tail = at + 2
        local complete = #tokens == at + 1
          or (keyword(tail, "RETURNING") and tokens[tail + 1])
          or (keyword(tail, "ON") and keyword(tail + 1, "DUPLICATE")
            and keyword(tail + 2, "KEY") and keyword(tail + 3, "UPDATE") and tokens[tail + 4])
        if keyword(at, "DEFAULT") and keyword(at + 1, "VALUES") and complete then
          edits[#edits + 1] = { first = tokens[at].first, last = tokens[at].last, text = "()" }
          edits[#edits + 1] = { first = tokens[at + 1].first, last = tokens[at + 1].last, text = "VALUES ()" }
        end
      end
    end
    tokens = {}
    return true
  end

  while i <= n do
    local ch, pair = sql_str:sub(i, i), sql_str:sub(i, i + 1)
    if ch:match("%s") then
      i = i + 1
    elseif ch == "#" or (pair == "--" and sql_str:sub(i + 2, i + 2):match("[%s%c]")) then
      local newline = sql_str:find("[\r\n]", i + 1)
      -- Client/server handling of a bare CR differs; do not infer boundaries.
      if newline and sql_str:sub(newline, newline) == "\r"
          and sql_str:sub(newline + 1, newline + 1) ~= "\n" then return sql_str end
      i = newline and (newline + 1) or (n + 1)
    elseif pair == "/*" then
      -- These comments contain executable SQL, not lexical whitespace.
      local marker = sql_str:sub(i + 2, i + 3):upper()
      if marker:sub(1, 1) == "!" or marker == "M!" then return sql_str end
      local finish = sql_str:find("*/", i + 2, true)
      local nested = sql_str:find("/*", i + 2, true)
      if not finish or (nested and nested < finish) then return sql_str end
      -- mysql also honors short client commands inside optimizer hints. A
      -- delimiter/charset command invalidates this scan's boundary assumptions.
      local command = marker:sub(1, 1) == "+" and sql_str:find("\\", i + 3, true)
      if command and command < finish then return sql_str end
      i = finish + 2
    elseif ch == "'" or ch == '"' or ch == "`" then
      local first, quote, closed = i, ch, false
      i = i + 1
      while i <= n do
        ch = sql_str:sub(i, i)
        if ch == "\\" then
          local start = i
          while sql_str:sub(i, i) == "\\" do i = i + 1 end
          if (i - start) % 2 == 1 and sql_str:sub(i, i) == quote then return sql_str end
        elseif ch == quote then
          if sql_str:sub(i + 1, i + 1) == quote then i = i + 2
          else i = i + 1; closed = true; break end
        else i = i + 1 end
      end
      if not closed then return sql_str end
      tokens[#tokens + 1] = { kind = quote == "'" and "string" or "quoted",
        text = sql_str:sub(first + 1, i - 2):upper(), first = first, last = i - 1 }
    elseif ch == ";" then
      if not statement() then return sql_str end
      i = i + 1
    elseif ch:match(word_part) then
      local first = i
      repeat i = i + 1 until i > n or not sql_str:sub(i, i):match(word_part)
      tokens[#tokens + 1] = { kind = "word", text = sql_str:sub(first, i - 1):upper(), first = first, last = i - 1 }
    else
      -- mysql client commands can change delimiters/session interpretation.
      if ch == "\\" then return sql_str end
      tokens[#tokens + 1] = { kind = "other", text = ch, first = i, last = i }
      i = i + 1
    end
  end
  if not statement() or #edits == 0 then return sql_str end
  local pieces, first = {}, 1
  for _, edit in ipairs(edits) do
    pieces[#pieces + 1] = sql_str:sub(first, edit.first - 1)
    pieces[#pieces + 1] = edit.text
    first = edit.last + 1
  end
  pieces[#pieces + 1] = sql_str:sub(first)
  return table.concat(pieces)
end

function M.execute(sql_str, url)
  if vim.fn.executable("mysql") == 0 then
    return nil, "mysql not found. Install mysql-client."
  end

  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL: " .. sql_util.redact_url(url) end

  -- MySQL uses an empty column/value list for a default-row INSERT.
  sql_str = rewrite_default_values(sql_str)

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

function M.grid_write(plan, url, opts)
  local transaction = require("dadbod-grip.transaction")
  local parsed = parse_url(url)
  if not parsed then return nil, "Invalid MySQL URL" end
  local schema, tbl = split_table_name(plan.table_name, parsed.dbname)
  local output, metadata_error, metadata_code = mysql_query(parsed,
    "SELECT VERSION(), ENGINE, (SELECT COLUMN_NAME FROM information_schema.COLUMNS"
    .. " WHERE TABLE_SCHEMA=" .. sql_util.quote_value(schema) .. " AND TABLE_NAME=" .. sql_util.quote_value(tbl)
    .. " AND EXTRA LIKE '%auto_increment%' LIMIT 1) FROM information_schema.TABLES WHERE TABLE_SCHEMA="
    .. sql_util.quote_value(schema) .. " AND TABLE_NAME=" .. sql_util.quote_value(tbl), nil, true, true)
  if metadata_code ~= 0 then return nil, metadata_error end
  local metadata = require("dadbod-grip.transport").mysql_xml(output)
  local row = metadata and metadata.rows[1]
  if not row or (row[2] or ""):lower() ~= "innodb" then return nil, "Verified grid writes require InnoDB" end
  local kind = (row[1] or ""):find("MariaDB", 1, true) and "mariadb" or "mysql"
  local major, minor, patch = (row[1] or ""):match("(%d+)%.(%d+)%.(%d+)")
  local version = major and (tonumber(major) * 10000 + tonumber(minor) * 100 + tonumber(patch)) or 0
  if version < (kind == "mariadb" and 100201 or 80016) then
    return nil, "Verified grid writes require enforced CHECK constraints (MySQL8.0.16 or MariaDB10.2.1 and newer)"
  end
  local script, err = transaction.compile(plan, kind, { auto_increment = row[3], schema = schema, table_name = tbl })
  if not script then return nil, err end
  local stdout, stderr, code = transaction.submit(kind, opts, function(hooks)
    return mysql_query(parsed, script, nil, false, true, hooks)
  end)
  if code ~= 0 then return nil, stderr ~= "" and stderr or ("mysql exited with code " .. code) end
  local result, decode_err = transaction.decode(plan, stdout, kind)
  if result then result.sql = script end
  return result, decode_err
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
M._mysql_stdin = mysql_stdin
M._normalize_column_type = normalize_column_type
M._rewrite_default_values = rewrite_default_values

return M
