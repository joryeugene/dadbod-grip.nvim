-- adapters/sqlite.lua: SQLite adapter (sqlite3 CLI).
-- All functions receive a resolved, non-nil URL.
-- All functions return (result, err). Never throw.

local db_util  = require("dadbod-grip.db")
local adapters = require("dadbod-grip.adapters")
local sql_util = require("dadbod-grip.sql")
local esc      = sql_util.escape_literal

local M = {}

local DEFAULT_TIMEOUT = 10000

--- Extract file path from dadbod's sqlite: URL format.
--- "sqlite:path/to/db.db"      -> "path/to/db.db"
--- "sqlite:/absolute/path.db"  -> "/absolute/path.db"
--- "sqlite:///absolute/path"   -> "/absolute/path"
local function extract_path(url)
  local path = url:match("^sqlite:///(.+)$")
  if path then return "/" .. path end
  path = url:match("^sqlite:(.+)$")
  if not path or path == "" then return nil end
  -- Expand ~ to home directory
  if path:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or ""
    path = home .. path:sub(2)
  end
  return path
end

--- Reduce a table name to the bare name the PRAGMAs and sqlite_master expect.
--- SQLite has no schemas, so any qualifier ("main.users", an attached-database
--- prefix) is dropped rather than returned; that is why this is not
--- sql_util.split_table_name, which unquotes each part and hands the schema
--- back. Kept deliberately as-is: strip the outer double quotes off the whole
--- name, then drop everything up to the first dot.
local function bare_table_name(table_name)
  local tbl = table_name:gsub('^"', ''):gsub('"$', '')
  return tbl:match("^[^.]+%.(.+)$") or tbl
end

