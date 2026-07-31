-- db.lua: database facade.
-- Delegates to adapters based on URL scheme.
-- All functions return (result, err). Never throw.

local adapters = require("dadbod-grip.adapters")
local secrets = require("dadbod-grip.secrets")
local esc = require("dadbod-grip.sql").escape_literal

local M = {}

-- ── shared helpers (used by adapters via require("dadbod-grip.db")) ───────

--- Retrieve the connection URL from buffer-local or global dadbod var.
function M.get_url(url)
  if url and url ~= "" then return url end
  local buf_url = vim.b.db
  if type(buf_url) == "string" and buf_url ~= "" then return buf_url end
  local global_url = vim.g.db
  if type(global_url) == "string" and global_url ~= "" then return global_url end
  return nil, "No database connection. Use :GripConnect or set vim.g.db."
end

--- The connectable form of a URL, for callers that need its *scheme* rather
--- than a connection: adapters.kind() / display_name() dispatch on the
--- scheme, and a whole-URL template ("${DATABASE_URL}") has none to dispatch
--- on. Getting nil back there is not cosmetic -- it silently drops CASCADE
--- from generated DDL, discards FK dependents, degrades Query Doctor, and
--- feeds the wrong dialect to the LLM.
---
--- Best-effort by design: an unresolvable template comes back unchanged, so
--- those callers degrade to exactly what they did before this feature instead
--- of erroring. Anything that actually opens a connection must go through the
--- db.* API, where resolve() surfaces the expansion error.
--- @param url string|nil
--- @return string|nil
function M.resolved_url(url)
  if type(url) ~= "string" or not secrets.has_template(url) then return url end
  return (require("dadbod-grip.connections").expand_url(url)) or url
end

--- Group flat referencing-FK rows into one entry per constraint.
--- entries: { {table, column, ref_column, key}, ... } where key identifies the
--- constraint (e.g. child_table + constraint_name). Rows sharing a key are a
--- composite FK: collapsed to one entry with comma-joined columns and
--- composite = true. Shared by pg/mysql/duckdb reverse-FK adapters.
function M.group_referencing_fks(entries)
  local refs, index = {}, {}
  for _, e in ipairs(entries) do
    local key = e.table .. "\0" .. (e.key or "")
    local entry = index[key]
    if entry then
      -- Composite FK: kcu×ccu joins can produce duplicate column pairs; dedupe.
      if not entry.composite or not entry.column:find(e.column, 1, true) then
        entry.column = entry.column .. "," .. e.column
        entry.ref_column = entry.ref_column .. "," .. e.ref_column
      end
      entry.composite = true
    else
      entry = { table = e.table, column = e.column, ref_column = e.ref_column }
      index[key] = entry
      table.insert(refs, entry)
    end
  end
  return refs
end

