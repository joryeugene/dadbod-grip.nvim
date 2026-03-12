-- picker.lua: table picker with column preview.
-- Uses grip_picker (zero external deps). Never throw.

local db = require("dadbod-grip.db")

local M = {}

--- Format column info for preview display.
local function format_preview(table_name, url)
  local lines = { table_name, string.rep("─", #table_name) }
  local cols = db.get_column_info(table_name, url)
  if not cols then return lines end

  local pks = db.get_primary_keys(table_name, url)
  local pk_set = {}
  for _, pk in ipairs(pks or {}) do pk_set[pk] = true end

  local fks = db.get_foreign_keys(table_name, url)
  local fk_map = {}
  for _, fk in ipairs(fks or {}) do
    fk_map[fk.column] = fk.ref_table .. "." .. fk.ref_column
  end

  for _, col in ipairs(cols) do
    local prefix = "   "
    if pk_set[col.column_name] and fk_map[col.column_name] then
      prefix = "🔑🔗"
    elseif pk_set[col.column_name] then
      prefix = "🔑 "
    elseif fk_map[col.column_name] then
      prefix = "🔗 "
    end
    local line = prefix .. " " .. col.column_name .. "  " .. col.data_type
    if fk_map[col.column_name] then
      line = line .. "  → " .. fk_map[col.column_name]
    end
    table.insert(lines, line)
  end

  if #pks > 0 then
    table.insert(lines, "")
    table.insert(lines, "PKs: " .. table.concat(pks, ", "))
  end
  if #fks > 0 then
    table.insert(lines, "FKs: " .. table.concat(
      vim.tbl_map(function(fk) return fk.column .. " → " .. fk.ref_table end, fks), ", "))
  end

  return lines
end

--- Open table picker. Calls callback(table_name) on selection.
function M.pick_table(url, callback)
  local tables, err = db.list_tables(url)
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  if #tables == 0 then
    vim.notify("Grip: no tables found", vim.log.levels.WARN)
    return
  end

  require("dadbod-grip.grip_picker").pick({
    title = "Tables",
    items = tables,
    display = function(t)
      local icon = t.type == "view" and "○" or "●"
      return icon .. " " .. t.name
    end,
    on_select = function(t)
      callback(t.name)
    end,
  })
end

--- Format column preview lines (exposed for schema.lua reuse).
M.format_preview = format_preview

return M
