-- init.lua — wiring + :Grip command.
-- Entry point. Parses arg, validates connection, orchestrates modules.

local db     = require("dadbod-grip.db")
local data   = require("dadbod-grip.data")
local view   = require("dadbod-grip.view")
local editor = require("dadbod-grip.editor")
local sql    = require("dadbod-grip.sql")
local query  = require("dadbod-grip.query")

local M = {}

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

--- Detect if arg is a queryable file path for DuckDB file-as-table.
local function is_queryable_file(arg)
  if not (arg:match("^/") or arg:match("^~/") or arg:match("^%./") or arg:match("^%.%./")) then
    return false
  end
  local lower = arg:lower()
  for _, ext in ipairs(DUCKDB_EXTENSIONS) do
    if lower:sub(-#ext) == ext then return true end
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

  -- File-as-table: route to DuckDB
  if is_queryable_file(arg) then
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

  -- If it looks like a SELECT/WITH statement, run as raw query
  local upper = arg:upper():match("^%s*(%u+)")
  if upper == "SELECT" or upper == "WITH" or upper == "TABLE" then
    return query.new_raw(arg, page_size), nil
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

  local errors = {}

  -- Execute deletes first (avoids FK conflicts with inserts)
  for _, del in ipairs(deletes) do
    local stmt = sql.build_delete(st.table_name, del.pk_values)
    local result, err = db.execute(stmt, url)
    if err then
      table.insert(errors, { sql = stmt, err = err })
    elseif result.affected == 0 then
      table.insert(errors, {
        sql = stmt,
        err = "0 rows affected — row may have been modified externally. Press r to refresh.",
      })
    end
  end

  for _, upd in ipairs(updates) do
    local stmt = sql.build_update(st.table_name, upd.pk_values, upd.changes)
    local result, err = db.execute(stmt, url)
    if err then
      table.insert(errors, { sql = stmt, err = err })
    elseif result.affected == 0 then
      table.insert(errors, {
        sql = stmt,
        err = "0 rows affected — row may have been modified externally. Press r to refresh.",
      })
    end
  end

  for _, ins in ipairs(inserts) do
    local stmt = sql.build_insert(st.table_name, ins.values, ins.columns)
    local _, err = db.execute(stmt, url)
    if err then
      table.insert(errors, { sql = stmt, err = err })
    end
  end

  if #errors > 0 then
    -- Show first error. Changes are preserved (not undone).
    local first = errors[1]
    local lines = {
      "✗ " .. first.sql,
      "",
    }
    for chunk in (first.err .. "\n"):gmatch("([^\n]+)\n?") do
      if chunk ~= "" then table.insert(lines, "  " .. chunk) end
    end
    table.insert(lines, "")
    table.insert(lines, "  Your change is preserved. Fix the value or press u to undo.")
    editor.show_error("Apply failed", lines)
    return
  end

  -- Success — notify and refresh
  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify("Applied " .. table.concat(parts, ", "), vim.log.levels.INFO)
  session.on_refresh(bufnr)
end

-- ── refresh ───────────────────────────────────────────────────────────────
local function do_refresh(bufnr, url, query_sql, table_name)
  local result, err = db.query(query_sql, url)
  if err then
    vim.notify("Grip: query failed: " .. err, vim.log.levels.ERROR)
    return
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
    view.render(bufnr, new_state)
  end)
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
  local spec, table_name_arg, file_path = resolve_query(arg, OPTS.limit)
  if not spec then
    vim.notify("Grip: " .. table_name_arg, vim.log.levels.WARN)
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

  -- Run query
  local result, qerr = db.query(query_sql, conn)
  if not result then
    vim.notify("Grip: " .. (qerr or "query failed"), vim.log.levels.ERROR)
    return
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

  local state = data.new(result)

  -- Open the view
  local view_opts = vim.tbl_extend("force", { max_col_width = OPTS.max_col_width }, opts or {})
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
      local sql_str = s and s.query_spec and query.build_sql(s.query_spec) or query_sql
      do_refresh(bid, conn, sql_str, table_name_arg)
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
      local was_deleted = session_d.state.deleted[row_idx]
      local new_state = data.toggle_delete(session_d.state, row_idx)
      if was_deleted then
        vim.notify("Row " .. row_idx .. " unmarked", vim.log.levels.INFO)
      else
        vim.notify("Row " .. row_idx .. " marked for deletion", vim.log.levels.INFO)
      end
      view.render(bid, new_state)
    end,
    on_insert = function(bid, after_idx)
      local session_i = view._sessions[bid]
      if not session_i then return end
      local new_state = data.insert_row(session_i.state, after_idx)
      view.render(bid, new_state)
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

  -- Case 3: Normal buffer — word under cursor
  M.open(vim.fn.expand("<cword>"), nil)
end

-- ── setup ─────────────────────────────────────────────────────────────────
function M.setup(opts)
  opts = opts or {}
  OPTS.limit        = opts.limit        or 100
  OPTS.max_col_width = opts.max_col_width or 40
  OPTS.timeout      = opts.timeout      or 10000

  -- Register :Grip command
  vim.api.nvim_create_user_command("Grip", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    M.open(arg, nil)
  end, {
    nargs = "?",
    desc  = "Open dadbod-grip result grid for table or query",
  })

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

    -- Render in a float with color coding
    local explain_lines = result.lines
    local explain_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(explain_buf, 0, -1, false, explain_lines)
    vim.api.nvim_set_option_value("filetype", "sql", { buf = explain_buf })

    local max_w = 0
    for _, l in ipairs(explain_lines) do max_w = math.max(max_w, #l) end
    local width = math.min(math.max(max_w + 4, 40), vim.o.columns - 10)
    local height = math.min(#explain_lines, math.floor(vim.o.lines * 0.7))

    local win = vim.api.nvim_open_win(explain_buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " EXPLAIN Plan ",
      title_pos = "center",
    })

    -- Color code cost lines (green for low, yellow for medium, red for high)
    local explain_ns = vim.api.nvim_create_namespace("grip_explain")
    for i, line in ipairs(explain_lines) do
      local cost = line:match("cost=([%d.]+)")
      if cost then
        local c = tonumber(cost) or 0
        local hl = c < 100 and "DiagnosticOk" or c < 1000 and "DiagnosticWarn" or "DiagnosticError"
        vim.api.nvim_buf_set_extmark(explain_buf, explain_ns, i - 1, 0, {
          end_col = #line,
          hl_group = hl,
        })
      end
    end

    -- Close keymaps
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end, { buffer = explain_buf })
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

return M