--- Parse CSV output into rows + columns.
--- Handles multiline quoted fields (RFC 4180).
--- Shared by all adapters that use CSV CLI output.
function M.parse_csv(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  local DQUOTE, COMMA, LF, CR = 34, 44, 10, 13

  -- Parse entire raw string respecting quoted fields that span newlines.
  local all_rows = {}
  local fields = {}
  local i = 1
  local len = #raw

  while i <= len do
    local b = raw:byte(i)

    if b == DQUOTE then
      -- Quoted field: may contain newlines, commas, escaped quotes. Scan
      -- forward to the next quote and collect chunks in a table instead of
      -- concatenating byte-by-byte (that was O(n^2) on large quoted blobs).
      i = i + 1
      local start = i
      local parts = {}
      while true do
        local qpos = raw:find('"', i, true)
        if not qpos then
          -- Unterminated quote: the rest of the input is the field.
          parts[#parts + 1] = raw:sub(start, len)
          i = len + 1
          break
        elseif raw:byte(qpos + 1) == DQUOTE then
          -- Escaped quote (""): keep one literal quote, skip both.
          parts[#parts + 1] = raw:sub(start, qpos)
          i = qpos + 2
          start = i
        else
          -- Closing quote.
          parts[#parts + 1] = raw:sub(start, qpos - 1)
          i = qpos + 1
          break
        end
      end
      table.insert(fields, table.concat(parts))
      -- After closing quote: expect comma, newline, or end
      if i <= len then
        b = raw:byte(i)
        if b == COMMA then
          i = i + 1
        elseif b == LF or b == CR then
          if b == CR and raw:byte(i + 1) == LF then i = i + 1 end
          i = i + 1
          table.insert(all_rows, fields)
          fields = {}
        end
      end
    elseif b == COMMA then
      table.insert(fields, "")
      i = i + 1
    elseif b == LF or b == CR then
      if b == CR and raw:byte(i + 1) == LF then i = i + 1 end
      i = i + 1
      table.insert(all_rows, fields)
      fields = {}
    else
      -- Unquoted field
      local start = i
      while i <= len do
        local ub = raw:byte(i)
        if ub == COMMA or ub == LF or ub == CR then break end
        i = i + 1
      end
      table.insert(fields, raw:sub(start, i - 1))
      if i <= len then
        b = raw:byte(i)
        if b == COMMA then
          i = i + 1
        elseif b == LF or b == CR then
          if b == CR and raw:byte(i + 1) == LF then i = i + 1 end
          i = i + 1
          table.insert(all_rows, fields)
          fields = {}
        end
      end
    end
  end
  -- Flush last row if non-empty
  if #fields > 0 then
    table.insert(all_rows, fields)
  end

  -- Filter out empty rows and psql "(N rows)" footer
  local filtered = {}
  for _, row in ipairs(all_rows) do
    if not (#row == 1 and row[1]:match("^%(%d+ rows?%)$")) then
      if not (#row == 1 and row[1] == "") then
        table.insert(filtered, row)
      end
    end
  end

  if #filtered == 0 then return { columns = {}, rows = {} } end

  local columns = filtered[1]
  local rows = {}
  for ri = 2, #filtered do
    local row = filtered[ri]
    while #row < #columns do table.insert(row, "") end
    table.insert(rows, row)
  end

  return { columns = columns, rows = rows }
end

--- Parse TSV output from mysql --batch into rows + columns.
--- Neither the MySQL nor the MariaDB CLI has a --csv flag, hence --batch:
--- tab-separated output with backslash escaping for tabs, newlines and NULs.
--- NULL: mysql 8.4 --batch prints the four-byte literal "NULL" (verified live),
--- which is why a real NULL is indistinguishable here from the string 'NULL'.
--- The \N form comes from INTO OUTFILE / mysqldump --tab, and possibly from
--- other/older clients -- unverified, so the branch below stays as a cheap
--- safety net rather than being the documented behaviour.
function M.parse_batch(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  -- Unescape a single field value from --batch output
  local function unescape(field)
    if field == "\\N" then return "" end
    return (field:gsub("\\(.)", function(ch)
      if ch == "t" then return "\t" end
      if ch == "n" then return "\n" end
      if ch == "\\" then return "\\" end
      if ch == "0" then return "\0" end
      return ch
    end))
  end

  local all_rows = {}
  for line in raw:gmatch("[^\r\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
      fields[#fields + 1] = unescape(field)
    end
    if #fields > 0 then
      all_rows[#all_rows + 1] = fields
    end
  end

  if #all_rows == 0 then return { columns = {}, rows = {} } end

  local columns = all_rows[1]
  local rows = {}
  for ri = 2, #all_rows do
    local row = all_rows[ri]
    while #row < #columns do row[#row + 1] = "" end
    rows[#rows + 1] = row
  end

  return { columns = columns, rows = rows }
end

-- ── resolve adapter from URL ──────────────────────────────────────────────

--- Pick the adapter for a URL and turn that URL into a connectable one.
---
--- Every public db.* function funnels through here, which makes this the one
--- and only place where a "${VAR}" template becomes a real URL carrying a
--- real password. vim.g.db, vim.b.db, .grip/connections.json and the query
--- history all keep the template, so no write path anywhere in the plugin is
--- ever handed a secret it could spill -- not because each of them scrubs,
--- but because none of them ever holds one. Keep it that way: expanding
--- further out (in M.get_url, in connections.switch, in a caller) puts the
--- password back into everything downstream of it.
---
--- The has_template() check comes first so a literal URL -- the overwhelming
--- majority -- does not even load connections.lua, let alone read a file.
--- @return table|nil adapter
--- @return string|nil conn  the expanded URL to hand the adapter
--- @return string|nil err
local function resolve(url)
  local conn, conn_err = M.get_url(url)
  if not conn then return nil, nil, conn_err end
  if secrets.has_template(conn) then
    -- Lazy require: connections.lua pulls in the UI stack, and db.lua is
    -- loaded by every adapter.
    local expanded, exp_err = require("dadbod-grip.connections").expand_url(conn)
    if not expanded then return nil, nil, exp_err end
    conn = expanded
  end
  local adapter, adapt_err = adapters.resolve(conn)
  if not adapter then return nil, nil, adapt_err end
  return adapter, conn, nil
end

--- Publish `url`'s read/write mode to the adapter layer, run the adapter
--- call, and unpublish it again.
---
--- This is the only correct place for that decision. The mode lives on the
--- connection *entry*, which is keyed by the template URL; resolve() above
--- hands the adapter the *expanded* one, from which the entry can no longer
--- be found. Reading vim.g.db down in the adapter instead is what this
--- replaces, and it was wrong in both directions: a query against an
--- explicitly passed ro URL spawned without the read-only flag whenever the
--- ambient connection was a different one, and -- worse -- an unrelated rw
--- connection was spawned read-only whenever the ambient one happened to be
--- ro. Both are ordinary sequences: :GripConnect with a grid or sidebar still
--- open, whose closures captured the URL they were opened with.
---
--- `url` is passed through exactly as the caller gave it, nil included:
--- current_mode falls back to vim.b.db/vim.g.db through the same get_url()
--- resolve() uses, so the two always agree on which connection this is.
---
--- Restores the previous value rather than clearing to nil, and does so on the
--- error path too. Both halves are load-bearing:
---
---   * Nesting is real. run_cmd blocks in vim.wait, which pumps the main loop,
---     so a scheduled db.* call (init.lua's column-info auto-fetch, view.lua's
---     on_refresh) runs *inside* an adapter call that is between two spawns.
---     Clearing to nil on the way out of the inner one left every later spawn
---     of the outer one falling back to the ambient connection -- the same
---     defect this function exists to fix, just harder to see.
---   * "Adapters return (result, err)" is a statement about their return
---     convention, not a promise that no Lua error is ever raised inside one;
---     init.lua:2329 pcalls a db_mod call for exactly that reason. Without the
---     pcall here a throw would strand the published value, and with a bare
---     save/restore it would strand the *inner* frame's value, which is worse.
---     So the restore runs either way and the error is re-raised unchanged --
---     error(err, 0) adds no position of its own, so nothing is hidden.
---
--- Two values because that is the adapters' whole contract.
local function via_adapter(url, fn, ...)
  local previous = adapters.set_call_readonly(
    require("dadbod-grip.connections").current_mode(url) == "ro")
  local ok, result, err = pcall(fn, ...)
  adapters.set_call_readonly(previous)
  if not ok then error(result, 0) end
  return result, err
end

-- ── public interface (unchanged signatures) ───────────────────────────────

function M.query(sql, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return via_adapter(url, adapter.query, sql, conn)
end

function M.get_primary_keys(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  return via_adapter(url, adapter.get_primary_keys, table_name, conn)
end

function M.get_column_info(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return via_adapter(url, adapter.get_column_info, table_name, conn)
end

function M.execute(sql, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return via_adapter(url, adapter.execute, sql, conn)
end

--- Ping a connection. Returns true on success, false on any error.
--- File-backed adapters check filereadable(); network adapters run SELECT 1 (5s timeout).
function M.ping(url)
  local adapter, conn = resolve(url)
  if not adapter then return false end
  if adapter.ping then return via_adapter(url, adapter.ping, conn) end
  return false
end

function M.get_foreign_keys(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_foreign_keys then return {}, "Adapter does not support FK lookup" end
  return via_adapter(url, adapter.get_foreign_keys, table_name, conn)
end

function M.list_tables(url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.list_tables then return nil, "Adapter does not support list_tables" end
  return via_adapter(url, adapter.list_tables, conn)
end

--- Reverse FK lookup: which tables have FKs pointing at table_name?
--- Returns { {table, column, ref_column, composite?}, ... }, err.
--- Adapters with a single-query implementation (postgres, mysql, sqlite,
--- duckdb) are preferred; otherwise falls back to scanning every table's
--- forward FKs via list_tables + get_foreign_keys (composite FKs are not
--- detectable in the fallback: entries stay per-column).
function M.get_referencing_foreign_keys(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if adapter.get_referencing_foreign_keys then
    return via_adapter(url, adapter.get_referencing_foreign_keys, table_name, conn)
  end
  if not (adapter.list_tables and adapter.get_foreign_keys) then
    return {}, "Adapter does not support FK lookup"
  end
  -- The fallback spawns the CLI once per table, so the whole scan goes inside
  -- one via_adapter rather than each call getting its own.
  return via_adapter(url, function()
    local tables, terr = adapter.list_tables(conn)
    if not tables then return {}, terr end
    local bare_target = table_name:match("([^.]+)$")
    local refs = {}
    for _, t in ipairs(tables) do
      if t.type ~= "view" then
        local fks = adapter.get_foreign_keys(t.name, conn)
        for _, fk in ipairs(fks or {}) do
          local bare_ref = (fk.ref_table or ""):match("([^.]+)$")
          if fk.ref_table == table_name or bare_ref == bare_target then
            table.insert(refs, {
              table = t.name, column = fk.column, ref_column = fk.ref_column,
            })
          end
        end
      end
    end
    return refs, nil
  end)
end

--- Fetch all table columns in a single batch query (adapter-specific optimisation).
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- nil means the adapter doesn't support batch fetch; callers fall back to per-table.
function M.get_schema_batch(url)
  local adapter, conn = resolve(url)
  if not adapter then return nil end
  if not adapter.get_schema_batch then return nil end
  return via_adapter(url, adapter.get_schema_batch, conn)
end

--- Async variant of get_schema_batch. Calls callback(tables) when done, or callback(nil) on error.
--- No-op if the adapter doesn't support async batch fetch.
function M.get_schema_batch_async(url, callback)
  local adapter, conn = resolve(url)
  if not adapter or not adapter.get_schema_batch_async then callback(nil); return end
  via_adapter(url, adapter.get_schema_batch_async, conn, callback)
end

function M.get_indexes(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_indexes then return {}, "Adapter does not support get_indexes" end
  return via_adapter(url, adapter.get_indexes, table_name, conn)
end

function M.get_table_stats(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.get_table_stats then return nil, "Adapter does not support get_table_stats" end
  return via_adapter(url, adapter.get_table_stats, table_name, conn)
end

function M.explain(sql_str, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.explain then return nil, "Adapter does not support EXPLAIN" end
  return via_adapter(url, adapter.explain, sql_str, conn)
end

function M.get_constraints(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_constraints then return {}, "Adapter does not support get_constraints" end
  return via_adapter(url, adapter.get_constraints, table_name, conn)
end

--- Returns true when the grid must not be editable: either the adapter
--- intentionally exposes read-only grids (sqlserver), or the connection is
--- saved with `"mode": "ro"`.
---
--- `url` is passed through as given -- the stored, possibly templated form --
--- because that is the key connection entries live under; see
--- connections.current_mode.
function M.is_readonly(url)
  local adapter = resolve(url)
  if adapter and adapter.readonly == true then return true end
  return require("dadbod-grip.connections").current_mode(url) == "ro"
end

--- List database routines for schema browsers.
--- Returns { {name, display, type}, ... }. Unsupported adapters return empty.
function M.list_routines(url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.list_routines then return {}, nil end
  return via_adapter(url, adapter.list_routines, conn)
end

--- Fetch a routine's source/definition text. Unsupported adapters return an error.
function M.get_routine_source(routine_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.get_routine_source then return nil, "Adapter does not support routine source" end
  return via_adapter(url, adapter.get_routine_source, routine_name, conn)
end

--- Describe the columns of a local/remote file via DuckDB DESCRIBE.
--- Returns (cols, nil) on success where cols = { {column_name, data_type} }.
--- Returns (nil, err_string) on failure.
function M.describe_file(path, url)
  local safe = esc(path)
  local sql  = string.format("DESCRIBE SELECT * FROM '%s' LIMIT 0", safe)
  local result, err = M.query(sql, url)
  if err or not result then return nil, err or "describe failed" end
  local cols = {}
  for _, row in ipairs(result.rows or {}) do
    table.insert(cols, { column_name = row[1], data_type = row[2] })
  end
  return cols, nil
end

return M
