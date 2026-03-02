-- query.lua — pure query composition.
-- No I/O. No state. No side effects. Values in, strings out.
-- Query spec is a plain Lua table (a value, not an object).

local sql_mod = require("dadbod-grip.sql")

local M = {}

-- ── deep copy (local, same pattern as data.lua) ─────────────────────────
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

-- ── constructors ─────────────────────────────────────────────────────────

--- Create a spec for a table query.
function M.new_table(table_name, page_size)
  return {
    table_name = table_name,
    base_sql   = nil,
    sorts      = {},
    filters    = {},
    page       = 1,
    page_size  = page_size or 100,
    is_raw     = false,
  }
end

--- Create a spec for a raw SELECT/WITH query.
function M.new_raw(sql_str, page_size)
  -- Strip trailing semicolons — raw SQL gets wrapped in a subquery
  local cleaned = sql_str and sql_str:gsub(";%s*$", "") or sql_str
  return {
    table_name = nil,
    base_sql   = cleaned,
    sorts      = {},
    filters    = {},
    page       = 1,
    page_size  = page_size or 100,
    is_raw     = true,
  }
end

-- ── sort modifiers ───────────────────────────────────────────────────────

--- Toggle sort on a column (replaces existing sorts).
--- Cycles: off → ASC → DESC → off.
function M.toggle_sort(spec, column)
  local new = deep_copy(spec)
  new.page = 1
  for i, s in ipairs(new.sorts) do
    if s.column == column then
      if s.dir == "ASC" then
        new.sorts[i].dir = "DESC"
      else
        table.remove(new.sorts, i)
      end
      return new
    end
  end
  -- Not found → replace all with ASC on this column
  new.sorts = { { column = column, dir = "ASC" } }
  return new
end

--- Add/toggle secondary sort (stacked).
function M.add_sort(spec, column)
  local new = deep_copy(spec)
  new.page = 1
  for i, s in ipairs(new.sorts) do
    if s.column == column then
      if s.dir == "ASC" then
        new.sorts[i].dir = "DESC"
      else
        table.remove(new.sorts, i)
      end
      return new
    end
  end
  table.insert(new.sorts, { column = column, dir = "ASC" })
  return new
end

--- Clear all sorts.
function M.clear_sorts(spec)
  local new = deep_copy(spec)
  new.sorts = {}
  new.page = 1
  return new
end

--- Get sort indicator for a column header.
--- Returns "▲", "▼", "▲1", "▼2", or nil.
function M.get_sort_indicator(spec, column)
  for i, s in ipairs(spec.sorts) do
    if s.column == column then
      local arrow = s.dir == "ASC" and "▲" or "▼"
      if #spec.sorts > 1 then
        return arrow .. tostring(i)
      end
      return arrow
    end
  end
  return nil
end

-- ── filter modifiers ─────────────────────────────────────────────────────

--- Add a WHERE clause fragment. Multiple filters are AND-ed.
function M.add_filter(spec, clause)
  local new = deep_copy(spec)
  new.page = 1
  table.insert(new.filters, { clause = clause })
  return new
end

--- Quick-filter: "column = value" or "column IS NULL".
function M.quick_filter(spec, column, value)
  local clause
  if value == nil then
    clause = sql_mod.quote_ident(column) .. " IS NULL"
  else
    clause = sql_mod.quote_ident(column) .. " = " .. sql_mod.quote_value(value)
  end
  return M.add_filter(spec, clause)
end

--- Clear all filters.
function M.clear_filters(spec)
  local new = deep_copy(spec)
  new.filters = {}
  new.page = 1
  return new
end

--- Check if spec has active filters.
function M.has_filters(spec)
  return #spec.filters > 0
end

--- Human-readable filter summary for status line.
function M.filter_summary(spec)
  if #spec.filters == 0 then return "" end
  if #spec.filters == 1 then
    return "filter: " .. spec.filters[1].clause
  end
  return #spec.filters .. " filters"
end

--- Replace all filters with a single clause (for loading presets).
function M.set_filters(spec, clause)
  local new = deep_copy(spec)
  new.filters = { { clause = clause } }
  new.page = 1
  return new
end

--- Reset all modifiers: clear sorts, filters, page back to 1.
function M.reset(spec)
  local new = deep_copy(spec)
  new.sorts = {}
  new.filters = {}
  new.page = 1
  return new
end

-- ── pagination modifiers ─────────────────────────────────────────────────

function M.set_page(spec, page)
  local new = deep_copy(spec)
  new.page = math.max(1, page)
  return new
end

function M.next_page(spec)
  return M.set_page(spec, spec.page + 1)
end

function M.prev_page(spec)
  return M.set_page(spec, spec.page - 1)
end

--- Page info string for status line.
function M.page_info(spec, total_rows)
  if total_rows then
    local total_pages = math.max(1, math.ceil(total_rows / spec.page_size))
    return string.format("Page %d/%d (%d rows)", spec.page, total_pages, total_rows)
  end
  return string.format("Page %d", spec.page)
end

-- ── SQL composition ──────────────────────────────────────────────────────

--- Build the data query SQL from a spec.
function M.build_sql(spec)
  local parts = {}

  -- FROM clause
  local from
  if spec.is_raw then
    from = "(" .. spec.base_sql .. ") AS _grip"
  else
    from = sql_mod.quote_ident(spec.table_name)
  end

  table.insert(parts, "SELECT * FROM " .. from)

  -- WHERE clause
  if #spec.filters > 0 then
    local where_parts = {}
    for _, f in ipairs(spec.filters) do
      table.insert(where_parts, "(" .. f.clause .. ")")
    end
    table.insert(parts, "WHERE " .. table.concat(where_parts, " AND "))
  end

  -- ORDER BY clause
  if #spec.sorts > 0 then
    local order_parts = {}
    for _, s in ipairs(spec.sorts) do
      table.insert(order_parts, sql_mod.quote_ident(s.column) .. " " .. s.dir)
    end
    table.insert(parts, "ORDER BY " .. table.concat(order_parts, ", "))
  end

  -- LIMIT / OFFSET
  table.insert(parts, "LIMIT " .. spec.page_size)
  if spec.page > 1 then
    table.insert(parts, "OFFSET " .. ((spec.page - 1) * spec.page_size))
  end

  return table.concat(parts, " ")
end

--- Build COUNT query (for pagination total).
function M.build_count_sql(spec)
  local parts = {}
  local from
  if spec.is_raw then
    from = "(" .. spec.base_sql .. ") AS _grip"
  else
    from = sql_mod.quote_ident(spec.table_name)
  end

  table.insert(parts, "SELECT COUNT(*) AS _grip_count FROM " .. from)

  if #spec.filters > 0 then
    local where_parts = {}
    for _, f in ipairs(spec.filters) do
      table.insert(where_parts, "(" .. f.clause .. ")")
    end
    table.insert(parts, "WHERE " .. table.concat(where_parts, " AND "))
  end

  return table.concat(parts, " ")
end

return M
