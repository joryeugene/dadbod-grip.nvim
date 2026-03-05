-- sql.lua: pure SQL generation.
-- No DB calls. No state. Pure string builders.

local M = {}

-- Quote a value for use in SQL.
-- nil    → NULL
-- string → 'value' with single-quote escaping
-- number → n
-- bool   → TRUE / FALSE
function M.quote_value(v)
  if v == nil then
    return "NULL"
  elseif type(v) == "boolean" then
    return v and "TRUE" or "FALSE"
  elseif type(v) == "number" then
    return tostring(v)
  else
    -- Escape single quotes by doubling them
    local escaped = tostring(v):gsub("'", "''")
    return "'" .. escaped .. "'"
  end
end

-- Quote a column or table identifier with double-quotes.
function M.quote_ident(name)
  -- Split on . and quote each part: schema.table → "schema"."table"
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    table.insert(parts, '"' .. part:gsub('"', '""') .. '"')
  end
  return table.concat(parts, ".")
end
local quote_ident = M.quote_ident

-- M.build_update(table_name, pk_values, changes) → string
-- pk_values: { col = "val", ... }
-- changes:   { col = new_val, ... }  (data.NULL_SENTINEL means SQL NULL)
function M.build_update(table_name, pk_values, changes)
  local NULL_SENTINEL = require("dadbod-grip.data").NULL_SENTINEL
  local set_parts = {}
  for col, val in pairs(changes) do
    local sql_val = (val == NULL_SENTINEL) and "NULL" or M.quote_value(val)
    table.insert(set_parts, quote_ident(col) .. " = " .. sql_val)
  end
  -- Sort for deterministic output
  table.sort(set_parts)

  local where_parts = {}
  for col, val in pairs(pk_values) do
    if val == nil or val == "" then
      table.insert(where_parts, quote_ident(col) .. " IS NULL")
    else
      table.insert(where_parts, quote_ident(col) .. " = " .. M.quote_value(val))
    end
  end
  table.sort(where_parts)

  return string.format(
    "UPDATE %s SET %s WHERE %s",
    quote_ident(table_name),
    table.concat(set_parts, ", "),
    table.concat(where_parts, " AND ")
  )
end

-- M.build_insert(table_name, values, columns) → string
-- values:  { col = val, ... }  (data.NULL_SENTINEL means SQL NULL)
-- columns: ordered list of column names (defines INSERT column order)
function M.build_insert(table_name, values, columns)
  local NULL_SENTINEL = require("dadbod-grip.data").NULL_SENTINEL
  local col_parts = {}
  local val_parts = {}

  for _, col in ipairs(columns) do
    local val = values[col]
    -- Skip columns with nil that aren't explicitly set (let DB use DEFAULT)
    -- NULL_SENTINEL is non-nil and emits SQL NULL explicitly
    if val ~= nil then
      table.insert(col_parts, quote_ident(col))
      local sql_val = (val == NULL_SENTINEL) and "NULL" or M.quote_value(val)
      table.insert(val_parts, sql_val)
    end
  end

  if #col_parts == 0 then
    -- All defaults: INSERT with no columns
    return string.format("INSERT INTO %s DEFAULT VALUES", quote_ident(table_name))
  end

  return string.format(
    "INSERT INTO %s (%s) VALUES (%s)",
    quote_ident(table_name),
    table.concat(col_parts, ", "),
    table.concat(val_parts, ", ")
  )
end

-- M.build_delete(table_name, pk_values) → string
-- pk_values: { col = "val", ... }
function M.build_delete(table_name, pk_values)
  local where_parts = {}
  for col, val in pairs(pk_values) do
    if val == nil or val == "" then
      table.insert(where_parts, quote_ident(col) .. " IS NULL")
    else
      table.insert(where_parts, quote_ident(col) .. " = " .. M.quote_value(val))
    end
  end
  table.sort(where_parts)

  return string.format(
    "DELETE FROM %s WHERE %s",
    quote_ident(table_name),
    table.concat(where_parts, " AND ")
  )
end

-- M.preview_staged(table_name, updates, deletes, inserts) → string
-- Generates a multi-line SQL preview of all staged changes.
-- updates: from data.get_updates(), deletes: from data.get_deletes(), inserts: from data.get_inserts()
function M.preview_staged(table_name, updates, deletes, inserts)
  local stmts = {}
  for _, del in ipairs(deletes) do
    table.insert(stmts, M.build_delete(table_name, del.pk_values) .. ";")
  end
  for _, upd in ipairs(updates) do
    table.insert(stmts, M.build_update(table_name, upd.pk_values, upd.changes) .. ";")
  end
  for _, ins in ipairs(inserts) do
    table.insert(stmts, M.build_insert(table_name, ins.values, ins.columns) .. ";")
  end
  if #stmts == 0 then return "-- no staged changes" end
  return table.concat(stmts, "\n")
end

return M
