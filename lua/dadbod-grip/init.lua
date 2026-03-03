-- init.lua — wiring + :Grip command.
-- Entry point. Parses arg, validates connection, orchestrates modules.

local db     = require("dadbod-grip.db")
local data   = require("dadbod-grip.data")
local view   = require("dadbod-grip.view")
local editor = require("dadbod-grip.editor")
local sql    = require("dadbod-grip.sql")
local query  = require("dadbod-grip.query")

local M = {}
M._version = require("dadbod-grip.version")

-- Default options (overridden by setup)
local OPTS = {
  limit       = 100,
  max_col_width = 40,
  timeout     = 10000,
}

-- ── helpers ───────────────────────────────────────────────────────────────

--- Re-render a grip buffer if it's still valid and has a session.
function M._render_if_visible(bufnr)
  local s = view._sessions[bufnr]
  if s and vim.api.nvim_buf_is_valid(bufnr) then
    view.render(bufnr, s.state)
  end
end

-- File extensions DuckDB can query directly (file-as-table).
local DUCKDB_EXTENSIONS = {
  ".parquet", ".csv", ".tsv", ".json", ".ndjson", ".jsonl", ".xlsx",
}

--- Detect if arg is a queryable file path or URL for DuckDB file-as-table.
local function is_queryable_file(arg)
  local is_path = arg:match("^/") or arg:match("^~/") or arg:match("^%./") or arg:match("^%.%./")
  local is_url = arg:match("^https?://")
  if not is_path and not is_url then
    return false
  end
  local lower = arg:lower()
  -- Strip query string and fragment for URL extension matching
  local check = is_url and lower:gsub("[?#].*$", "") or lower
  for _, ext in ipairs(DUCKDB_EXTENSIONS) do
    if check:sub(-#ext) == ext then return true end
  end
  return false
end

-- Decide the query spec for a given :Grip argument.
-- Returns (spec, table_name, file_path) or (nil, err_string).
local function resolve_query(arg, page_size)
  if not arg or arg == "" then
    arg = vim.fn.expand("<cword>")
  end
  if arg == "" then
    return nil, "No table name or query provided."
  end

  -- File-as-table or URL-as-table: route to DuckDB
  if is_queryable_file(arg) then
    if arg:match("^https?://") then
      -- Remote URL: pass through to DuckDB httpfs
      local file_sql = string.format("SELECT * FROM '%s'", arg:gsub("'", "''"))
      return query.new_raw(file_sql, page_size), nil, arg
    end
    local path = arg
    if path:sub(1, 1) == "~" then
      path = (os.getenv("HOME") or "") .. path:sub(2)
    end
    path = vim.fn.fnamemodify(path, ":p")
    if vim.fn.filereadable(path) == 0 then
      return nil, "File not found: " .. path
    end
    local file_sql = string.format("SELECT * FROM '%s'", path:gsub("'", "''"))
    return query.new_raw(file_sql, page_size), nil, path
  end

  -- Detect statement type
  local upper = arg:upper():match("^%s*(%u+)")
  if upper == "SELECT" or upper == "TABLE" then
    return query.new_raw(arg, page_size), nil
  end
  -- WITH can be a read-only CTE (SELECT) or a mutating CTE (UPDATE/DELETE/INSERT).
  -- Scan for mutation keywords to decide; default to SELECT if none found.
  if upper == "WITH" then
    local stripped = arg:upper():gsub("'[^']*'", ""):gsub("%-%-.-%\n", "")
    if stripped:find("%f[%u]UPDATE%f[^%u]") or stripped:find("%f[%u]DELETE%f[^%u]")
        or stripped:find("%f[%u]INSERT%f[^%u]") then
      return nil, nil, nil, arg
    end
    return query.new_raw(arg, page_size), nil
  end
  -- REPLACE INTO (MySQL/SQLite): route through mutation preview like INSERT
  if upper == "REPLACE" then
    return nil, nil, nil, arg
  end
  -- Destructive statements: execute directly, don't wrap in SELECT
  if upper == "UPDATE" or upper == "DELETE" or upper == "INSERT"
    or upper == "ALTER" or upper == "DROP" or upper == "CREATE"
    or upper == "BEGIN" or upper == "COMMIT" or upper == "ROLLBACK" then
    return nil, nil, nil, arg  -- 4th return = mutation SQL
  end
  -- Otherwise treat as table name
  return query.new_table(arg, page_size), arg
end

-- ── apply staged changes ──────────────────────────────────────────────────
local function do_apply(bufnr, url)
  local session = view._sessions[bufnr]
  if not session then return end
  local st = session.state

  local updates = data.get_updates(st)
  local inserts = data.get_inserts(st)
  local deletes = data.get_deletes(st)

  local total = #updates + #inserts + #deletes
  if total == 0 then
    vim.notify("No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Build all statements
  local stmts = {}

  -- Deletes first (avoids FK conflicts with inserts)
  for _, del in ipairs(deletes) do
    table.insert(stmts, sql.build_delete(st.table_name, del.pk_values))
  end
  for _, upd in ipairs(updates) do
    table.insert(stmts, sql.build_update(st.table_name, upd.pk_values, upd.changes))
  end
  for _, ins in ipairs(inserts) do
    table.insert(stmts, sql.build_insert(st.table_name, ins.values, ins.columns))
  end

  -- Wrap in transaction for atomicity (all or nothing)
  local txn_sql = "BEGIN;\n" .. table.concat(stmts, ";\n") .. ";\nCOMMIT;"
  local t_apply = vim.uv.hrtime()
  local _, err = db.execute(txn_sql, url)
  local apply_ms = math.floor((vim.uv.hrtime() - t_apply) / 1e6)

  if err then
    -- Transaction failed — DB auto-rolled back
    local err_lines = { "✗ Transaction rolled back (" .. total .. " statement(s))", "" }
    for chunk in (err .. "\n"):gmatch("([^\n]+)\n?") do
      if chunk ~= "" then table.insert(err_lines, "  " .. chunk) end
    end
    table.insert(err_lines, "")
    table.insert(err_lines, "  Your changes are preserved. Fix the value or press u to undo.")
    editor.show_error("Apply failed", err_lines)
    return
  end

  -- Success — compute reverse SQL for transaction undo before clearing staging
  local reverse_stmts = {}
  local col_idx = {}
  for i, col in ipairs(st.columns) do col_idx[col] = i end

  -- Reverse of DELETE = INSERT with full original row data
  for _, del in ipairs(deletes) do
    local row_values = {}
    for _, col in ipairs(st.columns) do
      row_values[col] = st.rows[del.row_idx][col_idx[col]]
    end
    table.insert(reverse_stmts, sql.build_insert(st.table_name, row_values, st.columns))
  end

  -- Reverse of UPDATE = UPDATE with original pre-change values
  for _, upd in ipairs(updates) do
    local orig_values = {}
    for col, _ in pairs(upd.changes) do
      orig_values[col] = st.rows[upd.row_idx][col_idx[col]]
    end
    table.insert(reverse_stmts, sql.build_update(st.table_name, upd.pk_values, orig_values))
  end

  -- Reverse of INSERT = DELETE by PK.
  -- If the user typed an explicit PK (plain INSERT), use it directly.
  -- If PK was auto-assigned (clone / new-row with SERIAL/UUID), find the row
  -- by matching non-PK values after commit, then build reverse DELETE.
  for _, ins in ipairs(inserts) do
    local ins_pk_values = {}
    for _, pk in ipairs(st.pks) do
      ins_pk_values[pk] = ins.values[pk]
    end

    if not next(ins_pk_values) and #st.pks > 0 then
      -- Auto-assigned PK: locate the row by non-PK values (best-effort)
      local pk_set = {}
      for _, pk in ipairs(st.pks) do pk_set[pk] = true end
      local where_parts = {}
      for col, val in pairs(ins.values) do
        if not pk_set[col] and val and val ~= "" and val ~= data.NULL_SENTINEL then
          table.insert(where_parts, sql.quote_ident(col) .. " = " .. sql.quote_value(tostring(val)))
        end
      end
      if #where_parts > 0 then
        local pk_cols = table.concat(vim.tbl_map(function(pk)
          return sql.quote_ident(pk)
        end, st.pks), ", ")
        -- ORDER BY pk DESC picks the highest (most recently inserted) matching row
        local find_sql = "SELECT " .. pk_cols
          .. " FROM " .. sql.quote_ident(st.table_name)
          .. " WHERE " .. table.concat(where_parts, " AND ")
          .. " ORDER BY " .. sql.quote_ident(st.pks[1]) .. " DESC LIMIT 1"
        local r, _ = db.query(find_sql, url)
        if r and r.rows and r.rows[1] then
          for i, pk in ipairs(st.pks) do
            ins_pk_values[pk] = r.rows[1][i]
          end
        end
      end
    end

    if next(ins_pk_values) then
      table.insert(reverse_stmts, sql.build_delete(st.table_name, ins_pk_values))
    end
  end

  -- Store in transaction undo stack
  if #reverse_stmts > 0 then
    session._txn_undo_stack = session._txn_undo_stack or {}
    table.insert(session._txn_undo_stack, reverse_stmts)
    if #session._txn_undo_stack > 10 then table.remove(session._txn_undo_stack, 1) end
  end

  -- Clear local staging undo stack (stale pre-apply states)
  session._undo_stack = {}

  -- Notify, record history, and refresh
  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify("Applied " .. table.concat(parts, ", "), vim.log.levels.INFO)

  local history = require("dadbod-grip.history")
  history.record({ sql = txn_sql, url = url, table_name = st.table_name, type = "dml" })

  session.elapsed_ms = apply_ms
  -- Build action label from what was applied
  local action_parts = {}
  if #updates > 0 then table.insert(action_parts, "updated") end
  if #inserts > 0 then table.insert(action_parts, "inserted") end
  if #deletes > 0 then table.insert(action_parts, "deleted") end
  session.last_action = table.concat(action_parts, "+")
  session.on_refresh(bufnr)
end

-- ── refresh ───────────────────────────────────────────────────────────────
local function do_refresh(bufnr, url, query_sql, table_name)
  local t0 = vim.uv.hrtime()
  local result, err = db.query(query_sql, url)
  local elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
  if err then
    vim.notify("Grip: query failed: " .. err, vim.log.levels.ERROR)
    return
  end

  -- Empty result: fetch columns from schema (adapter returns none for 0 rows)
  if (#result.columns == 0) and table_name then
    local col_info = db.get_column_info(table_name, url)
    if col_info then
      for _, ci in ipairs(col_info) do
        table.insert(result.columns, ci.column_name)
      end
    end
  end

  -- Re-fetch primary keys
  if table_name then
    local pks, pk_err = db.get_primary_keys(table_name, url)
    result.primary_keys = (pk_err == nil) and pks or {}
  else
    result.primary_keys = {}
  end

  result.table_name = table_name
  result.url = url
  result.sql = query_sql

  local new_state = data.new(result)
  local session = view._sessions[bufnr]
  if session then
    session.elapsed_ms = elapsed_ms
    session.last_action = "query"
  end
  view.render(bufnr, new_state)
end

-- ── edit cell ─────────────────────────────────────────────────────────────
local function do_edit(bufnr, cell, url)
  local session = view._sessions[bufnr]
  if not session then return end

  -- Binary columns: not editable
  local val = cell.value or ""
  if val:sub(1, #"<binary") == "<binary" then
    vim.notify("Binary column: not editable", vim.log.levels.INFO)
    return
  end

  local prompt = (session.state.table_name or "row") .. "." .. cell.col_name
  editor.open(prompt, cell.value, function(new_val)
    if new_val == nil then return end  -- cancelled

    -- nil = NULL, anything else = new value
    local actual_val = new_val == editor.NULL_VALUE and nil or new_val

    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, actual_val)
    view.apply_edit(bufnr, new_state)
  end)
end

-- ── parse INSERT VALUES ───────────────────────────────────────────────────
-- Best-effort parser for INSERT ... VALUES (...), (...).
-- Returns list of {col = val} tables. Skips INSERT...SELECT (no VALUES keyword).
local function parse_insert_values(flat, columns)
  if not flat:find("[Vv][Aa][Ll][Uu][Ee][Ss]") then return {} end

  -- Extract column list between INSERT INTO tbl (...) VALUES
  -- Pattern: everything in parens before the VALUES keyword
  local col_str = flat:match("[Ii][Nn][Ss][Ee][Rr][Tt][^(]+%(([^)]+)%)%s*[Vv][Aa][Ll][Uu][Ee][Ss]")
  local insert_cols
  if col_str then
    insert_cols = {}
    for part in col_str:gmatch("[^,]+") do
      local col = part:match("^%s*(.-)%s*$"):gsub('^"(.*)"$', "%1"):gsub("^`(.*)`$", "%1")
      if col ~= "" then table.insert(insert_cols, col) end
    end
  else
    insert_cols = columns  -- no column list: assume schema order
  end
  if #insert_cols == 0 then return {} end

  local values_part = flat:match("[Vv][Aa][Ll][Uu][Ee][Ss]%s*(.*)")
  if not values_part then return {} end

  local rows = {}
  local pos = 1
  while pos <= #values_part do
    local pstart = values_part:find("%(", pos)
    if not pstart then break end
    -- Walk to matching ')' respecting single-quoted strings
    local depth, i = 1, pstart + 1
    while i <= #values_part and depth > 0 do
      local ch = values_part:sub(i, i)
      if ch == "'" then
        i = i + 1
        while i <= #values_part do
          if values_part:sub(i, i) == "'" then
            if values_part:sub(i + 1, i + 1) == "'" then i = i + 2
            else i = i + 1; break end
          else i = i + 1 end
        end
      elseif ch == "(" then depth = depth + 1; i = i + 1
      elseif ch == ")" then depth = depth - 1; i = i + 1
      else i = i + 1 end
    end
    local tuple = values_part:sub(pstart + 1, i - 2)
    pos = i

    -- Tokenize the tuple
    local vals, ti, tn = {}, 1, #tuple
    while ti <= tn do
      while ti <= tn and (tuple:sub(ti, ti) == "," or tuple:sub(ti, ti):match("^%s$")) do ti = ti + 1 end
      if ti > tn then break end
      local token
      if tuple:sub(ti, ti) == "'" then
        local tj = ti + 1
        while tj <= tn do
          if tuple:sub(tj, tj) == "'" then
            if tuple:sub(tj + 1, tj + 1) == "'" then tj = tj + 2
            else break end
          else tj = tj + 1 end
        end
        token = tuple:sub(ti + 1, tj - 1):gsub("''", "'")
        ti = tj + 1
      else
        local tj = ti
        while tj <= tn and tuple:sub(tj, tj) ~= "," do tj = tj + 1 end
        token = tuple:sub(ti, tj - 1):match("^%s*(.-)%s*$")
        if token:upper() == "NULL" then token = nil end
        ti = tj
      end
      table.insert(vals, token)
    end

    local row = {}
    for j, col in ipairs(insert_cols) do row[col] = vals[j] end
    table.insert(rows, row)
  end
  return rows
end

-- ── mutation preview ──────────────────────────────────────────────────────
-- Shows affected rows in a grid before executing UPDATE/DELETE/INSERT.
function M._mutation_preview(mutation_sql, url, stmt_type, caller_opts)
  local sql_mod = require("dadbod-grip.sql")

  -- Extract table name from the SQL (handles quoted identifiers)
  local flat = mutation_sql:gsub("\n", " ")
  local table_name
  if stmt_type == "UPDATE" then
    local after_update = flat:match("[Uu][Pp][Dd][Aa][Tt][Ee]%s+(.*)")
    if after_update then
      table_name = after_update:match('^"([^"]+)"') or after_update:match("^`([^`]+)`") or after_update:match("^([%w_%.]+)")
    end
  elseif stmt_type == "DELETE" then
    table_name = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
      or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
      or flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
  elseif stmt_type == "INSERT" then
    table_name = flat:match('[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+"([^"]+)"')
      or flat:match("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+`([^`]+)`")
      or flat:match("[Ii][Nn][Ss][Ee][Rr][Tt]%s+[Ii][Nn][Tt][Oo]%s+([%w_%.]+)")
  end

  if not table_name then
    vim.notify("Could not parse table from " .. stmt_type, vim.log.levels.ERROR)
    return
  end

  -- Extract WHERE clause (not applicable for INSERT)
  local where
  if stmt_type ~= "INSERT" then
    where = flat:match("[Ww][Hh][Ee][Rr][Ee]%s+(.+)$")
    if where then
      where = where:gsub("%s*;%s*$", "")
      -- Strip trailing ORDER BY, LIMIT etc.
      where = where:gsub("%s+[Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy].*$", "")
      where = where:gsub("%s+[Ll][Ii][Mm][Ii][Tt]%s+.*$", "")
    end
  end

  -- Build preview SELECT (INSERT shows full current table state)
  local preview_sql = "SELECT * FROM " .. sql_mod.quote_ident(table_name)
  if where and where ~= "" then
    preview_sql = preview_sql .. " WHERE " .. where
  end

  -- Run preview query
  local result, err = db.query(preview_sql, url)
  if not result then
    vim.notify("Preview failed: " .. (err or "query error"), vim.log.levels.ERROR)
    return
  end

  -- Fetch columns from schema if needed (empty result)
  if #result.columns == 0 then
    local col_info = db.get_column_info(table_name, url)
    if col_info then
      for _, ci in ipairs(col_info) do table.insert(result.columns, ci.column_name) end
    end
  end

  -- Fetch PKs
  local pks = db.get_primary_keys(table_name, url) or {}
  result.primary_keys = pks
  result.table_name = table_name
  result.url = url
  result.sql = preview_sql

  local state = data.new(result)
  local row_count = #result.rows

  -- For UPDATE: parse SET clause and pre-stage changes so cells show as blue
  if stmt_type == "UPDATE" and row_count > 0 then
    local set_clause = flat:match("[Ss][Ee][Tt]%s+(.-)%s+[Ww][Hh][Ee][Rr][Ee]")
      or flat:match("[Ss][Ee][Tt]%s+(.-)%s*;?%s*$")
    if set_clause then
      -- Parse "col = 'val', col2 = 'val2'" assignments
      for assignment in set_clause:gmatch("([^,]+)") do
        local col_raw, val_raw = assignment:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if col_raw and val_raw then
          -- Strip quotes from column name
          local col = col_raw:match('^"([^"]+)"$') or col_raw:match("^`([^`]+)`$") or col_raw:match("^%s*(%S+)%s*$")
          -- Strip quotes from value
          local val = val_raw:match("^'(.-)'$") or val_raw:match('^"(.-)"$') or val_raw
          if col and val then
            -- Apply as staged change to every row
            for row_idx = 1, #state.rows do
              state = data.add_change(state, row_idx, col, val)
            end
          end
        end
      end
    end
  end

  -- For DELETE: mark all rows as deleted so they show red
  if stmt_type == "DELETE" and row_count > 0 then
    for row_idx = 1, #state.rows do
      state = data.toggle_delete(state, row_idx)
    end
  end

  -- For INSERT with VALUES: parse and add new rows highlighted green
  if stmt_type == "INSERT" then
    local insert_rows = parse_insert_values(flat, result.columns)
    for _, row_values in ipairs(insert_rows) do
      state = data.insert_row_with_values(state, #result.rows, row_values)
    end
    row_count = #insert_rows  -- count = rows being inserted, not existing rows
  end

  -- Open grid with pending_mutation metadata
  local reuse_win = caller_opts and caller_opts.reuse_win
  local view_opts = {
    max_col_width = OPTS.max_col_width,
    pending_mutation = {
      sql = mutation_sql,
      type = stmt_type,
      table_name = table_name,
      row_count = row_count,
    },
  }
  if reuse_win then view_opts.reuse_win = reuse_win end

  local bufnr = view.open(state, url, preview_sql, view_opts)

  -- Store mutation info on session and re-render to pick up title/hints
  local session = view._sessions[bufnr]
  if session then
    session.pending_mutation = view_opts.pending_mutation
    session.query_spec = query.new_raw(preview_sql, OPTS.limit)
    if stmt_type == "INSERT" then
      if row_count > 0 then
        session._mutation_title = string.format("INSERT into %s (%d new row%s)",
          table_name, row_count, row_count == 1 and "" or "s")
      else
        -- INSERT ... SELECT or unparseable VALUES
        session._mutation_title = string.format("INSERT into %s (current state)", table_name)
      end
    else
      session._mutation_title = string.format("%s %s (%d row%s)",
        stmt_type, table_name, row_count, row_count == 1 and "" or "s")
    end

    -- Wire refresh callback so grid updates after mutation executes
    view.set_callbacks(bufnr, {
      on_refresh = function(bid)
        do_refresh(bid, url, preview_sql, table_name)
      end,
    })

    view.render(bufnr, session.state)  -- re-render with mutation title + hints
  end
end

-- ── open ──────────────────────────────────────────────────────────────────
function M.open(arg, url, opts)
  -- Resolve connection URL
  local conn = url
  if not conn or conn == "" then
    conn = vim.b.db
    if not conn or conn == "" then conn = vim.g.db end
  end

  -- Resolve query spec (must happen before connection check for file-as-table)
  local spec, table_name_arg, file_path, mutation_sql = resolve_query(arg, OPTS.limit)

  -- Handle destructive statements (UPDATE/DELETE/INSERT/DDL)
  if mutation_sql then
    local exec_conn = url or conn or vim.b.db or vim.g.db
    if not exec_conn or exec_conn == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    local stmt_type = mutation_sql:upper():match("^%s*(%u+)") or "SQL"

    -- For UPDATE/DELETE/INSERT/REPLACE: show preview grid with a:execute / U:cancel
    if stmt_type == "UPDATE" or stmt_type == "DELETE" or stmt_type == "INSERT"
        or stmt_type == "REPLACE" then
      -- Treat REPLACE as INSERT for preview purposes
      local preview_type = (stmt_type == "REPLACE") and "INSERT" or stmt_type
      M._mutation_preview(mutation_sql, exec_conn, preview_type, opts)
      return
    end

    -- For DDL (ALTER/DROP/CREATE/etc.): confirm then execute
    local label = ("Execute " .. stmt_type .. "?")
    local choice = vim.fn.confirm(label .. "\n\n" .. mutation_sql:sub(1, 200), "&Execute\n&Cancel", 2)
    if choice ~= 1 then return end

    local t0 = vim.uv.hrtime()
    local _, exec_err = db.execute(mutation_sql, exec_conn)
    local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
    if exec_err then
      vim.notify("Grip: " .. exec_err, vim.log.levels.ERROR)
    else
      vim.notify(string.format("%s executed (%dms)", stmt_type, ms), vim.log.levels.INFO)
      local history = require("dadbod-grip.history")
      history.record({ sql = mutation_sql, url = exec_conn, type = stmt_type:lower(), elapsed_ms = ms })
      for bufnr_r, session_r in pairs(view._sessions) do
        if session_r.on_refresh then session_r.on_refresh(bufnr_r); break end
      end
    end
    return
  end

  if not spec then
    vim.notify("Grip: " .. (table_name_arg or "unknown error"), vim.log.levels.WARN)
    return
  end

  -- File-as-table: force DuckDB adapter (works even with no db set)
  if file_path then
    conn = "duckdb::memory:"
  end

  if not conn or conn == "" then
    vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
    return
  end

  local query_sql = query.build_sql(spec)

  -- Run query with timing
  local t_start = vim.uv.hrtime()
  local result, qerr = db.query(query_sql, conn)
  local elapsed_ms = math.floor((vim.uv.hrtime() - t_start) / 1e6)
  if not result then
    vim.notify("Grip: " .. (qerr or "query failed"), vim.log.levels.ERROR)
    return
  end

  -- Empty result: adapter may not return columns. Fetch from table schema.
  if (#result.columns == 0) and table_name_arg then
    local col_info = db.get_column_info(table_name_arg, conn)
    if col_info then
      for _, ci in ipairs(col_info) do
        table.insert(result.columns, ci.column_name)
      end
    end
  end

  -- Fetch primary keys if we have a table name
  if table_name_arg then
    local pks, _ = db.get_primary_keys(table_name_arg, conn)
    result.primary_keys = pks or {}
  else
    result.primary_keys = {}
  end

  result.table_name = table_name_arg
  result.url = conn
  result.sql = query_sql
  result.elapsed_ms = elapsed_ms

  local history = require("dadbod-grip.history")
  history.record({ sql = query_sql, url = conn, table_name = table_name_arg, type = "query", elapsed_ms = elapsed_ms })

  local state = data.new(result)

  -- Open the view
  local view_opts = vim.tbl_extend("force", { max_col_width = OPTS.max_col_width, elapsed_ms = elapsed_ms }, opts or {})
  local bufnr = view.open(state, conn, query_sql, view_opts)

  -- Store query spec and run initial count for pagination
  local session = view._sessions[bufnr]
  if session then
    session.query_spec = spec
    -- Run count query for pagination
    local count_sql = query.build_count_sql(spec)
    local count_result = db.query(count_sql, conn)
    if count_result and count_result.rows[1] then
      session.total_rows = tonumber(count_result.rows[1][1]) or 0
    end
    -- Auto-fetch column info for conditional formatting
    if table_name_arg and not session._column_info then
      vim.schedule(function()
        local s = view._sessions[bufnr]
        if s and not s._column_info then
          local info = db.get_column_info(table_name_arg, conn)
          if info then
            s._column_info = info
            M._render_if_visible(bufnr)
          end
        end
      end)
    end
  end

  -- Wire callbacks
  view.set_callbacks(bufnr, {
    on_refresh = function(bid)
      local s = view._sessions[bid]
      if not s then return end
      -- Read current table name from session state (may have been updated by rename)
      local current_table = (s.state and s.state.table_name) or table_name_arg
      local sql_str = s.query_spec and query.build_sql(s.query_spec) or query_sql
      do_refresh(bid, conn, sql_str, current_table)
    end,
    on_requery = function(bid, new_spec)
      local s = view._sessions[bid]
      if not s then return end

      -- Run count query for pagination
      local count_sql = query.build_count_sql(new_spec)
      local count_result = db.query(count_sql, conn)
      if count_result and count_result.rows[1] then
        s.total_rows = tonumber(count_result.rows[1][1]) or 0
      end

      -- Clamp page to valid range
      if s.total_rows then
        local total_pages = math.max(1, math.ceil(s.total_rows / new_spec.page_size))
        if new_spec.page > total_pages then
          new_spec = query.set_page(new_spec, total_pages)
        end
      end

      s.query_spec = new_spec
      local new_sql = query.build_sql(new_spec)
      s.query_sql = new_sql
      do_refresh(bid, conn, new_sql, table_name_arg)
    end,
    on_apply = function(bid)
      do_apply(bid, conn)
    end,
    on_edit = function(bid, cell)
      do_edit(bid, cell, conn)
    end,
    on_delete = function(bid, row_idx)
      local session_d = view._sessions[bid]
      if not session_d then return end
      if session_d.state.inserted[row_idx] then
        -- Unsaved inserted row: remove it entirely
        local new_state = data.undo_row(session_d.state, row_idx)
        view.apply_edit(bid, new_state)
        vim.notify("Removed unsaved row", vim.log.levels.INFO)
      else
        -- Existing DB row: toggle delete mark
        local was_deleted = session_d.state.deleted[row_idx]
        local new_state = data.toggle_delete(session_d.state, row_idx)
        vim.notify(was_deleted and "Unmarked" or "Marked for deletion", vim.log.levels.INFO)
        view.apply_edit(bid, new_state)
      end
    end,
    on_insert = function(bid, after_idx)
      local session_i = view._sessions[bid]
      if not session_i then return end
      local new_state = data.insert_row(session_i.state, after_idx)
      view.apply_edit(bid, new_state)
      vim.notify("Inserted blank row", vim.log.levels.INFO)
      -- Move cursor to first cell of the new row
      local r = session_i._render
      if r then
        local ordered = r.ordered
        for i, idx in ipairs(ordered) do
          if new_state.inserted[idx] and idx == new_state._next_insert_idx - 1 then
            local line_nr = i + (r.data_start or 4) - 1
            local bp_row = r.byte_positions and r.byte_positions[i]
            local col_byte = bp_row and bp_row[new_state.columns[1]] and bp_row[new_state.columns[1]].start or #("║ ")
            pcall(vim.api.nvim_win_set_cursor, 0, { line_nr, col_byte })
            break
          end
        end
      end
    end,
    on_clone = function(bid, row_idx)
      local session_c = view._sessions[bid]
      if not session_c then return end
      local new_state = data.clone_row(session_c.state, row_idx)
      view.apply_edit(bid, new_state)
      vim.notify("Cloned row (edit PKs then gw to commit)", vim.log.levels.INFO)
      -- Move cursor to first cell of the cloned row
      local r = session_c._render
      if r then
        for i, idx in ipairs(r.ordered) do
          if new_state.inserted[idx] and idx == new_state._next_insert_idx - 1 then
            local line_nr = i + (r.data_start or 4) - 1
            local bp_row = r.byte_positions and r.byte_positions[i]
            local first_col = new_state.columns[1]
            local col_byte = bp_row and bp_row[first_col] and bp_row[first_col].start or #("║ ")
            pcall(vim.api.nvim_win_set_cursor, 0, { line_nr, col_byte })
            break
          end
        end
      end
    end,
  })
end

-- ── open_smart ───────────────────────────────────────────────────────────
-- DBUI-aware smart open: detects context from current buffer and opens
-- the appropriate table in the grid. Works from SQL query buffers,
-- dbout result buffers, and normal buffers (word under cursor).
function M.open_smart()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Case 1: DBUI SQL query buffer — has b:dbui_table_name + b:db (string URL)
  local dbui_table = vim.b[bufnr].dbui_table_name
  if dbui_table and dbui_table ~= "" then
    local url = vim.b[bufnr].db
    if type(url) ~= "string" or url == "" then url = vim.g.db end
    if not url or url == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    -- Find the dbout window to reuse (keeps two-pane layout)
    local reuse_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local wb = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(wb):match("%.dbout$") then
        reuse_win = win
        break
      end
    end
    local opts = reuse_win and { reuse_win = reuse_win } or nil
    M.open(dbui_table, url, opts)
    return
  end

  -- Case 2: dbout result buffer — b:db is a dict with db_url
  local db_obj = vim.b[bufnr].db
  if type(db_obj) == "table" and db_obj.db_url then
    local url = db_obj.db_url
    if not url or url == "" then url = vim.w.db end
    if not url or url == "" then url = vim.g.db end
    if not url or url == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    local table_name
    local db_input = vim.b[bufnr].db_input
    if db_input then
      local input_resolved = vim.fn.resolve(db_input)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          local bname = vim.fn.resolve(vim.api.nvim_buf_get_name(b))
          if bname == input_resolved then
            table_name = vim.b[b].dbui_table_name
            break
          end
        end
      end
      if (not table_name or table_name == "")
        and vim.fn.filereadable(db_input) == 1 then
        local sql_text = table.concat(vim.fn.readfile(db_input), " ")
        table_name = sql_text:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
      end
    end
    -- Fallback: search visible windows for a buffer with dbui_table_name
    if not table_name or table_name == "" then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wb = vim.api.nvim_win_get_buf(win)
        local tname = vim.b[wb].dbui_table_name
        if tname and tname ~= "" then
          table_name = tname
          break
        end
      end
    end
    if not table_name or table_name == "" then
      vim.notify("Grip: only works for table results, not raw queries", vim.log.levels.WARN)
      return
    end
    local winid = vim.api.nvim_get_current_win()
    M.open(table_name, url, { reuse_win = winid })
    return
  end

  -- Case 3: No DBUI/dbout context — show table picker
  local conn = vim.b.db
  if type(conn) == "table" then conn = conn.db_url end
  if not conn or conn == "" then conn = vim.g.db end
  if not conn or conn == "" then
    vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
    return
  end
  require("dadbod-grip.picker").pick_table(conn, function(table_name)
    M.open(table_name, conn)
  end)
end

-- ── setup ─────────────────────────────────────────────────────────────────
function M.setup(opts)
  opts = opts or {}
  OPTS.limit        = opts.limit        or 100
  OPTS.max_col_width = opts.max_col_width or 40
  OPTS.timeout      = opts.timeout      or 10000

  -- AI configuration (optional)
  if opts.ai then
    require("dadbod-grip.ai").setup(opts.ai)
  end

  -- Register :Grip command
  vim.api.nvim_create_user_command("Grip", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    M.open(arg, nil)
  end, {
    nargs = "?",
    desc  = "Open dadbod-grip result grid for table or query",
  })

  -- ── Query Doctor: EXPLAIN parsing and rendering ──────────────────────────

  --- Detect adapter type from connection URL.
  local function detect_adapter(url)
    if not url then return "unknown" end
    local u = url:lower()
    if u:match("^postgres") then return "postgresql" end
    if u:match("^mysql") or u:match("^mariadb") then return "mysql" end
    if u:match("^duckdb") then return "duckdb" end
    if u:match("^sqlite") then return "sqlite" end
    return "unknown"
  end

  --- Parse EXPLAIN output into structured nodes.
  function M._parse_explain_nodes(lines, adapter_type)
    local nodes = {}
    for i, line in ipairs(lines) do
      local node = { text = line, cost = nil, rows = nil, time = nil, indent = 0, operation = nil }

      -- Detect indent level
      node.indent = #(line:match("^(%s*)") or "")

      if adapter_type == "postgresql" then
        -- cost=0.00..35.50
        local cost_end = line:match("cost=[%d.]+%.%.([%d.]+)")
        if cost_end then node.cost = tonumber(cost_end) end
        local rows_val = line:match("rows=(%d+)")
        if rows_val then node.rows = tonumber(rows_val) end
        local actual_time = line:match("actual time=[%d.]+%.%.([%d.]+)")
        if actual_time then node.time = tonumber(actual_time) end
      elseif adapter_type == "mysql" then
        local cost_val = line:match("cost=([%d.]+)")
        if cost_val then node.cost = tonumber(cost_val) end
        local rows_val = line:match("rows=(%d+)")
        if rows_val then node.rows = tonumber(rows_val) end
      elseif adapter_type == "duckdb" then
        local card = line:match("Estimated Cardinality:%s*(%d+)")
        if card then node.cost = tonumber(card) end
      end

      -- Detect operation type
      local lt = line:lower()
      if lt:match("seq scan") or lt:match("full scan") or lt:match("table scan") or lt:match("scan table")
        or lt:match("^%s*scan ") then
        node.operation = "seq_scan"
      elseif lt:match("index scan") or lt:match("index lookup") or lt:match("using index")
        or lt:match("search.*using") then
        node.operation = "index_scan"
      elseif lt:match("bitmap") then
        node.operation = "bitmap_scan"
      elseif lt:match("nested loop") then
        node.operation = "nested_loop"
      elseif lt:match("hash join") or lt:match("hash match") then
        node.operation = "hash_join"
      elseif lt:match("sort") or lt:match("filesort") then
        node.operation = "sort"
      elseif lt:match("filter") then
        node.operation = "filter"
      elseif lt:match("aggregate") or lt:match("group") then
        node.operation = "aggregate"
      elseif lt:match("limit") then
        node.operation = "limit"
      end

      table.insert(nodes, node)
    end
    return nodes
  end

  --- Translation table: operation -> plain English description + severity rules.
  local TRANSLATIONS = {
    seq_scan     = { label = "Reading every row in %s", tip = "Consider adding an index on the filtered column", severity = "slow" },
    index_scan   = { label = "Looking up by index on %s", tip = nil, severity = "ok" },
    bitmap_scan  = { label = "Partial index scan on %s", tip = nil, severity = "ok" },
    nested_loop  = { label = "Comparing every row pair (nested loop)", tip = "Large nested loop; check if a hash join would help", severity = "slow" },
    hash_join    = { label = "Matching rows by hash", tip = nil, severity = "ok" },
    sort         = { label = "Sorting results (no index)", tip = "Consider a covering index to avoid this sort", severity = "warn" },
    filter       = { label = "Filtering rows before output", tip = "Index on filter column may help", severity = "warn" },
    aggregate    = { label = "Computing aggregate (GROUP BY)", tip = nil, severity = "ok" },
    limit        = { label = "Limiting results", tip = nil, severity = "ok" },
  }

  --- Render parsed nodes as plain-English Query Doctor output.
  function M._render_query_doctor(nodes, adapter_type)
    local display_lines = {}
    local hl_marks = {}

    local function add(s) table.insert(display_lines, s) end
    local function mark(hl)
      table.insert(hl_marks, { line = #display_lines, hl = hl })
    end

    add("  Query Health")
    add("  " .. string.rep("\xe2\x94\x80", 28))
    mark("GripProfileHeader")
    add("")

    -- Find max cost for bar sizing
    local max_cost = 0
    local total_cost = 0
    local root_rows = nil
    for _, n in ipairs(nodes) do
      if n.cost then
        max_cost = math.max(max_cost, n.cost)
        total_cost = total_cost + n.cost
      end
      if not root_rows and n.rows then root_rows = n.rows end
    end

    -- Render each node with an operation
    local slow_count = 0
    local has_content = false

    for _, n in ipairs(nodes) do
      if n.operation then
        local tr = TRANSLATIONS[n.operation]
        if tr then
          has_content = true
          -- Extract table name from text
          local tbl_name = n.text:match("on%s+(%S+)") or n.text:match("table%s+(%S+)") or ""
          tbl_name = tbl_name:gsub("[%(%)]", "")

          -- Determine actual severity
          local sev = tr.severity
          if sev == "slow" and n.rows and n.rows < 1000 then sev = "ok" end
          if sev == "warn" and n.cost and n.cost < 500 then sev = "ok" end
          if n.operation == "nested_loop" and (not n.rows or n.rows < 1000) then sev = "ok" end

          -- Build label
          local label = tr.label
          if label:match("%%s") then
            label = string.format(label, tbl_name ~= "" and tbl_name or "table")
          end

          -- Severity prefix
          local prefix
          if sev == "slow" then
            prefix = "  SLOW"
            slow_count = slow_count + 1
          elseif sev == "warn" then
            prefix = "  WARN"
          else
            prefix = "  OK"
          end

          add(prefix .. ": " .. label)
          if sev == "slow" then mark("DiagnosticError")
          elseif sev == "warn" then mark("DiagnosticWarn")
          else mark("DiagnosticOk")
          end

          -- Cost bar
          if n.cost and max_cost > 0 then
            local bar_w = math.max(1, math.floor((n.cost / max_cost) * 20))
            local bar = string.rep("\xe2\x96\x88", bar_w) .. string.rep("\xe2\x96\x91", 20 - bar_w)
            local pct = math.floor(n.cost / max_cost * 100)
            local bar_label = n.cost == max_cost and "  (bottleneck)" or "  (fast)"
            if sev == "warn" then bar_label = "" end
            add("  " .. bar .. "  " .. pct .. "%" .. bar_label)
          end

          -- Description with row count
          if n.rows then
            add("  This processes ~" .. n.rows .. " rows.")
          end

          -- Tip
          if sev ~= "ok" and tr.tip then
            add("  Tip: " .. tr.tip)
          end

          add("")
        end
      end
    end

    -- If no operations detected, show raw plan
    if not has_content then
      for _, n in ipairs(nodes) do
        add("  " .. n.text)
      end
      add("")
    end

    -- Summary
    add("  " .. string.rep("\xe2\x94\x80", 28))
    local summary_parts = {}
    if slow_count > 0 then
      table.insert(summary_parts, slow_count .. " slow operation(s) found")
    else
      table.insert(summary_parts, "No major issues detected")
    end
    if total_cost > 0 then
      table.insert(summary_parts, "Est. cost: " .. string.format("%.1f", total_cost))
    end
    if root_rows then
      table.insert(summary_parts, "Est. rows: " .. root_rows)
    end
    add("  " .. table.concat(summary_parts, "  |  "))
    if slow_count > 0 then mark("DiagnosticError")
    else mark("DiagnosticOk")
    end

    return display_lines, hl_marks
  end

  -- Register :GripExplain command
  vim.api.nvim_create_user_command("GripExplain", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")

    -- If no arg, try to get SQL from current grip session
    if arg == "" then
      local bufnr = vim.api.nvim_get_current_buf()
      local session = view._sessions[bufnr]
      if session and session.query_spec then
        arg = query.build_sql(session.query_spec)
      elseif session and session.query_sql then
        arg = session.query_sql
      end
    end
    if arg == "" then
      vim.notify("GripExplain: provide a SQL query or run from a Grip buffer", vim.log.levels.WARN)
      return
    end

    -- Resolve connection
    local conn = vim.b.db
    if type(conn) ~= "string" or conn == "" then conn = vim.g.db end
    if type(conn) == "table" and conn.db_url then conn = conn.db_url end
    if not conn or conn == "" then
      vim.notify("GripExplain: no database connection", vim.log.levels.WARN)
      return
    end

    local result, err = db.explain(arg, conn)
    if err then
      vim.notify("EXPLAIN failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if not result or not result.lines or #result.lines == 0 then
      vim.notify("EXPLAIN returned no output", vim.log.levels.INFO)
      return
    end

    local hist = require("dadbod-grip.history")
    hist.record({ sql = arg, url = conn, type = "explain" })

    -- Parse and render as Query Doctor
    local adapter_type = detect_adapter(conn)
    local nodes = M._parse_explain_nodes(result.lines, adapter_type)
    local doctor_lines, doctor_marks = M._render_query_doctor(nodes, adapter_type)

    local explain_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(explain_buf, 0, -1, false, doctor_lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = explain_buf })

    local max_w = 0
    for _, l in ipairs(doctor_lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
    local width = math.min(math.max(max_w + 4, 40), vim.o.columns - 10)
    local height = math.min(#doctor_lines, math.floor(vim.o.lines * 0.7))

    local win = vim.api.nvim_open_win(explain_buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " Query Health ",
      title_pos = "center",
    })

    -- Apply highlights
    local explain_ns = vim.api.nvim_create_namespace("grip_explain")
    for _, m in ipairs(doctor_marks) do
      pcall(vim.api.nvim_buf_set_extmark, explain_buf, explain_ns, m.line - 1, 0, {
        end_col = #(doctor_lines[m.line] or ""),
        hl_group = m.hl,
      })
    end

    -- Close keymaps
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = explain_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, close, { buffer = explain_buf })
    end
  end, {
    nargs = "?",
    desc  = "Show EXPLAIN plan for a query",
  })

  -- Register :GripSchema command
  vim.api.nvim_create_user_command("GripSchema", function()
    local schema = require("dadbod-grip.schema")
    schema.toggle()
  end, {
    nargs = 0,
    desc  = "Toggle schema browser sidebar",
  })

  -- Register :GripTables command
  vim.api.nvim_create_user_command("GripTables", function()
    local picker = require("dadbod-grip.picker")
    local url = db.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
    picker.pick_table(url, function(name) M.open(name, url) end)
  end, {
    nargs = 0,
    desc  = "Open table picker",
  })

  -- Register :GripQuery command
  vim.api.nvim_create_user_command("GripQuery", function(cmd_opts)
    local query_pad = require("dadbod-grip.query_pad")
    local url = db.get_url()
    local initial = vim.trim(cmd_opts.args or "")
    query_pad.open(url, initial ~= "" and { initial_sql = initial } or nil)
  end, {
    nargs = "?",
    desc  = "Open SQL query pad",
  })

  -- Register :GripSave command
  vim.api.nvim_create_user_command("GripSave", function(cmd_opts)
    local saved = require("dadbod-grip.saved")
    local name = vim.trim(cmd_opts.args or "")
    if name == "" then
      local bufnr = vim.api.nvim_get_current_buf()
      saved.save_prompt(bufnr)
    else
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      saved.save(name, table.concat(lines, "\n"))
    end
  end, {
    nargs = "?",
    desc  = "Save current query",
  })

  -- Register :GripLoad command
  vim.api.nvim_create_user_command("GripLoad", function(cmd_opts)
    local saved = require("dadbod-grip.saved")
    local name = vim.trim(cmd_opts.args or "")
    if name ~= "" then
      local content = saved.load(name)
      if content then
        local query_pad = require("dadbod-grip.query_pad")
        local url = db.get_url()
        query_pad.open(url, { initial_sql = content })
      end
    else
      saved.pick(function(content)
        local query_pad = require("dadbod-grip.query_pad")
        local url = db.get_url()
        query_pad.open(url, { initial_sql = content })
      end)
    end
  end, {
    nargs = "?",
    desc  = "Load a saved query",
  })

  -- Register :GripHistory command
  vim.api.nvim_create_user_command("GripHistory", function()
    local hist = require("dadbod-grip.history")
    hist.pick(function(content)
      local query_pad = require("dadbod-grip.query_pad")
      local url = db.get_url()
      query_pad.open(url, { initial_sql = content })
    end)
  end, {
    nargs = 0,
    desc  = "Browse query history",
  })

  -- Register :GripProfile command
  vim.api.nvim_create_user_command("GripProfile", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    local tbl = arg
    if tbl == "" then
      local bufnr_p = vim.api.nvim_get_current_buf()
      local session_p = view._sessions[bufnr_p]
      if session_p and session_p.state.table_name then
        tbl = session_p.state.table_name
      end
    end
    if tbl == "" then
      vim.notify("GripProfile: provide a table name or run from a Grip buffer", vim.log.levels.WARN)
      return
    end
    local conn = db.get_url()
    if not conn then
      vim.notify("GripProfile: no database connection", vim.log.levels.WARN)
      return
    end
    local profile = require("dadbod-grip.profile")
    profile.open(tbl, conn)
  end, {
    nargs = "?",
    desc  = "Profile table columns with sparkline distributions",
  })

  -- Register :GripAsk command
  vim.api.nvim_create_user_command("GripAsk", function(cmd_opts)
    local question = vim.trim(cmd_opts.args or "")
    local conn = db.get_url()
    if not conn then
      vim.notify("GripAsk: no database connection", vim.log.levels.WARN)
      return
    end
    local ai = require("dadbod-grip.ai")
    if question ~= "" then
      vim.notify("Generating SQL...", vim.log.levels.INFO)
      ai.generate_sql(question, conn, function(result_sql, err)
        if err then
          vim.notify("GripAsk: " .. err, vim.log.levels.ERROR)
          return
        end
        local query_pad = require("dadbod-grip.query_pad")
        query_pad.open(conn, { initial_sql = result_sql })
      end)
    else
      ai.ask(conn)
    end
  end, {
    nargs = "?",
    desc  = "Generate SQL from natural language",
  })

  -- Register :GripDiff command
  vim.api.nvim_create_user_command("GripDiff", function(cmd_opts)
    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    if #args < 2 then
      vim.notify("Usage: :GripDiff table1 table2", vim.log.levels.WARN)
      return
    end
    local url = db.get_url()
    if not url then
      vim.notify("GripDiff: no database connection", vim.log.levels.WARN)
      return
    end
    local diff_mod = require("dadbod-grip.diff")
    diff_mod.open(args[1], args[2], url)
  end, {
    nargs = "+",
    desc  = "Diff two tables side-by-side",
  })

  -- Register :GripCreate command
  vim.api.nvim_create_user_command("GripCreate", function()
    local url = db.get_url()
    if not url then
      vim.notify("GripCreate: no database connection. Use :GripConnect.", vim.log.levels.WARN)
      return
    end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.create_table(url, function()
      -- Refresh schema browser if open
      local schema_mod = require("dadbod-grip.schema")
      if schema_mod.is_open() then
        schema_mod.refresh(url)
      end
    end)
  end, {
    nargs = 0,
    desc  = "Create a new table interactively",
  })

  -- Register :GripDrop command
  vim.api.nvim_create_user_command("GripDrop", function(cmd_opts)
    local table_name = vim.trim(cmd_opts.args or "")
    if table_name == "" then
      local bufnr = vim.api.nvim_get_current_buf()
      local session = view._sessions[bufnr]
      if session and session.state.table_name then
        table_name = session.state.table_name
      end
    end
    if table_name == "" then
      vim.notify("GripDrop: provide a table name", vim.log.levels.WARN)
      return
    end
    local url = db.get_url()
    if not url then
      vim.notify("GripDrop: no database connection", vim.log.levels.WARN)
      return
    end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.drop_table(table_name, url, function()
      local schema_mod = require("dadbod-grip.schema")
      if schema_mod.is_open() then
        schema_mod.refresh(url)
      end
    end)
  end, {
    nargs = "?",
    desc  = "Drop a table (requires typed confirmation)",
  })

  -- Register :GripRename command
  vim.api.nvim_create_user_command("GripRename", function(cmd_opts)
    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    local bufnr = vim.api.nvim_get_current_buf()
    local session = view._sessions[bufnr]
    local table_name = session and session.state.table_name

    if not table_name then
      vim.notify("GripRename: run from a Grip buffer", vim.log.levels.WARN)
      return
    end
    local url = db.get_url(session and session.url)
    if not url then
      vim.notify("GripRename: no database connection", vim.log.levels.WARN)
      return
    end

    local ddl_mod = require("dadbod-grip.ddl")
    if #args >= 2 then
      -- :GripRename old_name new_name
      local old_name, new_name = args[1], args[2]
      local sql_mod = require("dadbod-grip.sql")
      local ddl_sql = string.format('ALTER TABLE %s RENAME COLUMN %s TO %s',
        sql_mod.quote_ident(table_name), sql_mod.quote_ident(old_name), sql_mod.quote_ident(new_name))
      local _, err = db.execute(ddl_sql, url)
      if err then
        vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Renamed " .. old_name .. " to " .. new_name, vim.log.levels.INFO)
        if session.on_refresh then session.on_refresh(bufnr) end
      end
    elseif #args == 1 then
      ddl_mod.rename_column(table_name, args[1], url, function()
        if session.on_refresh then session.on_refresh(bufnr) end
      end)
    else
      vim.notify("Usage: :GripRename old_name [new_name]", vim.log.levels.WARN)
    end
  end, {
    nargs = "+",
    desc  = "Rename a column: :GripRename old_name new_name",
  })

  -- Register :GripProperties command
  vim.api.nvim_create_user_command("GripProperties", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    local table_name = arg ~= "" and arg or nil
    -- Try to get table name from current grip session
    if not table_name then
      local bufnr = vim.api.nvim_get_current_buf()
      local session = view._sessions[bufnr]
      if session and session.state.table_name then
        table_name = session.state.table_name
      end
    end
    if not table_name then
      vim.notify("GripProperties: provide a table name or run from a Grip buffer", vim.log.levels.WARN)
      return
    end
    local url = db.get_url()
    if not url then
      vim.notify("GripProperties: no database connection", vim.log.levels.WARN)
      return
    end
    local properties = require("dadbod-grip.properties")
    properties.open(table_name, url)
  end, {
    nargs = "?",
    desc  = "Show table properties (columns, indexes, stats)",
  })

  -- Register :GripConnect command
  vim.api.nvim_create_user_command("GripConnect", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local arg = vim.trim(cmd_opts.args or "")
    if arg ~= "" then
      -- Direct URL or name
      local conns = connections.list()
      for _, c in ipairs(conns) do
        if c.name == arg then
          connections.switch(c.url, c.name)
          return
        end
      end
      -- Treat as URL
      connections.switch(arg)
    else
      connections.pick()
    end
  end, {
    nargs = "?",
    desc  = "Switch database connection",
  })
end

-- Exposed for testing
M._is_queryable_file = is_queryable_file
M._resolve_query = resolve_query

return M
