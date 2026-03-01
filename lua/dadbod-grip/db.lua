-- db.lua — database facade.
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

function M.explain(sql_str, url)
  local adapter, conn, err = resolve(url)
  if not adapter then return nil, err end
  if not adapter.explain then return nil, "Adapter does not support EXPLAIN" end
  return adapter.explain(sql_str, conn)
end

return M
