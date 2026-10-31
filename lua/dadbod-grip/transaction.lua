-- Verified grid transactions. Each script owns one connection and one atomic
-- commit. Row identity is captured by that write, never inferred after commit.
local data = require('dadbod-grip.data')
local sql = require('dadbod-grip.sql')
local M = {}
local q, v = sql.quote_column, sql.quote_value
local EVENT = '__GRIP_EVENT__'

local function mysql_binary(schema, column)
  for _, info in ipairs(schema or {}) do
    if info.column_name == column then
      local name = (info.data_type or ''):lower():match('^%w+')
      return ({ binary=true, varbinary=true, tinyblob=true, blob=true, mediumblob=true,
        longblob=true, bit=true })[name] == true
    end
  end
  return false
end

local function columns(info)
  local cols, writable = {}, {}
  for _, col in ipairs(info or {}) do
    cols[#cols + 1] = col.column_name
    if not col.generated then writable[#writable + 1] = col.column_name end
  end
  return cols, writable
end
local function row_map(cols, row)
  local values = {}
  for i, col in ipairs(cols) do values[col] = row[i] == nil and vim.NIL or row[i] end
  return values
end
local function metadata_map(cols, row)
  local result = {}
  for i, col in ipairs(cols) do
    if row and row[i] ~= nil and row[i] ~= vim.NIL then result[col] = row[i] end
  end
  return result
end
local function original_metadata(state, row_idx)
  return metadata_map(state.columns, state.cell_types and state.cell_types[row_idx]),
    metadata_map(state.columns, state.cell_exact and state.cell_exact[row_idx])
end
local function identity(pks, values)
  assert(#pks > 0, 'missing primary key')
  local result = {}
  for _, pk in ipairs(pks) do
    assert(values[pk] ~= nil and values[pk] ~= vim.NIL, 'NULL or missing primary key: ' .. pk)
    result[pk] = values[pk]
  end
  return result
end

function M.plan(state, info)
  local ok, result = pcall(function()
    local problem=require('dadbod-grip.provenance').write_error(state);assert(not problem,problem)
    assert(not state.readonly and state.table_name, 'grid is read-only')
    local cols, writable = columns(info)
    assert(#cols > 0, 'table metadata unavailable')
    local plan = { version = 1, table_name = state.table_name, columns = cols,
      writable = writable, pks = vim.deepcopy(state.pks), schema = info, ops = {} }
    for field,value in pairs(require('dadbod-grip.provenance').copy(state,true)) do plan[field]=value end
    for _, del in ipairs(data.get_deletes(state)) do
      local expected = row_map(state.columns, state.rows[del.row_idx])
      local types, exact = original_metadata(state, del.row_idx)
      plan.ops[#plan.ops + 1] = { kind = 'delete', keys = identity(state.pks, expected), expected = expected,
        expected_types = types, expected_exact = exact }
    end
    local allowed = {}; for _, col in ipairs(writable) do allowed[col] = true end
    for _, upd in ipairs(data.get_updates(state)) do
      for col in pairs(upd.changes) do assert(allowed[col], 'column is not writable: ' .. col) end
      if not state.deleted[upd.row_idx] then
        local expected = row_map(state.columns, state.rows[upd.row_idx])
        local post = vim.tbl_extend('force', expected, upd.changes)
        identity(state.pks, post)
        local types, exact = original_metadata(state, upd.row_idx)
        local post_types, post_exact = vim.deepcopy(types), vim.deepcopy(exact)
        for col in pairs(upd.changes) do post_types[col], post_exact[col] = nil, nil end
        plan.ops[#plan.ops + 1] = { kind = 'update', keys = identity(state.pks, expected),
          expected = expected, expected_types = types, expected_exact = exact,
          values = upd.changes, post_keys = identity(state.pks, post), post_types = post_types, post_exact = post_exact }
      end
    end
    for _, ins in ipairs(data.get_inserts(state)) do
      for _, pk in ipairs(state.pks) do assert(ins.values[pk] ~= vim.NIL, 'NULL primary key: ' .. pk) end
      plan.ops[#plan.ops + 1] = { kind = 'insert', values = ins.values,
        value_types = ins.value_types, value_exact = ins.value_exact }
    end
    assert(#plan.ops > 0, 'no staged changes')
    return plan
  end)
  if not ok then return nil, tostring(result) end
  return result
end

-- Match the adapter's public cell spelling, including PostgreSQL booleans
-- and DuckDB nested values. No value is decoded through a Lua number.
local function cell_text(name, kind)
  local cast = 'CAST(' .. name .. ' AS ' .. ((kind == 'mysql' or kind == 'mariadb') and 'CHAR' or 'TEXT') .. ')'
  if kind == 'postgresql' then
    return 'CASE WHEN ' .. name .. " IS NULL THEN NULL WHEN pg_typeof(" .. name .. ")::text='boolean' THEN CASE "
      .. cast .. " WHEN 'true' THEN 't' ELSE 'f' END ELSE " .. cast .. ' END'
  elseif kind == 'duckdb' then
    return "CASE WHEN regexp_matches(typeof(" .. name .. "), '^(STRUCT|MAP|UNION)\\(|\\]$') THEN to_json("
      .. name .. ')::VARCHAR ELSE ' .. cast .. ' END'
  elseif kind == 'mysql' or kind == 'mariadb' then
    -- The source column's charset drives conversion. Connection/client output
    -- encoding must never normalize embedded control bytes or Latin-1 text.
    return 'CONVERT(' .. name .. ' USING utf8mb4)'
  end
  return cast
end

-- Compare stored spelling exactly, independently of a key's column collation.
local function predicate(values, kind, types, exact, schema)
  local terms = {}
  for col, value in pairs(values) do
    local name = q(col)
    local storage_type = types and types[col]
    if kind == 'sqlite' and storage_type then
      terms[#terms + 1] = 'typeof(' .. name .. ') = ' .. v(storage_type)
    end
    if value == vim.NIL then terms[#terms + 1] = name .. ' IS NULL'
    elseif ((kind == 'mysql' or kind == 'mariadb') and mysql_binary(schema, col))
        or (kind == 'sqlite' and (storage_type == 'text' or storage_type == 'blob')) then
      terms[#terms + 1] = 'hex(' .. name .. ') = ' .. v(require('dadbod-grip.transport').hex(value))
    elseif kind == 'sqlite' and storage_type == 'real' and exact and exact[col] then
      terms[#terms + 1] = "printf('%!.26g'," .. name .. ') = ' .. v(exact[col])
    else
      local cast = cell_text(name, kind)
      if kind == 'mysql' or kind == 'mariadb' then cast = 'BINARY ' .. cast end
      if kind == 'sqlite' then cast = cast .. ' COLLATE BINARY' end
      if kind == 'postgresql' then cast = cast .. ' COLLATE "C"' end
      terms[#terms + 1] = cast .. ' = ' .. sql.quote_value(value, kind)
    end
  end
  table.sort(terms)
  assert(#terms > 0, 'missing predicate')
  return table.concat(terms, ' AND ')
end

local function event_expr(plan, op_idx, phase, kind, empty)
  local cells = {}
  if not empty then
    for _, col in ipairs(plan.columns) do
      if kind == 'sqlite' then
        cells[#cells + 1] = 'CASE WHEN ' .. q(col) .. ' IS NULL THEN NULL ELSE hex(CAST(' .. q(col) .. ' AS TEXT)) END'
      elseif kind == 'mysql' or kind == 'mariadb' then
        cells[#cells + 1] = 'CASE WHEN ' .. q(col) .. ' IS NULL THEN NULL ELSE HEX('
          .. (mysql_binary(plan.schema, col) and q(col) or cell_text(q(col), kind)) .. ') END'
      else cells[#cells + 1] = cell_text(q(col), kind) end
    end
  end
  local array
  if kind == 'postgresql' then array = 'json_build_array(' .. table.concat(cells, ',') .. ')::text'
  elseif kind == 'duckdb' then array = 'to_json(list_value(' .. table.concat(cells, ',') .. '))::VARCHAR'
  else array = 'json_array(' .. table.concat(cells, ',') .. ')' end
  local head = v(EVENT .. '{"op":' .. op_idx .. ',"phase":"' .. phase .. '","values":')
  if kind == 'sqlite' then
    local types, exact = {}, {}
    if not empty then
      for _, col in ipairs(plan.columns) do
        types[#types + 1] = 'typeof(' .. q(col) .. ')'
        exact[#exact + 1] = "CASE WHEN typeof(" .. q(col) .. ")='real' THEN printf('%!.26g'," .. q(col) .. ') ELSE NULL END'
      end
    end
    return head .. ' || ' .. array .. [[ || ',"types":' || json_array(]] .. table.concat(types, ',')
      .. [[) || ',"exact":' || json_array(]] .. table.concat(exact, ',') .. [[) || '}']]
  end
  if kind == 'mysql' or kind == 'mariadb' then
    local types = {}
    if not empty then for _, col in ipairs(plan.columns) do types[#types+1] = v(mysql_binary(plan.schema,col) and 'blob' or 'text') end end
    return 'CONCAT(' .. head .. ',' .. array .. [[,',"types":',JSON_ARRAY(]] .. table.concat(types,',') .. [[),'}')]]
  end
  return head .. ' || ' .. array .. " || '}'"
end

function M.compile(plan, kind, caps)
  local ok, script = pcall(function()
    require('dadbod-grip.provenance').assert_plan(plan)
    assert(kind ~= 'sqlserver', 'SQL Server grids remain read-only')
    local mysql = kind == 'mysql' or kind == 'mariadb'
    if mysql then
      for _, info in ipairs(plan.schema or {}) do
        local name = (info.data_type or ''):lower():match('^%w+')
        local _, profile_error = require('dadbod-grip.mysql_profile').enum_set(info.data_type)
        assert(not profile_error, profile_error)
        assert(not ({ geometry=true, point=true, linestring=true, polygon=true, multipoint=true,
          multilinestring=true, multipolygon=true, geometrycollection=true })[name],
          'verified grid writes do not support spatial row restoration')
      end
    end
    local token = '_grip_' .. tostring(vim.uv.hrtime()):gsub('[^%w]', '')
    local guard = q(token .. '_guard')
    local parts = { kind == 'sqlite' and 'BEGIN IMMEDIATE' or
      (kind == 'postgresql' and 'BEGIN ISOLATION LEVEL SERIALIZABLE' or 'BEGIN') }
    if kind == 'mariadb' then table.insert(parts, 1, 'SET SESSION check_constraint_checks=ON') end
    local function add(s) parts[#parts + 1] = s end
    add('CREATE TEMPORARY TABLE ' .. guard .. ' (n INTEGER NOT NULL CHECK(n=1))' .. (mysql and ' ENGINE=InnoDB' or ''))
    local function check(expr) add('INSERT INTO ' .. guard .. ' SELECT ' .. expr) end
    local function count(tbl) check('(SELECT COUNT(*) FROM ' .. tbl .. ')') end
    local col_list = table.concat(vim.tbl_map(q, plan.columns), ', ')
    local target = sql.quote_ident(plan.table_name)
    if mysql then
      assert(caps and caps.schema and caps.table_name, 'transactional table metadata unavailable')
      -- Pin the source metadata in this transaction before checking its engine.
      add('CREATE TEMPORARY TABLE ' .. q(token .. '_lock') .. ' ENGINE=InnoDB AS SELECT '
        .. col_list .. ' FROM ' .. target .. ' WHERE false')
      check("(SELECT CASE WHEN ENGINE='InnoDB' THEN 1 ELSE 0 END FROM information_schema.TABLES WHERE TABLE_SCHEMA="
        .. v(caps.schema) .. ' AND TABLE_NAME=' .. v(caps.table_name) .. ')')
    end
    local function emit(tbl, i, phase, empty)
      add('SELECT ' .. event_expr(plan, i, phase, kind, empty) .. ' AS _grip_event' .. (tbl and ' FROM ' .. tbl or ''))
    end
    local function capture(name, where)
      if mysql then
        add('CREATE TEMPORARY TABLE ' .. name .. ' ENGINE=InnoDB AS SELECT ' .. col_list .. ' FROM ' .. target .. ' WHERE false')
        add('INSERT INTO ' .. name .. ' SELECT ' .. col_list .. ' FROM ' .. target .. ' WHERE ' .. where .. ' FOR UPDATE')
      else
        add('CREATE TEMPORARY TABLE ' .. name .. ' AS SELECT ' .. col_list .. ' FROM ' .. target .. ' WHERE ' .. where
          .. (kind == 'postgresql' and ' FOR UPDATE' or ''))
      end
      count(name)
    end
    for i, op in ipairs(plan.ops) do
      local before, after = q(token .. '_b' .. i), q(token .. '_a' .. i)
      local where
      if op.kind ~= 'insert' then
        identity(plan.pks, op.keys)
        if kind == 'sqlite' then
          for col in pairs(op.expected or {}) do assert(op.expected_types and op.expected_types[col], 'unproven SQLite storage type: ' .. col) end
        end
        where = predicate(vim.tbl_extend('force', op.expected or {}, op.keys), kind, op.expected_types, op.expected_exact, plan.schema)
        capture(before, where)
        emit(before, i, 'before')
      end
      local statement
      if op.kind == 'insert' then
        local has_values = false
        for _, col in ipairs(plan.writable) do if op.values[col] ~= nil then has_values = true end end
        statement = mysql and not has_values and ('INSERT INTO ' .. target .. ' () VALUES ()')
          or sql.build_insert(plan.table_name, op.values, plan.writable, { adapter_kind = kind,
            override_identity = kind == 'postgresql' and op.restore, value_types = op.value_types, value_exact = op.value_exact })
      elseif op.kind == 'update' then
        statement = sql.build_update(plan.table_name, op.keys, op.values, { adapter_kind = kind, predicate = where, value_types = op.value_types, value_exact = op.value_exact })
      else statement = 'DELETE FROM ' .. target .. ' WHERE ' .. where end

      if kind == 'postgresql' then
        add('CREATE TEMPORARY TABLE ' .. after .. ' AS SELECT ' .. col_list .. ' FROM ' .. target .. ' WHERE false')
        add('WITH written AS (' .. statement .. ' RETURNING ' .. col_list .. ') INSERT INTO ' .. after .. ' SELECT * FROM written')
        count(after)
        if op.kind ~= 'delete' then
          local joins = {}
          for _, pk in ipairs(plan.pks) do joins[#joins + 1] = q(pk) .. ' = (SELECT ' .. q(pk) .. ' FROM ' .. after .. ')' end
          local final = q(token .. '_f' .. i)
          capture(final, table.concat(joins, ' AND '))
          after = final
        end
      elseif (kind == 'duckdb' or kind == 'mariadb') and op.kind == 'insert' and not op.required_after then
        add(statement .. ' RETURNING ' .. event_expr(plan, i, 'after', kind, false) .. ' AS _grip_event')
        after = nil -- RETURNING is the exact identity from this INSERT.
      else
        add(statement)
        if kind == 'sqlite' and op.kind == 'insert' then
          add('CREATE TEMPORARY TABLE ' .. q(token .. '_id' .. i) .. ' AS SELECT last_insert_rowid() AS id')
        end
        if kind == 'sqlite' then check('changes()') end
        if mysql then check('ROW_COUNT()') end
        if op.kind ~= 'delete' then
          local post_keys = op.kind == 'update' and op.post_keys or nil
          if not post_keys then
            local complete = true
            for _, pk in ipairs(plan.pks) do if op.values[pk] == nil then complete = false end end
            if complete then post_keys = identity(plan.pks, op.values) end
          end
          if kind == 'sqlite' and caps and caps.rowid and op.kind == 'insert' then
            local present = {}; for _, col in ipairs(plan.columns) do present[col] = true end
            local rowid; for _, name in ipairs({ 'rowid', '_rowid_', 'oid' }) do if not present[name] then rowid = name; break end end
            assert(rowid, 'no unshadowed SQLite row identity; supply complete keys')
            capture(after, q(rowid) .. ' = (SELECT id FROM ' .. q(token .. '_id' .. i) .. ')')
          elseif post_keys then capture(after, predicate(post_keys, kind,
            op.kind == 'update' and op.post_types or op.value_types, op.kind == 'update' and op.post_exact or op.value_exact, plan.schema))
          elseif kind == 'sqlite' then
            assert(caps and caps.rowid, 'generated-key Undo unsupported for this SQLite table; supply complete keys')
            local present = {}; for _, col in ipairs(plan.columns) do present[col] = true end
            local rowid; for _, name in ipairs({ 'rowid', '_rowid_', 'oid' }) do if not present[name] then rowid = name; break end end
            assert(rowid, 'no unshadowed SQLite row identity; supply complete keys')
            -- Capture before any guard-table INSERT can change last_insert_rowid().
            -- The INSERT's rowid is saved by the runner before executing checks.
            capture(after, q(rowid) .. ' = (SELECT id FROM ' .. q(token .. '_id' .. i) .. ')')
          elseif kind == 'mysql' then
            assert(#plan.pks == 1 and caps and caps.auto_increment == plan.pks[1],
              'generated-key Undo unsupported for this MySQL key; supply complete keys')
            capture(after, q(plan.pks[1]) .. ' = LAST_INSERT_ID() AND LAST_INSERT_ID() <> 0')
          else error('generated-key identity capture unsupported') end
        end
      end
      if op.kind == 'delete' then emit(nil, i, 'after', true)
      elseif after then
        for _, pk in ipairs(plan.pks) do check('(SELECT COUNT(*) FROM ' .. after .. ' WHERE ' .. q(pk) .. ' IS NOT NULL)') end
        if op.required_after then check('(SELECT COUNT(*) FROM ' .. after .. ' WHERE ' .. predicate(op.required_after, kind, op.required_after_types, op.required_after_exact, plan.schema) .. ')') end
        emit(after, i, 'after')
      end
    end
    add('COMMIT')
    return table.concat(parts, ';\n') .. ';'
  end)
  if not ok then return nil, tostring(script) end
  return script
end

local function decode(plan, raw, kind)
  local parsed, err
  if kind == 'mysql' or kind == 'mariadb' then parsed, err = require('dadbod-grip.db').parse_batch(raw)
  else parsed, err = require('dadbod-grip.db').parse_csv(raw) end
  if not parsed then return nil, err end
  local events = {}
  local function take(row)
    for _, cell in ipairs(row) do
      if cell:sub(1, #EVENT) == EVENT then
        local ok, event = pcall(vim.json.decode, cell:sub(#EVENT + 1))
        if not ok or type(event) ~= 'table' or type(event.op) ~= 'number' then return false end
        events[event.op] = events[event.op] or {}
        if events[event.op][event.phase] then return false end
        events[event.op][event.phase] = event
      end
    end
    return true
  end
  if not take(parsed.columns) then return nil, 'invalid transaction identity result' end
  for _, row in ipairs(parsed.rows) do if not take(row) then return nil, 'invalid transaction identity result' end end
  local undo = vim.deepcopy(plan); undo.ops = {}
  for i = #plan.ops, 1, -1 do
    local op, event = plan.ops[i], events[i]
    if not event or not event.after or (op.kind ~= 'insert' and not event.before) then
      return nil, 'write committed but identity result is incomplete; refresh before further writes'
    end
    local function material(receipt)
      if not receipt then return nil, {}, {} end
      assert(type(receipt.values) == 'table' and #receipt.values == #plan.columns, 'incomplete row receipt')
      local values = receipt.values
      if kind == 'sqlite' or kind == 'mysql' or kind == 'mariadb' then
        values = vim.deepcopy(values)
        for ci, value in ipairs(values) do if value ~= vim.NIL then values[ci] = require('dadbod-grip.transport').unhex(value) end end
      end
      return row_map(plan.columns, values), metadata_map(plan.columns, receipt.types), metadata_map(plan.columns, receipt.exact)
    end
    local before, before_types, before_exact = material(event.before)
    local after, after_types, after_exact
    if op.kind == 'delete' then after, after_types, after_exact = {}, {}, {}
    else after, after_types, after_exact = material(event.after) end
    local reverse
    if op.kind == 'delete' then
      reverse = { kind = 'insert', values = before, value_types = before_types, value_exact = before_exact,
        restore = true, required_after = before, required_after_types = before_types, required_after_exact = before_exact }
    elseif op.kind == 'insert' then
      reverse = { kind = 'delete', keys = identity(plan.pks, after), expected = after,
        expected_types = after_types, expected_exact = after_exact }
    else
      local values = {}; for col in pairs(op.values) do values[col] = before[col] end
      reverse = { kind = 'update', keys = identity(plan.pks, after), expected = after, expected_types = after_types, expected_exact = after_exact,
        values = values, value_types = before_types, value_exact = before_exact,
        post_keys = identity(plan.pks, before), post_types = before_types, post_exact = before_exact,
        required_after = before, required_after_types = before_types, required_after_exact = before_exact }
    end
    undo.ops[#undo.ops + 1] = reverse
  end
  return { affected = #plan.ops, undo = undo }
end

function M.decode(plan, raw, kind)
  local ok, result, err = pcall(decode, plan, raw, kind)
  if not ok or not result then
    return nil, 'write committed but identity result is unavailable; refresh before further writes: '
      .. tostring(ok and err or result)
  end
  return result, err
end

-- Submission is a separate boundary from completion. An adapter/client error
-- after submission cannot prove rollback; only a reaped client reporting a
-- recognized server SQL rejection can do that. Unknown errors never retry.
function M.submit(kind, opts, run)
  local lifecycle = type(opts) == 'table' and opts.write_lifecycle or {}
  lifecycle.state, lifecycle.settled = 'submitted', false
  local hooks = {
    on_start = function() lifecycle.state = 'started' end,
    on_complete = function() lifecycle.settled = true end,
    on_spawn_error = function() lifecycle.state = 'not_started' end,
  }
  local stdout, stderr, code = run(hooks)
  if code ~= 0 and lifecycle.settled and lifecycle.state ~= 'not_started' then
    local rejected
    if kind == 'sqlite' then
      local message = stderr:match('^Runtime error near line %d+: ([^\n]+)')
        or stderr:match('^Error near line %d+: ([^\n]+)')
      rejected = (message and (message:match('^CHECK constraint failed:') or message:match('^UNIQUE constraint failed:')
        or message:match('^NOT NULL constraint failed:') or message:match('^FOREIGN KEY constraint failed')
        or message:match('^database is locked'))) ~= nil or stderr:match('^Parse error near line %d+:') ~= nil
    elseif kind == 'postgresql' then
      rejected = stderr:match('^ERROR:') ~= nil or stderr:match('^psql:[^\n]+: ERROR:') ~= nil
    elseif kind == 'duckdb' then
      rejected = stderr:match('^Constraint Error:') ~= nil or stderr:match('^TransactionContext Error:') ~= nil
        or stderr:match('^Parser Error:') ~= nil or stderr:match('^Binder Error:') ~= nil
        or stderr:match('^Catalog Error:') ~= nil
    else
      local number = tonumber(stderr:match('^ERROR (%d+) %('))
      rejected = ({ [1062]=true, [1048]=true, [1146]=true, [1054]=true, [1064]=true,
        [1205]=true, [1213]=true, [1451]=true, [1452]=true, [3819]=true, [4025]=true })[number] == true
    end
    lifecycle.rollback_confirmed = rejected
  end
  return stdout, stderr, code
end

return M