--- argv for one sqlite3 invocation. Split out from sqlite3() so the blocking
--- and non-blocking spawns run byte-identical command lines.
---
--- -readonly is added for opts.readonly, but only when the file is already
--- there: sqlite3 creates a missing database on open, and -readonly turns
--- that into a hard "unable to open database file" instead. A connection
--- pointing at a not-yet-created file therefore behaves exactly as it does in
--- rw mode -- there is nothing to protect in a database that does not exist.
--- @param opts table|nil  { readonly = boolean }
local function sqlite3_args(db_path, sql_str, opts)
  local args = { "sqlite3", "-init", "", "-csv", "-header" }
  if opts and opts.readonly and vim.fn.filereadable(db_path) == 1 then
    args[#args + 1] = "-readonly"
  end
  args[#args + 1] = db_path
  args[#args + 1] = sql_str
  return args
end

local function sqlite3(db_path, sql_str, timeout_ms)
  return adapters.run_cmd(sqlite3_args(db_path, sql_str, adapters.session_opts()),
    timeout_ms or DEFAULT_TIMEOUT)
end

function M.query(sql_str, url)
  if vim.fn.executable("sqlite3") == 0 then
    return nil, "sqlite3 not found. Install sqlite."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local stdout, stderr, code = sqlite3(db_path, sql_str)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("sqlite3 exited with code " .. code)
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
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA table_info("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query primary keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
  -- pk > 0 means primary key; the value is position in composite key
  local pks = {}
  for _, row in ipairs(parsed.rows) do
    local pk_val = tonumber(row[6]) or 0
    if pk_val > 0 then
      table.insert(pks, { name = row[2], pos = pk_val })
    end
  end
  table.sort(pks, function(a, b) return a.pos < b.pos end)

  local result = {}
  for _, pk in ipairs(pks) do
    table.insert(result, pk.name)
  end
  return result, nil
end

function M.get_column_info(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA table_info("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return nil, stderr ~= "" and stderr or "Failed to query column info"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil, "Failed to parse column info" end

  -- PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
  local cols = {}
  for _, row in ipairs(parsed.rows) do
    local pk_val = tonumber(row[6]) or 0
    table.insert(cols, {
      column_name    = row[2] or "",
      data_type      = row[3] or "",
      is_nullable    = (row[4] == "1") and "NO" or "YES",
      column_default = row[5] or "",
      constraints    = pk_val > 0 and "PRIMARY KEY" or "",
    })
  end
  return cols, nil
end

function M.get_foreign_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  local stdout, stderr, code = sqlite3(db_path, string.format('PRAGMA foreign_key_list("%s")', tbl:gsub('"', '""')))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- PRAGMA foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match
  local fks = {}
  for _, row in ipairs(parsed.rows) do
    table.insert(fks, {
      column = row[4] or "",      -- "from" column in this table
      ref_table = row[3] or "",   -- referenced table
      ref_column = row[5] or "",  -- referenced column ("to")
    })
  end
  return fks, nil
end

--- Reverse FK lookup: which tables reference table_name?
--- Single query via the pragma_foreign_key_list table-valued function.
--- Returns { {table, column, ref_column, composite?}, ... }, err.
--- Composite FKs are collapsed to one entry with comma-joined columns.
function M.get_referencing_foreign_keys(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  -- PRAGMA foreign_key_list columns: id, seq, table, from, to, ...
  -- One row per FK column; (child, id) identifies a constraint.
  local sql_str = string.format([[
    SELECT m.name AS child_table, p.id, p."from", p."to"
    FROM sqlite_master m, pragma_foreign_key_list(m.name) p
    WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%%'
      AND lower(p."table") = lower('%s')
    ORDER BY m.name, p.id, p.seq
  ]], esc(tbl))

  local stdout, stderr, code = sqlite3(db_path, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query referencing foreign keys"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- Group rows by (child_table, id): >1 row = composite FK.
  local refs, index = {}, {}
  for _, row in ipairs(parsed.rows) do
    local key = (row[1] or "") .. "\0" .. (row[2] or "")
    local entry = index[key]
    if entry then
      entry.column = entry.column .. "," .. (row[3] or "")
      entry.ref_column = entry.ref_column .. "," .. (row[4] or "")
      entry.composite = true
    else
      entry = { table = row[1] or "", column = row[3] or "", ref_column = row[4] or "" }
      index[key] = entry
      table.insert(refs, entry)
    end
  end
  return refs, nil
end

--- The one schema-batch statement, shared by get_schema_batch and
--- get_schema_batch_async so the two paths can never query different things.
local SCHEMA_BATCH_SQL = [[
    SELECT m.name AS table_name,
           p.name AS column_name,
           p.type AS data_type,
           CASE WHEN p."notnull" = 1 THEN 'NO' ELSE 'YES' END AS is_nullable
    FROM sqlite_master m, pragma_table_info(m.name) p
    WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite_%'
    ORDER BY m.name, p.cid
  ]]

--- Parse SCHEMA_BATCH_SQL's CSV into the completion cache format.
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- The single parser for both the blocking and non-blocking paths.
local function parse_schema_batch(stdout)
  local parsed = db_util.parse_csv(stdout)
  if not parsed then return nil end

  local tables = {}
  for _, row in ipairs(parsed.rows) do
    local tname     = row[1] or ""
    local col_name  = row[2] or ""
    local data_type = row[3] or ""
    local nullable  = row[4] or ""
    tables[tname] = tables[tname] or {}
    table.insert(tables[tname], { column_name = col_name, data_type = data_type, is_nullable = nullable })
  end
  return tables
end

--- Fetch all table columns in a single query (O(1) CLI spawns).
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
function M.get_schema_batch(url)
  local db_path = extract_path(url)
  if not db_path then return nil end

  local stdout, _, code = sqlite3(db_path, SCHEMA_BATCH_SQL)
  if code ~= 0 then return nil end

  return parse_schema_batch(stdout)
end

--- Async variant: same statement, same parser, non-blocking spawn.
--- Calls callback(tables), or callback(nil) on a bad URL or a failed sqlite3.
--- Used to pre-warm the completion cache on connection switch / GripAttach.
function M.get_schema_batch_async(url, callback)
  local db_path = extract_path(url)
  -- Deliver via vim.schedule even on this guard path: run_cmd_async's contract
  -- is that the callback never fires on the calling tick, and a caller must not
  -- be able to tell a bad URL from a spawn failure by that timing difference.
  if not db_path then vim.schedule(function() callback(nil) end); return end

  adapters.run_cmd_async(sqlite3_args(db_path, SCHEMA_BATCH_SQL, adapters.session_opts()),
    DEFAULT_TIMEOUT, function(stdout, _, code)
      if code ~= 0 then callback(nil); return end
      callback(parse_schema_batch(stdout))
    end)
end

function M.explain(sql_str, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local stdout, stderr, code = sqlite3(db_path, "EXPLAIN QUERY PLAN " .. sql_str)
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
  if not db_path then return nil, "Invalid SQLite URL: " .. url end
  local sql_str = [[
    SELECT name, type FROM sqlite_master
    WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
    ORDER BY type DESC, name
  ]]
  local stdout, stderr, code = sqlite3(db_path, sql_str)
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

--- List indexes with their columns in a single query (O(1) CLI spawns).
--- Single query via the pragma_index_list / pragma_index_info table-valued
--- functions, joined so each index's columns arrive in seqno order without
--- a per-index PRAGMA round trip.
function M.get_indexes(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  -- il.seq/il."unique"/il.origin: PRAGMA index_list columns.
  -- ii.seqno/ii.name: PRAGMA index_info columns, one row per index column.
  -- ORDER BY il.seq (index order) then ii.seqno (column order within the index).
  local sql_str = string.format([[
    SELECT il.name AS idx_name, il."unique", il.origin, ii.seqno, ii.name AS col_name
    FROM pragma_index_list('%s') il
    JOIN pragma_index_info(il.name) ii
    ORDER BY il.seq, ii.seqno
  ]], esc(tbl))

  local stdout, stderr, code = sqlite3(db_path, sql_str)
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query indexes"
  end

  local parsed = db_util.parse_csv(stdout)
  if not parsed then return {} end

  -- Group rows by index name, preserving first-seen (= il.seq) order.
  local indexes, index = {}, {}
  for _, row in ipairs(parsed.rows) do
    local idx_name = row[1] or ""
    local entry = index[idx_name]
    if not entry then
      local is_unique = row[2] == "1"
      local origin = row[3] or ""
      entry = {
        name = idx_name,
        type = origin == "pk" and "PRIMARY" or (is_unique and "UNIQUE" or "INDEX"),
        columns = {},
      }
      index[idx_name] = entry
      table.insert(indexes, entry)
    end
    table.insert(entry.columns, row[5] or "")
  end
  return indexes, nil
end

-- SQLite stores constraints inline in the CREATE TABLE DDL; there is no constraint catalog.
-- Return the raw DDL as a single "constraint" row so users can inspect it.
function M.get_constraints(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return {}, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  local stdout, stderr, code = sqlite3(db_path,
    string.format("SELECT sql FROM sqlite_master WHERE type='table' AND name='%s'",
      esc(tbl)))
  if code ~= 0 then
    return {}, stderr ~= "" and stderr or "Failed to query DDL"
  end

  -- Extract UNIQUE and CHECK clauses from CREATE TABLE SQL with a simple scan
  local ddl = stdout:gsub("^%s+", ""):gsub("%s+$", "")
  if ddl == "" then return {}, nil end

  local constraints = {}
  -- Match lines containing UNIQUE or CHECK (not column-level, those are simpler)
  for line in ddl:gmatch("[^\n]+") do
    local trimmed = vim.trim(line):gsub(",$", "")
    if trimmed:upper():match("^UNIQUE") or trimmed:upper():match("^CONSTRAINT.*UNIQUE")
      or trimmed:upper():match("^CHECK") or trimmed:upper():match("^CONSTRAINT.*CHECK") then
      local ctype = trimmed:upper():find("UNIQUE") and "UNIQUE" or "CHECK"
      table.insert(constraints, { name = "(inline)", type = ctype, definition = trimmed })
    end
  end

  -- Fallback: return the full DDL for manual inspection when no named constraints found
  if #constraints == 0 then
    table.insert(constraints, { name = "(see DDL)", type = "DDL", definition = ddl })
  end

  return constraints, nil
end

function M.get_table_stats(table_name, url)
  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  local tbl = bare_table_name(table_name)

  -- Row count (exact, SQLite doesn't have estimates)
  local stdout, _, code = sqlite3(db_path, string.format("SELECT COUNT(*) FROM \"%s\"", tbl:gsub('"', '""')))
  local row_count = 0
  if code == 0 then
    for line in stdout:gmatch("([^\n]+)") do
      local n = tonumber(line)
      if n then row_count = n end
    end
  end

  -- DB file size (page_count * page_size)
  local size_stdout = sqlite3(db_path, "SELECT page_count * page_size FROM pragma_page_count, pragma_page_size")
  local size_bytes = 0
  if size_stdout then
    for line in size_stdout:gmatch("([^\n]+)") do
      local n = tonumber(line)
      if n then size_bytes = n end
    end
  end

  return {
    row_estimate = row_count,
    size_bytes = size_bytes,
  }, nil
end

function M.execute(sql_str, url)
  if vim.fn.executable("sqlite3") == 0 then
    return nil, "sqlite3 not found. Install sqlite."
  end

  local db_path = extract_path(url)
  if not db_path then return nil, "Invalid SQLite URL: " .. url end

  -- Append changes() to get affected row count in a single invocation
  local wrapped = sql_str .. "; SELECT changes();"
  local stdout, stderr, code = sqlite3(db_path, wrapped)
  if code ~= 0 then
    local msg = stderr ~= "" and stderr or ("sqlite3 exited with code " .. code)
    return nil, msg
  end

  -- stdout from "SELECT changes()" with -csv -header:
  -- "changes()\nN\n"
  -- Parse last numeric line for the count.
  local n = 0
  for line in stdout:gmatch("([^\n]+)") do
    local num = tonumber(line)
    if num then n = num end
  end

  return { affected = n, message = n .. " row(s) affected" }, nil
end

--- Ping: a SQLite DB is reachable when its file is readable.
function M.ping(url)
  local path = extract_path(url)
  if not path then return false end
  return vim.fn.filereadable(path) == 1
end

-- Exposed for testing
M._extract_path = extract_path
M._sqlite3_args = sqlite3_args

return M
