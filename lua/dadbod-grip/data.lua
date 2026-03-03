-- data.lua — pure state transforms.
-- All functions take state, return new state. No mutation. No self.

local M = {}

-- Sentinel stored in changes table to represent an explicitly NULL-staged value.
-- Cannot use Lua nil as a table value (it removes the key).
-- Callers pass nil to add_change() for NULL; this sentinel is internal only.
local NULL_SENTINEL = "\0NULL\0"
M.NULL_SENTINEL = NULL_SENTINEL  -- exposed so sql.lua / view.lua can check

-- State shape (plain table, no methods):
-- {
--   rows       = {},        -- original rows from query (list of string lists)
--   columns    = {},        -- ordered column names
--   pks        = {},        -- primary key column names
--   table_name = nil,       -- nil if computed query (readonly)
--   url        = nil,       -- connection url
--   sql        = nil,       -- query used to populate
--   changes    = {},        -- [row_idx] = { field = new_value }
--   deleted    = {},        -- { [row_idx] = true }
--   inserted   = {},        -- [row_idx] = { field = value }  (row_idx > #rows)
--   _next_insert_idx = nil, -- monotonically increasing fake row idx for inserts
--   readonly   = false,     -- true when no PKs detected or no table_name
-- }

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

--- Shallow-copy a state, deep-copying only the mutable subtrees
--- (changes, deleted, inserted). Rows, columns, and pks are shared
--- since they are never mutated after creation.
local function edit_copy(state)
  return {
    rows             = state.rows,      -- immutable: share
    columns          = state.columns,   -- immutable: share
    pks              = state.pks,       -- immutable: share
    table_name       = state.table_name,
    url              = state.url,
    sql              = state.sql,
    changes          = deep_copy(state.changes),
    deleted          = deep_copy(state.deleted),
    inserted         = deep_copy(state.inserted),
    _next_insert_idx = state._next_insert_idx,
    readonly         = state.readonly,
  }
end

-- M.new(query_result) → State
-- query_result = { rows, columns, primary_keys, table_name, url, sql }
function M.new(query_result)
  local pks = query_result.primary_keys or {}
  local table_name = query_result.table_name
  local readonly = (#pks == 0) or (table_name == nil)
  return {
    rows = deep_copy(query_result.rows or {}),
    columns = deep_copy(query_result.columns or {}),
    pks = deep_copy(pks),
    table_name = table_name,
    url = query_result.url,
    sql = query_result.sql,
    changes = {},
    deleted = {},
    inserted = {},
    _next_insert_idx = #(query_result.rows or {}) + 1000,
    readonly = readonly,
  }
end

-- M.add_change(state, row_idx, field, value) → State
-- value=nil means "set to NULL" — stored as NULL_SENTINEL internally so the
-- key survives in the Lua table (assigning nil would remove it).
function M.add_change(state, row_idx, field, value)
  local s = edit_copy(state)
  -- Empty string and explicit nil both become NULL
  local stored = (value == nil or value == "") and NULL_SENTINEL or value
  -- Inserted rows: write directly into inserted.values (not changes table)
  if s.inserted[row_idx] then
    s.inserted[row_idx].values[field] = stored
  else
    if not s.changes[row_idx] then s.changes[row_idx] = {} end
    s.changes[row_idx][field] = stored
  end
  return s
end

-- M.toggle_delete(state, row_idx) → State
function M.toggle_delete(state, row_idx)
  local s = edit_copy(state)
  if s.deleted[row_idx] then
    s.deleted[row_idx] = nil
  else
    s.deleted[row_idx] = true
  end
  return s
end

-- M.insert_row(state, after_idx) → State
-- Adds a blank row placeholder after after_idx.
function M.insert_row(state, after_idx)
  local s = edit_copy(state)
  local new_idx = s._next_insert_idx
  s._next_insert_idx = s._next_insert_idx + 1
  local blank = {}
  for _, col in ipairs(s.columns) do blank[col] = nil end
  s.inserted[new_idx] = { _after = after_idx, values = blank }
  return s
end

-- M.clone_row(state, row_idx) → State
-- Copies all non-PK effective values into a new staged INSERT after row_idx.
function M.clone_row(state, row_idx)
  local s = edit_copy(state)
  local new_idx = s._next_insert_idx
  s._next_insert_idx = s._next_insert_idx + 1
  local pk_set = {}
  for _, pk in ipairs(s.pks) do pk_set[pk] = true end
  local values = {}
  for _, col in ipairs(s.columns) do
    if not pk_set[col] then
      local v = M.effective_value(state, row_idx, col)
      -- Skip nil and "" — both represent NULL in original rows (psql --csv quirk)
      if v ~= nil and v ~= "" then values[col] = v end
    end
    -- PK columns: omit so DB SERIAL/AUTO_INCREMENT generates a new ID on commit
  end
  s.inserted[new_idx] = { _after = row_idx, values = values }
  return s
end

-- M.undo_row(state, row_idx) → State
-- Removes all staged changes/deletions for a row. For inserts, removes the row.
function M.undo_row(state, row_idx)
  local s = edit_copy(state)
  s.changes[row_idx] = nil
  s.deleted[row_idx] = nil
  s.inserted[row_idx] = nil
  return s
end

-- M.undo_all(state) → State
function M.undo_all(state)
  local s = edit_copy(state)
  s.changes = {}
  s.deleted = {}
  s.inserted = {}
  return s
end

-- M.get_updates(state) → list of {row_idx, pk_values, changes}
function M.get_updates(state)
  local updates = {}
  for row_idx, field_changes in pairs(state.changes) do
    -- Only rows that exist in original rows (not inserts)
    if row_idx <= #state.rows then
      local pk_values = {}
      local col_idx = {}
      for i, col in ipairs(state.columns) do col_idx[col] = i end

      for _, pk in ipairs(state.pks) do
        local idx = col_idx[pk]
        pk_values[pk] = idx and state.rows[row_idx][idx] or nil
      end

      -- Keep NULL_SENTINEL as-is; sql.lua checks for it and emits NULL
      local clean_changes = {}
      for col, val in pairs(field_changes) do
        clean_changes[col] = val
      end
      table.insert(updates, {
        row_idx = row_idx,
        pk_values = pk_values,
        changes = clean_changes,
      })
    end
  end
  return updates
end

-- M.get_inserts(state) → list of {values, columns}
function M.get_inserts(state)
  local inserts = {}
  for _, ins in pairs(state.inserted) do
    local clean_values = {}
    for col, val in pairs(ins.values) do
      clean_values[col] = val  -- keep NULL_SENTINEL; sql.lua emits NULL for it
    end
    table.insert(inserts, {
      values = clean_values,
      columns = deep_copy(state.columns),
    })
  end
  return inserts
end

-- M.get_deletes(state) → list of {row_idx, pk_values}
function M.get_deletes(state)
  local deletes = {}
  local col_idx = {}
  for i, col in ipairs(state.columns) do col_idx[col] = i end

  for row_idx in pairs(state.deleted) do
    if row_idx <= #state.rows then
      local pk_values = {}
      for _, pk in ipairs(state.pks) do
        local idx = col_idx[pk]
        pk_values[pk] = idx and state.rows[row_idx][idx] or nil
      end
      table.insert(deletes, { row_idx = row_idx, pk_values = pk_values })
    end
  end
  return deletes
end

-- M.has_changes(state) → bool
function M.has_changes(state)
  return next(state.changes) ~= nil or
         next(state.deleted) ~= nil or
         next(state.inserted) ~= nil
end

-- M.row_status(state, row_idx) → "clean"|"modified"|"deleted"|"inserted"
function M.row_status(state, row_idx)
  if state.inserted[row_idx] then return "inserted" end
  if state.deleted[row_idx] then return "deleted" end
  if state.changes[row_idx] and next(state.changes[row_idx]) then return "modified" end
  return "clean"
end

-- M.effective_value(state, row_idx, field) → value (string or nil for NULL)
-- Returns the staged value if present, else original row value.
-- nil return always means NULL (either staged or original).
function M.effective_value(state, row_idx, field)
  -- Inserted rows
  if state.inserted[row_idx] then
    local v = state.inserted[row_idx].values[field]
    if v == NULL_SENTINEL then return nil end
    return v
  end

  -- Check staged changes: key present (even if sentinel) means staged
  if state.changes[row_idx] then
    local staged = state.changes[row_idx][field]
    if staged ~= nil then
      if staged == NULL_SENTINEL then return nil end
      return staged
    end
  end

  -- Fall through to original row value
  local col_idx = {}
  for i, col in ipairs(state.columns) do col_idx[col] = i end
  local idx = col_idx[field]
  if not idx then return nil end
  local raw = state.rows[row_idx] and state.rows[row_idx][idx]
  -- psql --csv emits empty string for NULL
  return raw == "" and nil or raw
end

-- M.count_staged(state) → int (total staged operations)
function M.count_staged(state)
  local n = 0
  for _ in pairs(state.changes) do n = n + 1 end
  for _ in pairs(state.deleted) do n = n + 1 end
  for _ in pairs(state.inserted) do n = n + 1 end
  return n
end

-- M.get_ordered_rows(state) → list of row_idx (original + inserts in order)
-- Inserts are spliced after their _after idx.
function M.get_ordered_rows(state)
  local order = {}
  for i = 1, #state.rows do
    table.insert(order, i)
    -- Splice in any inserted rows that follow this one
    for ins_idx, ins in pairs(state.inserted) do
      if ins._after == i then
        table.insert(order, ins_idx)
      end
    end
  end
  -- Rows inserted after the last row (after_idx = #rows or 0)
  for ins_idx, ins in pairs(state.inserted) do
    if ins._after == 0 or ins._after >= #state.rows then
      -- Only add if not already spliced
      local found = false
      for _, v in ipairs(order) do if v == ins_idx then found = true; break end end
      if not found then table.insert(order, ins_idx) end
    end
  end
  return order
end

return M
