-- db.lua: database facade.
-- Delegates to adapters based on URL scheme.
-- All functions return (result, err). Never throw.

local adapters = require("dadbod-grip.adapters")

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

--- Parse CSV output into rows + columns.
--- Handles multiline quoted fields (RFC 4180).
--- Shared by all adapters that use CSV CLI output.
function M.parse_csv(raw)
  if not raw or raw == "" then
    return { columns = {}, rows = {} }
  end

  -- Parse entire raw string respecting quoted fields that span newlines.
  local all_rows = {}
  local fields = {}
  local i = 1
  local len = #raw

  while i <= len do
    local ch = raw:sub(i, i)

    if ch == '"' then
      -- Quoted field: may contain newlines, commas, escaped quotes
      local field = ""
      i = i + 1
      while i <= len do
        local qch = raw:sub(i, i)
        if qch == '"' then
          if raw:sub(i + 1, i + 1) == '"' then
            field = field .. '"'
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          field = field .. qch
          i = i + 1
        end
      end
      table.insert(fields, field)
      -- After closing quote: expect comma, newline, or end
      if i <= len then
        ch = raw:sub(i, i)
        if ch == "," then
          i = i + 1
        elseif ch == "\n" or ch == "\r" then
          if ch == "\r" and raw:sub(i + 1, i + 1) == "\n" then i = i + 1 end
          i = i + 1
          table.insert(all_rows, fields)
          fields = {}
        end
      end
    elseif ch == "," then
      table.insert(fields, "")
      i = i + 1
    elseif ch == "\n" or ch == "\r" then
      if ch == "\r" and raw:sub(i + 1, i + 1) == "\n" then i = i + 1 end
      i = i + 1
      table.insert(all_rows, fields)
      fields = {}
    else
      -- Unquoted field
      local start = i
      while i <= len do
        local uch = raw:sub(i, i)
        if uch == "," or uch == "\n" or uch == "\r" then break end
        i = i + 1
      end
      table.insert(fields, raw:sub(start, i - 1))
      if i <= len then
        ch = raw:sub(i, i)
        if ch == "," then
          i = i + 1
        elseif ch == "\n" or ch == "\r" then
          if ch == "\r" and raw:sub(i + 1, i + 1) == "\n" then i = i + 1 end
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
--- MariaDB does not support --csv; --batch produces tab-separated output
--- with \N for NULL and backslash escaping for special characters.
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

local function resolve(url)
  local conn, conn_err = M.get_url(url)
  if not conn then return nil, nil, conn_err end
  local adapter, adapt_err = adapters.resolve(conn)
  if not adapter then return nil, nil, adapt_err end
  return adapter, conn, nil
end

-- ── public interface (unchanged signatures) ───────────────────────────────

function M.query(sql, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return adapter.query(sql, conn)
end

function M.get_primary_keys(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  return adapter.get_primary_keys(table_name, conn)
end

function M.get_column_info(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return adapter.get_column_info(table_name, conn)
end

function M.execute(sql, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  return adapter.execute(sql, conn)
end

--- Ping a connection. Returns true on success, false on any error.
--- File-backed adapters check filereadable(); network adapters run SELECT 1 (5s timeout).
function M.ping(url)
  local adapter, conn, err = resolve(url)
  if not adapter then return false end
  if adapter.ping then return adapter.ping(conn) end
  return false
end

function M.get_foreign_keys(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_foreign_keys then return {}, "Adapter does not support FK lookup" end
  return adapter.get_foreign_keys(table_name, conn)
end

function M.list_tables(url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.list_tables then return nil, "Adapter does not support list_tables" end
  return adapter.list_tables(conn)
end

--- Fetch all table columns in a single batch query (adapter-specific optimisation).
--- Returns { [table_name] = [{column_name, data_type, is_nullable}] } or nil.
--- nil means the adapter doesn't support batch fetch; callers fall back to per-table.
function M.get_schema_batch(url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil end
  if not adapter.get_schema_batch then return nil end
  return adapter.get_schema_batch(conn)
end

--- Async variant of get_schema_batch. Calls callback(tables) when done, or callback(nil) on error.
--- No-op if the adapter doesn't support async batch fetch.
function M.get_schema_batch_async(url, callback)
  local adapter, conn, err = resolve(url)
  if not adapter or not adapter.get_schema_batch_async then callback(nil); return end
  adapter.get_schema_batch_async(conn, callback)
end

function M.get_indexes(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_indexes then return {}, "Adapter does not support get_indexes" end
  return adapter.get_indexes(table_name, conn)
end

function M.get_table_stats(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.get_table_stats then return nil, "Adapter does not support get_table_stats" end
  return adapter.get_table_stats(table_name, conn)
end

function M.explain(sql_str, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.explain then return nil, "Adapter does not support EXPLAIN" end
  return adapter.explain(sql_str, conn)
end

function M.get_constraints(table_name, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return {}, err end
  if not adapter.get_constraints then return {}, "Adapter does not support get_constraints" end
  return adapter.get_constraints(table_name, conn)
end

--- Describe the columns of a local/remote file via DuckDB DESCRIBE.
--- Returns (cols, nil) on success where cols = { {column_name, data_type} }.
--- Returns (nil, err_string) on failure.
function M.describe_file(path, url)
  local safe = path:gsub("'", "''")
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
