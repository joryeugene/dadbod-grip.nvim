-- data.lua: pure state transforms.
-- All functions take state, return new state. No mutation. No self.

local M = {}
local provenance = require('dadbod-grip.provenance')

-- Sentinel stored in changes table to represent an explicitly NULL-staged value.
-- Cannot use Lua nil as a table value (it removes the key).
-- Callers pass nil to add_change() for NULL; this sentinel is internal only.
local NULL_SENTINEL = vim.NIL
M.NULL_SENTINEL = NULL_SENTINEL  -- exposed so sql.lua / view.lua can check

-- Convert a decoded cell to a SQL builder value. Typed NULL never collides
-- with text, including empty text and strings used by older sentinels.
function M.from_csv_raw(raw)
  if raw == nil or raw == NULL_SENTINEL then
    return NULL_SENTINEL
  end
  return raw
end

-- State shape (plain table, no methods):
-- {
--   rows       = {},        -- original cells: strings or vim.NIL (SQL NULL)
--   columns    = {},        -- ordered column names
--   pks        = {},        -- primary key column names
--   table_name = nil,       -- nil if computed query (readonly)
--   url        = nil,       -- connection url
--   sql        = nil,       -- query used to populate
--   changes    = {},        -- [row_idx] = { field = new_value }
--   deleted    = {},        -- { [row_idx] = true }
--   inserted   = {},        -- [row_idx] = { field = value }  (row_idx > #rows)
--   _next_insert_idx = nil, -- monotonically increasing fake row idx for inserts
--   readonly   = false,     -- true without a table or every projected PK
-- }

-- Column-name → index memo, keyed by the columns table itself.
-- Safe because a state's `columns` list is created once (M.new deep-copies it)
-- and never mutated afterwards — edit_copy() shares the same table across every
-- derived state, so all of them hit the same cache entry. Weak keys let the map
-- go away with the state it belongs to.
-- Without this, effective_value() rebuilt the map on every call, which the
-- renderer makes once per cell: O(rows × cols²) per redraw.
local _col_idx_cache = setmetatable({}, { __mode = "k" })

local function col_index_map(columns)
  local map = _col_idx_cache[columns]
  if not map then
    map = {}
    for i, col in ipairs(columns) do map[col] = i end
    _col_idx_cache[columns] = map
  end
  return map
end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  for k, v in pairs(t) do copy[k] = deep_copy(v) end
  return copy
end

local function sorted_numeric_keys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

--- Shallow-copy a state, deep-copying only the mutable subtrees
--- (changes, deleted, inserted). Rows, columns, and pks are shared
--- since they are never mutated after creation.
local function edit_copy(state)
  local result = {
    rows             = state.rows,      -- immutable: share
    cell_types       = state.cell_types,
    cell_exact       = state.cell_exact,
    storage_adapter  = state.storage_adapter,
    column_info      = state.column_info,
    _unknown_columns = state._unknown_columns,
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
  for field,value in pairs(provenance.copy(state,true)) do result[field]=value end
  return result
end

-- M.new(query_result) → State
-- query_result = { rows, columns, primary_keys, table_name, url, sql, readonly }
-- query_result.readonly is the caller saying so outright (a read-only adapter,
-- a connection saved with "mode": "ro"). Those callers also hand over an empty
-- primary_keys, which already produced a read-only state on its own -- this
-- makes the reason explicit instead of leaving it to be inferred from the
-- absence of a key, so a future PK-less-but-editable grid cannot undo it.
function M.new(query_result)
  local columns = deep_copy(query_result.columns or {})
  local pks = query_result.primary_keys or {}
  local table_name = query_result.table_name
  local readonly = (#pks == 0) or (table_name == nil) or query_result.readonly == true or query_result.lossless == false
    or provenance.write_error(query_result) ~= nil
  -- UPDATE/DELETE predicates use the original result's key values. A missing
  -- projected key would disappear from that predicate and could match siblings
  -- sharing the remaining composite-key values. Require the entire key.
  local present = col_index_map(columns)
  local unknown_columns={}
  for index=1,#columns do unknown_columns[index]=provenance.column_unknown(query_result,index) end
  for _, pk in ipairs(pks) do
    if not present[pk] then readonly = true; break end
  end
  local result = {
    rows = deep_copy(query_result.rows or {}),
    cell_types = deep_copy(query_result.cell_types),
    cell_exact = deep_copy(query_result.cell_exact),
    storage_adapter = query_result.storage_adapter,
    column_info = deep_copy(query_result.column_info),
    columns = columns,
    pks = deep_copy(pks),
    table_name = table_name,
    url = query_result.url,
    sql = query_result.sql,
    changes = {},
    deleted = {},
    inserted = {},
    _next_insert_idx = #(query_result.rows or {}) + 1000,
    readonly = readonly,
    _unknown_columns = unknown_columns,
  }
  for field,value in pairs(provenance.copy(query_result)) do result[field]=value end
  return result
end

-- M.add_change(state, row_idx, field, value) → State
-- value=nil means "set to NULL": stored as NULL_SENTINEL internally so the
-- key survives in the Lua table (assigning nil would remove it).
function M.add_change(state, row_idx, field, value)
  local s = edit_copy(state)
  -- Empty text remains text; only explicit nil stages SQL NULL.
  local stored = value == nil and NULL_SENTINEL or value
  -- Inserted rows: write directly into inserted.values (not changes table)
  if s.inserted[row_idx] then
    s.inserted[row_idx].values[field] = stored
    if s.inserted[row_idx].value_types then s.inserted[row_idx].value_types[field] = nil end
    if s.inserted[row_idx].value_exact then s.inserted[row_idx].value_exact[field] = nil end
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

-- M.insert_rows_with_values(state, after_idx, rows) → State
-- Adds pre-populated rows as one state transform, preserving source order.
function M.insert_rows_with_values(state, after_idx, rows)
  local s = edit_copy(state)
  for _, values in ipairs(rows) do
    local new_idx = s._next_insert_idx
    s._next_insert_idx = s._next_insert_idx + 1
    s.inserted[new_idx] = { _after = after_idx, values = values }
  end
  return s
end

-- M.insert_row_with_values(state, after_idx, values) → State
-- Adds a row with pre-populated values as a staged insert.
-- Used by mutation preview to show INSERT VALUES rows highlighted green.
function M.insert_row_with_values(state, after_idx, values)
  return M.insert_rows_with_values(state, after_idx, { values or {} })
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

-- Original storage metadata is immutable, just like the original cell bytes.
function M.cell_type(state, row_idx, field)
  local column_index = col_index_map(state.columns)[field]
  if column_index and ((state._unknown_columns and state._unknown_columns[column_index])
      or (not state._unknown_columns and provenance.column_unknown(state,column_index))) then return 'raw_unknown' end
  local inserted = state.inserted[row_idx]
  if inserted then return inserted.value_types and inserted.value_types[field] end
  if state.changes[row_idx] and state.changes[row_idx][field] ~= nil then
    if state.changes[row_idx][field] == NULL_SENTINEL then return 'null' end
    return nil
  end
  local idx = col_index_map(state.columns)[field]
  return idx and state.cell_types and state.cell_types[row_idx] and state.cell_types[row_idx][idx]
end

function M.cell_exact(state, row_idx, field)
  local inserted = state.inserted[row_idx]
  if inserted then return inserted.value_exact and inserted.value_exact[field] end
  if state.changes[row_idx] and state.changes[row_idx][field] ~= nil then return nil end
  local idx = col_index_map(state.columns)[field]
  return idx and state.cell_exact and state.cell_exact[row_idx] and state.cell_exact[row_idx][idx]
end

-- M.clone_row(state, row_idx) → State
-- Copies all non-PK effective values into a new staged INSERT after row_idx.
function M.clone_row(state, row_idx)
  local problem=provenance.write_error(state);assert(not problem,problem)
  local s = edit_copy(state)
  local new_idx = s._next_insert_idx
  s._next_insert_idx = s._next_insert_idx + 1
  local pk_set = {}
  for _, pk in ipairs(s.pks) do pk_set[pk] = true end
  local values, types, exact = {}, {}, {}
  for _, col in ipairs(s.columns) do
    if not pk_set[col] then
      local v = M.effective_value(state, row_idx, col)
      -- A clone copies NULL explicitly, rather than applying a column default.
      values[col] = v == nil and NULL_SENTINEL or v
      types[col], exact[col] = M.cell_type(state, row_idx, col), M.cell_exact(state, row_idx, col)
    end
    -- PK columns: omit so DB SERIAL/AUTO_INCREMENT generates a new ID on commit
  end
  s.inserted[new_idx] = { _after = row_idx, values = values,
    value_types = next(types) and types or nil, value_exact = next(exact) and exact or nil }
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
local function write_metadata(state, row_idx)
  local problem=provenance.write_error(state);assert(not problem,problem)
  if not state.storage_adapter then return {} end
  local types, exact = {}, {}
  for ci, col in ipairs(state.columns) do
    if state.cell_types and state.cell_types[row_idx] then types[col] = state.cell_types[row_idx][ci] end
    if state.cell_exact and state.cell_exact[row_idx] then exact[col] = state.cell_exact[row_idx][ci] end
  end
  return { adapter_kind = state.storage_adapter, key_types = types, key_exact = exact }
end
function M.get_updates(state)
  local updates = {}
  for row_idx, field_changes in pairs(state.changes) do
    -- Only rows that exist in original rows (not inserts)
    if row_idx <= #state.rows then
      local pk_values = {}
      local col_idx = col_index_map(state.columns)

      for _, pk in ipairs(state.pks) do
        local idx = col_idx[pk]
        pk_values[pk] = idx and state.rows[row_idx][idx] or nil
      end

      -- Keep NULL_SENTINEL as-is; sql.lua checks for it and emits NULL
      local clean_changes = {}
      for col, val in pairs(field_changes) do
        clean_changes[col] = val
      end
      local update = write_metadata(state,row_idx)
      update.row_idx, update.pk_values, update.changes = row_idx, pk_values, clean_changes
      table.insert(updates, update)
    end
  end
  return updates
end

-- M.get_inserts(state) → list of {values, columns}
function M.get_inserts(state)
  local problem=provenance.write_error(state);assert(not problem,problem)
  local inserts = {}
  for _, idx in ipairs(sorted_numeric_keys(state.inserted)) do
    local ins = state.inserted[idx]
    local clean_values = {}
    for col, val in pairs(ins.values) do
      clean_values[col] = val  -- keep NULL_SENTINEL; sql.lua emits NULL for it
    end
    table.insert(inserts, {
      values = clean_values,
      value_types = deep_copy(ins.value_types),
      value_exact = deep_copy(ins.value_exact),
      adapter_kind = state.storage_adapter,
      columns = deep_copy(state.columns),
    })
  end
  return inserts
end

-- M.get_deletes(state) → list of {row_idx, pk_values}
function M.get_deletes(state)
  local deletes = {}
  local col_idx = col_index_map(state.columns)

  for row_idx in pairs(state.deleted) do
    if row_idx <= #state.rows then
      local pk_values = {}
      for _, pk in ipairs(state.pks) do
        local idx = col_idx[pk]
        pk_values[pk] = idx and state.rows[row_idx][idx] or nil
      end
      local deletion = write_metadata(state,row_idx)
      deletion.row_idx, deletion.pk_values = row_idx, pk_values
      table.insert(deletes, deletion)
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
  local idx = col_index_map(state.columns)[field]
  if not idx then return nil end
  local raw = state.rows[row_idx] and state.rows[row_idx][idx]
  -- The public cell API uses nil for typed SQL NULL, preserving all strings.
  if raw == NULL_SENTINEL then return nil end
  return raw
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
  local inserted = sorted_numeric_keys(state.inserted)
  for i = 1, #state.rows do
    table.insert(order, i)
    -- Splice in any inserted rows that follow this one
    for _, ins_idx in ipairs(inserted) do
      local ins = state.inserted[ins_idx]
      if ins._after == i then
        table.insert(order, ins_idx)
      end
    end
  end
  -- Rows inserted after the last row (after_idx = #rows or 0)
  for _, ins_idx in ipairs(inserted) do
    local ins = state.inserted[ins_idx]
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
