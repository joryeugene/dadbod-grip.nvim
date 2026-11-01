-- init.lua: wiring + :Grip command.
-- Entry point. Parses arg, validates connection, orchestrates modules.

local db     = require("dadbod-grip.db")
local data   = require("dadbod-grip.data")
local view   = require("dadbod-grip.view")
local editor = require("dadbod-grip.editor")
local sql    = require("dadbod-grip.sql")
local esc = sql.escape_literal
local query  = require("dadbod-grip.query")
local ui     = require("dadbod-grip.ui")
local explain = require("dadbod-grip.explain")
local filetypes = require("dadbod-grip.filetypes")
local importer = require("dadbod-grip.importer")
local adapters = require("dadbod-grip.adapters")

local M = {}
M._version = require("dadbod-grip.version")
M._keymaps = {}  -- populated by setup(); read by keymaps.get()

-- Query Doctor moved to explain.lua; the historical names stay on the plugin
-- module. Bound here, not in setup(), so they exist before the first setup().
M._parse_explain_nodes = explain.parse_nodes
M._render_query_doctor = explain.render

-- Module-level augroup: prevents handler accumulation on config re-source.
local _ag = vim.api.nvim_create_augroup("DadbodGripInit", { clear = true })

-- Default options (overridden by setup)
local OPTS = {
  limit       = 100,
  max_col_width = 40,
  timeout     = 10000,
  engine_timing = false,
  completion  = true,
  connections_path = nil,
  picker      = "builtin",
  pinned_max  = nil,
  border      = "rounded",
  -- Split style for the full-buffer cell editor (gB): "horizontal" opens a
  -- ~40%-height split below the grid, "vertical" a ~40%-width split.
  cell_split  = "horizontal",
  -- Auto-discover local Docker containers tagged with the
  -- dev.localdb.* label set. See sources/docker_localdb.lua. Set false
  -- to disable shelling out to `docker ps` on picker open.
  -- Mirror the grid's column-name row into the window's winbar so it stays
  -- visible when a long table scrolls past it. Costs one screen line.
  sticky_header = true,
  open_sidebar = true,
  show_hints = true,
  show_running_time = true,
  show_result_time = true,
  highlights = {},
}

--- Return a copy of the current options.
--- Copied so callers cannot mutate the live config; a deep copy also means a
--- new option added to OPTS is exposed without touching this function.
function M.get_opts()
  return vim.deepcopy(OPTS)
end

-- ── helpers ───────────────────────────────────────────────────────────────

--- Re-render a grip buffer if it's still valid and has a session.
function M._render_if_visible(bufnr)
  local s = view._sessions[bufnr]
  if s and vim.api.nvim_buf_is_valid(bufnr) then
    view.render(bufnr, s.state)
  end
end

--- Detect if arg is a queryable file path or URL for DuckDB file-as-table.
local function is_queryable_file(arg)
  local is_path = arg:match("^/") or arg:match("^~/") or arg:match("^%./") or arg:match("^%.%./")
  local is_url = arg:match("^https?://") or arg:match("^s3://")
  if not is_path and not is_url then
    return false
  end
  return filetypes.has_supported_extension(arg)
end

--- Resolve what a table-scoped user command should act on: the explicit
--- argument first, then the table behind the current grip session.
--- Notifies and returns nil when either the table or the connection is missing.
--- @param cmd_opts table    user-command opts (reads .args)
--- @param cmd_name string   command name, used as the warning prefix
--- @param no_table_msg? string  override for the "no table" warning text
--- @return string|nil table_name
--- @return string|nil url
local function resolve_target(cmd_opts, cmd_name, no_table_msg)
  local table_name = vim.trim(cmd_opts.args or "")
  if table_name == "" then
    local session = view._sessions[vim.api.nvim_get_current_buf()]
    if session and session.state.table_name then
      table_name = session.state.table_name
    end
  end
  if table_name == "" then
    vim.notify(cmd_name .. ": " .. (no_table_msg or "provide a table name or run from a Grip buffer"),
      vim.log.levels.WARN)
    return nil
  end
  local url = db.get_url()
  if not url then
    vim.notify(cmd_name .. ": no database connection", vim.log.levels.WARN)
    return nil
  end
  return table_name, url
end

--- Shorthand for the shared read-only guard; see connections.deny_if_readonly.
--- @param cmd_name string
--- @param url string|nil  defaults to the current connection
local function deny_if_readonly(cmd_name, url)
  return require("dadbod-grip.connections").deny_if_readonly(cmd_name, url)
end

local tokenize_select = require("dadbod-grip.sql_tokens").tokenize

-- Ordinary statements keep the cheap keyword check. Leading SQL comments need
-- the same lexical boundaries as previews, while the original text stays intact.
local function statement_type(text, adapter_kind)
  local keyword = text:match("^%s*([%a_\128-\255][%w_$\128-\255]*)")
  if keyword then return keyword:upper() end
  local tokens = tokenize_select(text, adapter_kind, true)
  return tokens and tokens[1] and tokens[1].upper
end

-- Classify commands at WITH-body and outer-statement positions. PostgreSQL
-- permits UPDATE/DELETE/etc. as ordinary column, alias and CTE names; scanning
-- every word would mistake those reads for writes and discard their results.
local cte_mutation_words = { UPDATE = true, DELETE = true, INSERT = true, REPLACE = true, MERGE = true }
local function cte_mutation(tokens, adapter_kind)
  -- Most WITH queries contain no DML words. Preserve their cheap read routing;
  -- any candidate, including a nested or later statement, needs full context.
  local candidate = false
  for _, token in ipairs(tokens) do
    if cte_mutation_words[token.upper] then candidate = true; break end
  end
  if not candidate then return false end
  local matching, stack, starts = {}, {}, { 1 }
  for idx, token in ipairs(tokens) do
    if token.kind == "(" then
      stack[#stack + 1] = idx
    elseif token.kind == ")" then
      local opener = table.remove(stack)
      if not opener then return nil end
      matching[opener] = idx
    elseif token.kind == ";" and #stack == 0 then
      starts[#starts + 1] = idx + 1
    end
    -- T-SQL permits adjacent commands without separators. Its reserved DML
    -- words retain the previous conservative check, excluding @variables and
    -- qualified identifiers; PostgreSQL needs the structural checks below.
    if adapter_kind == "sqlserver" then
      local previous, following = tokens[idx - 1], tokens[idx + 1]
      if following and (not previous or (previous.kind ~= "." and previous.kind ~= "@"))
          and (((token.upper == "UPDATE" or token.upper == "DELETE" or token.upper == "INSERT")
            and (following.kind == "ident" or following.kind == "@"))
            or (token.upper == "MERGE" and following.upper == "INTO")) then return true end
    end
  end
  if #stack > 0 then return nil end
  local function keyword(pos, value)
    return tokens[pos] and tokens[pos].upper == value
  end
  local function identifier(pos)
    return tokens[pos] and tokens[pos].kind == "ident"
  end
  local function after_keyword(pos, value)
    while tokens[pos] do
      if keyword(pos, value) then return pos + 1 end
      pos = (matching[pos] or pos) + 1
    end
  end
  local function command(pos, wrapped)
    -- A top-level SELECT/WITH may be wrapped in parentheses. EXPLAIN ANALYZE
    -- can execute its inner mutation, including in a later batch statement.
    while matching[pos] do pos = pos + 1 end
    local verb = tokens[pos] and tokens[pos].upper
    if verb == "EXPLAIN" then
      pos = pos + 1
      if matching[pos] then
        pos = matching[pos] + 1
      else
        while keyword(pos, "ANALYZE") or keyword(pos, "ANALYSE") or keyword(pos, "VERBOSE") do
          pos = pos + 1
        end
      end
      return command(pos, true)
    end
    if verb == "UPDATE" or verb == "DELETE" or verb == "INSERT" or verb == "REPLACE" then return true end
    if verb == "MERGE" then
      return adapter_kind == "postgresql" or adapter_kind == "duckdb" or adapter_kind == "sqlserver"
    end
    if verb ~= "WITH" then
      if wrapped and verb ~= "SELECT" and verb ~= "TABLE" and verb ~= "VALUES"
          and not (adapter_kind == "duckdb" and verb == "FROM") then return nil end
      return false
    end
    pos = pos + 1
    if keyword(pos, "RECURSIVE") then pos = pos + 1 end
    -- T-SQL WITH prefixes also carry XML namespaces or change tracking data.
    if adapter_kind == "sqlserver" and (keyword(pos, "XMLNAMESPACES")
        or keyword(pos, "CHANGE_TRACKING_CONTEXT")) then
      if not matching[pos + 1] then return nil end
      pos = matching[pos + 1] + 1
      if not tokens[pos] or tokens[pos].kind ~= "," then return command(pos) end
      pos = pos + 1
    end
    while identifier(pos) do
      pos = pos + 1 -- CTE name, even when it spells a command keyword
      if matching[pos] then pos = matching[pos] + 1 end -- optional columns
      if adapter_kind == "duckdb" and keyword(pos, "USING") and keyword(pos + 1, "KEY") then
        if not matching[pos + 2] then return nil end
        pos = matching[pos + 2] + 1
      end
      if not keyword(pos, "AS") then return nil end
      pos = pos + 1
      if keyword(pos, "NOT") then pos = pos + 1 end
      if keyword(pos, "MATERIALIZED") then pos = pos + 1 end
      local finish = matching[pos]
      if not finish then return nil end
      local mutates = command(pos + 1)
      if mutates ~= false then return mutates end
      pos = finish + 1
      -- Recursive SEARCH/CYCLE suffixes name output columns, not commands.
      if keyword(pos, "SEARCH") then
        if not (keyword(pos + 1, "DEPTH") or keyword(pos + 1, "BREADTH"))
            or not keyword(pos + 2, "FIRST") or not keyword(pos + 3, "BY") then return nil end
        pos = pos + 4
        repeat
          if not identifier(pos) then return nil end
          pos = pos + 1
          if not tokens[pos] or tokens[pos].kind ~= "," then break end
          pos = pos + 1
        until false
        -- SET is also a legal sort-column name; only the delimiter after the
        -- identifier list starts the output-column clause.
        if not keyword(pos, "SET") or not identifier(pos + 1) then return nil end
        pos = pos + 2
      end
      if keyword(pos, "CYCLE") then
        pos = after_keyword(pos + 1, adapter_kind == "mysql" and "RESTRICT" or "USING")
        if not pos then return nil end
        if adapter_kind ~= "mysql" then
          if not identifier(pos) then return nil end
          pos = pos + 1
        end
      end
      if not tokens[pos] or tokens[pos].kind ~= "," then return command(pos) end
      pos = pos + 1
    end
    return nil
  end
  for _, pos in ipairs(starts) do
    local mutates = command(pos)
    if mutates ~= false then return mutates end
  end
  return false
end

-- Expose metadata only for direct columns of one known source. A dotted name
-- may be a struct field, so its qualifier must match the actual table/alias.
local function select_editable_table(sql_text, adapter_kind)
  local tokens = tokenize_select(sql_text, adapter_kind)
  if not tokens or not tokens[1] or tokens[1].upper ~= "SELECT" then return nil end

  local from
  for idx = 2, #tokens do
    if tokens[idx].upper == "FROM" then
      from = idx
      break
    end
  end
  if not from then return nil end

  local pos = from + 1
  local source = {}
  while tokens[pos] and tokens[pos].kind == "ident" do
    local part = tokens[pos]
    if part.upper == "ONLY" or part.upper == "LATERAL" then return nil end
    -- Table metadata represents schema separators as dots; a literal dot in
    -- a quoted name would point mutations at a different qualified table.
    if part.text == "" or part.text:find(".", 1, true) then return nil end
    source[#source + 1] = part
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "." then break end
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil end
  end
  if #source == 0 then return nil end

  local clauses = {
    WHERE = true, GROUP = true, HAVING = true, ORDER = true, LIMIT = true,
    OFFSET = true, FETCH = true, FOR = true, WINDOW = true, QUALIFY = true,
  }
  local blocked = {
    JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true,
    CROSS = true, NATURAL = true, UNION = true, INTERSECT = true, EXCEPT = true,
  }
  local set_operations = { UNION = true, INTERSECT = true, EXCEPT = true }
  local alias
  local next_token = tokens[pos]
  if next_token and next_token.upper == "AS" then
    pos = pos + 1
    next_token = tokens[pos]
    if not next_token or next_token.kind ~= "ident" then return nil end
    alias = next_token
    pos = pos + 1
  elseif next_token and next_token.kind == "ident"
      and not clauses[next_token.upper] and not blocked[next_token.upper] then
    alias = next_token
    pos = pos + 1
  end
  next_token = tokens[pos]
  if next_token and next_token.kind ~= ";" and not clauses[next_token.upper] then return nil end

  -- Tail expressions do not change column lineage, but a top-level set
  -- operation can append rows from an unrelated source under the same names.
  local depth = 0
  for idx = pos, #tokens do
    local token = tokens[idx]
    if token.kind == "(" then depth = depth + 1 end
    if token.kind == ")" then depth = depth - 1 end
    -- Require an identifier before the dot: 1. UNION is still a set operation.
    local qualified = idx >= 3 and tokens[idx - 1].kind == "."
      and tokens[idx - 2].kind == "ident"
    if depth < 0 or (depth == 0 and not qualified and set_operations[token.upper]) then return nil end
    if token.kind == ";" and (depth ~= 0 or idx ~= #tokens) then return nil end
  end
  if depth ~= 0 then return nil end

  local function normalized(token)
    if adapter_kind == "postgresql" then
      return token.upper and token.text:lower() or token.text
    end
    return token.text:lower()
  end

  local value_keywords = {
    CURRENT_DATE = true, CURRENT_TIME = true, CURRENT_TIMESTAMP = true,
    ["NULL"] = true,
  }
  local dialect_values = {
    postgresql = {
      "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_CATALOG", "CURRENT_ROLE",
      "CURRENT_SCHEMA", "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER",
      "TRUE", "FALSE",
    },
    mysql = {
      "CURRENT_USER", "CURRENT_ROLE", "LOCALTIME", "LOCALTIMESTAMP",
      "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "TRUE", "FALSE",
    },
    sqlserver = { "CURRENT_USER", "SESSION_USER", "SYSTEM_USER", "USER" },
  }
  for _, keyword in ipairs(dialect_values[adapter_kind] or {}) do
    value_keywords[keyword] = true
  end

  pos = 2
  if tokens[pos] and (tokens[pos].upper == "DISTINCT" or tokens[pos].upper == "ALL") then
    pos = pos + 1
  end
  local function consume_item()
    local parts = {}
    while pos < from do
      local token = tokens[pos]
      if token.kind ~= "ident" and token.kind ~= "*" then return false end
      parts[#parts + 1] = token
      pos = pos + 1
      if tokens[pos].kind ~= "." then break end
      if token.kind == "*" then return false end
      pos = pos + 1
      if pos >= from then return false end
    end
    if #parts == 0 then return false end
    if #parts == 1 then
      return not value_keywords[parts[1].upper]
    end
    local qualifiers = #parts - 1
    if alias then
      return qualifiers == 1 and normalized(parts[1]) == normalized(alias)
    end
    if qualifiers == 1 then
      return normalized(parts[1]) == normalized(source[#source])
    end
    if qualifiers ~= #source then return false end
    for idx = 1, qualifiers do
      if normalized(parts[idx]) ~= normalized(source[idx]) then return false end
    end
    return true
  end

  if not consume_item() then return nil end
  while pos < from do
    if tokens[pos].kind ~= "," then return nil end
    pos = pos + 1
    if not consume_item() then return nil end
  end
  local names = {}
  for _, part in ipairs(source) do
    names[#names + 1] = adapter_kind == "postgresql" and normalized(part) or part.text
  end
  return table.concat(names, ".")
end

-- Decide the query spec for a given :Grip argument.
-- Returns (spec, table_name, file_path) or (nil, err_string).
local function resolve_query(arg, page_size, adapter_kind)
  if not arg or arg == "" then
    arg = vim.fn.expand("<cword>")
  end
  if arg == "" then
    return nil, "No table name or query provided."
  end

  -- File-as-table or URL-as-table: route to DuckDB
  if is_queryable_file(arg) then
    if arg:match("^https?://") or arg:match("^s3://") then
      -- Remote URL: pass through to DuckDB httpfs
      local file_sql = string.format("SELECT * FROM '%s'", esc(arg))
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
    local file_sql = string.format("SELECT * FROM '%s'", esc(path))
    return query.new_raw(file_sql, page_size), nil, path
  end

  -- Detect statement type
  local upper = statement_type(arg, adapter_kind)
  if upper == "SELECT" or upper == "TABLE" then
    local table_name = nil
    local flat = arg:gsub("\n", " ")
    if upper == "TABLE" then
      -- TABLE <name> is always a single table
      local raw = flat:match('^%s*[Tt][Aa][Bb][Ll][Ee]%s+"([^"]+)"')
        or flat:match("^%s*[Tt][Aa][Bb][Ll][Ee]%s+`([^`]+)`")
        or flat:match("^%s*[Tt][Aa][Bb][Ll][Ee]%s+([%w_%.]+)")
      if raw then table_name = sql.unquote_ident(raw) end
    else
      table_name = select_editable_table(arg, adapter_kind)
    end
    return query.new_raw(arg, page_size), table_name
  end
  -- CTE mutations retain the confirmed execution path, while identifier
  -- spellings in read queries cannot change their routing.
  if upper == "WITH" then
    local tokens = tokenize_select(arg, adapter_kind, true)
    local mutates = tokens and cte_mutation(tokens, adapter_kind)
    if mutates == nil then return nil, "Could not safely classify this WITH statement" end
    if mutates then return nil, nil, nil, arg end
    return query.new_raw(arg, page_size), nil
  end
  -- MERGE has no row-preview model. Preserve the original statement behind
  -- whole-statement confirmation, consistently with mutating WITH statements.
  if upper == "MERGE" and (adapter_kind == "postgresql"
      or adapter_kind == "duckdb" or adapter_kind == "sqlserver") then
    local tokens = tokenize_select(arg, adapter_kind, true)
    if not tokens then return nil, "Could not safely classify this MERGE statement" end
    local target = tokens[2]
    if target and (target.upper == "INTO" or (adapter_kind == "sqlserver"
        and (target.kind == "ident" or target.kind == "@"))) then
      return nil, nil, nil, arg
    end
  end
  -- REPLACE INTO (MySQL/SQLite): route through mutation preview like INSERT
  if upper == "REPLACE" then
    return nil, nil, nil, arg
  end
  -- Destructive statements: execute directly, don't wrap in SELECT
  if upper == "UPDATE" or upper == "DELETE" or upper == "INSERT"
    or upper == "ALTER" or upper == "DROP" or upper == "CREATE"
    or upper == "BEGIN" or upper == "START" or upper == "COMMIT" or upper == "ROLLBACK" then
    return nil, nil, nil, arg  -- 4th return = mutation SQL
  end
  -- Otherwise treat as table name
  return query.new_table(arg, page_size), arg
end

-- ── file write-back ───────────────────────────────────────────────────────
-- Applies staged changes to a local file by creating a temp table, mutating it,
-- then COPY TO-ing back to the original path. file_path must be a local path.
local function do_apply_file_writeback(bufnr, session)
  local is_current = require("dadbod-grip.write").capture_owner(bufnr, session)
  local st = session.state
  local file_path = session.file_path
  local fmt = filetypes.write_format(file_path)
  if not fmt then
    vim.notify("Write mode does not support this file format", vim.log.levels.ERROR)
    return
  end

  local updates = data.get_updates(st)
  local inserts = data.get_inserts(st)
  local deletes = data.get_deletes(st)
  local total = #updates + #inserts + #deletes

  if total == 0 then
    vim.notify("No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Destructive-action confirm
  local short = vim.fn.fnamemodify(file_path, ":t")
  if not ui.confirm("Overwrite " .. short .. " (" .. total .. " change(s))? (y/N): ") then
    vim.notify("Write-back cancelled", vim.log.levels.INFO)
    return
  end

  local safe_path = esc(file_path)
  local stmts = {}

  -- 1. Create temp table with synthetic row-number PK
  table.insert(stmts,
    string.format("CREATE TEMP TABLE _grip_w AS SELECT ROW_NUMBER() OVER () AS _grip_rowid, * FROM '%s'", safe_path)
  )

  -- 2. Apply deletes (by row index)
  for _, del in ipairs(deletes) do
    table.insert(stmts, string.format("DELETE FROM _grip_w WHERE _grip_rowid = %d", del.row_idx))
  end

  -- 3. Apply updates (by row index)
  for _, upd in ipairs(updates) do
    local set_parts = {}
    for col, val in pairs(upd.changes) do
      local qval = (val == nil or val == data.NULL_SENTINEL) and "NULL"
                   or sql.quote_value(tostring(val))
      table.insert(set_parts, sql.quote_ident(col) .. " = " .. qval)
    end
    if #set_parts > 0 then
      table.insert(stmts, string.format(
        "UPDATE _grip_w SET %s WHERE _grip_rowid = %d",
        table.concat(set_parts, ", "), upd.row_idx
      ))
    end
  end

  -- 4. Apply inserts (no rowid needed: appended at end)
  for _, ins in ipairs(inserts) do
    table.insert(stmts, sql.build_insert("_grip_w", ins.values, ins.columns))
  end

  -- 5. Copy back to original file
  local copy_extra = fmt == "CSV" and ", HEADER TRUE" or ""
  table.insert(stmts, string.format(
    "COPY (SELECT * EXCLUDE (_grip_rowid) FROM _grip_w ORDER BY _grip_rowid) TO '%s' (FORMAT %s, OVERWRITE_OR_IGNORE TRUE%s)",
    safe_path, fmt, copy_extra
  ))

  -- 6. Drop temp table
  table.insert(stmts, "DROP TABLE _grip_w")

  local full_sql = table.concat(stmts, ";\n") .. ";"
  local written, err, ms, unknown = require("dadbod-grip.write").execute(full_sql, "duckdb::memory:", short)

  if err then
    local title = unknown and "Write outcome unknown" or "Write-back failed"
    local err_lines = { "✗ " .. title, "" }
    for line in err:gmatch("[^\n]+") do table.insert(err_lines, "  " .. line) end
    table.insert(err_lines, "")
    table.insert(err_lines, "  Your staged changes are preserved.")
    editor.show_error(title, err_lines)
    return
  end

  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify(
    "Written " .. table.concat(parts, ", ") .. " to " .. short .. " (" .. ms .. "ms)",
    vim.log.levels.INFO
  )

  local history = require("dadbod-grip.history")
  history.record({ sql = full_sql, url = "duckdb::memory:", table_name = file_path, type = "writeback", elapsed_ms = ms })

  if is_current() then
    session.on_refresh(bufnr, { write_elapsed_ms = ms, write_engine_timing = written and written.engine_timing,
      is_current = is_current })
  end
end

-- ── apply staged changes ──────────────────────────────────────────────────
local function do_apply(bufnr, url)
  local session = view._sessions[bufnr]
  if not session then return end
  local is_current = require("dadbod-grip.write").capture_owner(bufnr, session)

  -- File write-back path: session is a local file opened in write mode
  if session.write_mode and session.file_path
      and not session.file_path:match("^https?://") then
    do_apply_file_writeback(bufnr, session)
    return
  end

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
  local txn_sql = sql.wrap_transaction(stmts, require("dadbod-grip.adapters").kind(url))
  local written, err, apply_ms, unknown = require("dadbod-grip.write").execute(txn_sql, url, st.table_name)

  if err then
    -- Rollback guarantees differ between engines and statement types.
    local title = unknown and "Write outcome unknown" or "Apply failed"
    local err_lines = { "✗ " .. title .. " (" .. total .. " statement(s))", "" }
    for chunk in (err .. "\n"):gmatch("([^\n]+)\n?") do
      if chunk ~= "" then table.insert(err_lines, "  " .. chunk) end
    end
    table.insert(err_lines, "")
    table.insert(err_lines, "  Your changes are preserved. Fix the value or press u to undo.")
    editor.show_error(title, err_lines)
    return
  end

  -- Report the captured target even if input navigated elsewhere during the write.
  local parts = {}
  if #updates > 0 then table.insert(parts, #updates .. " update(s)") end
  if #deletes > 0 then table.insert(parts, #deletes .. " delete(s)") end
  if #inserts > 0 then table.insert(parts, #inserts .. " insert(s)") end
  vim.notify("Applied " .. table.concat(parts, ", ") .. " to " .. (st.table_name or "result"), vim.log.levels.INFO)

  local history = require("dadbod-grip.history")
  history.record({ sql = txn_sql, url = url, table_name = st.table_name, type = "dml", elapsed_ms = apply_ms })

  if not is_current() then return end

  -- Success: compute reverse SQL for transaction undo before clearing staging
  local reverse_stmts = {}
  local col_idx = {}
  for i, col in ipairs(st.columns) do col_idx[col] = i end

  -- Reverse of DELETE = INSERT with full original row data
  for _, del in ipairs(deletes) do
    local row_values = {}
    for _, col in ipairs(st.columns) do
      row_values[col] = data.from_csv_raw(st.rows[del.row_idx][col_idx[col]])
    end
    table.insert(reverse_stmts, sql.build_insert(st.table_name, row_values, st.columns))
  end

  -- Reverse of UPDATE = UPDATE with original pre-change values
  for _, upd in ipairs(updates) do
    local orig_values = {}
    for col, _ in pairs(upd.changes) do
      orig_values[col] = data.from_csv_raw(st.rows[upd.row_idx][col_idx[col]])
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

  -- Auto-assigned-PK lookup above can also yield to navigation/input.
  if not is_current() then return end

  -- Store in transaction undo stack
  if #reverse_stmts > 0 then
    session._txn_undo_stack = session._txn_undo_stack or {}
    table.insert(session._txn_undo_stack, reverse_stmts)
    if #session._txn_undo_stack > 10 then table.remove(session._txn_undo_stack, 1) end
  end

  -- Clear local staging undo stack (stale pre-apply states)
  session._undo_stack = {}

  session.on_refresh(bufnr, { write_elapsed_ms = apply_ms, write_engine_timing = written and written.engine_timing,
    is_current = is_current })
end

-- ── refresh ───────────────────────────────────────────────────────────────

--- Spinner label for a grid reload: the bare table name (no schema prefix),
--- one line, capped so a long name cannot outgrow the float.
local function spinner_label(table_name)
  local label = table_name and (table_name:match("[^.]+$") or table_name) or "result"
  return ((label:match("^([^\n]+)") or "query"):sub(1, 50))
end

--- Every db round-trip one refresh needs. Split out of do_refresh so a caller
--- that has its own db work to do first (on_requery runs a COUNT) can put the
--- whole batch inside one ui.blocking float instead of flashing two.
---
--- Returns ONE table, never a bare `nil, err`: ui.blocking() forwards its fn's
--- returns through table.unpack, which drops everything after a leading nil.
--- @return table { result: table|nil, err: string|nil, elapsed_ms: number }
local function fetch_refresh(url, query_sql, table_name, is_raw)
  local t0 = vim.uv.hrtime()
  local result, err = db.query(query_sql, url, { engine_timing = OPTS.engine_timing })
  local elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
  if err then return { err = err, elapsed_ms = elapsed_ms } end

  -- Some clients omit headers for zero rows. Schema fallback can prove the
  -- columns of our full-table SELECT *, but not a raw query's projection.
  local unproven_projection = is_raw and #result.columns == 0

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
  result.readonly = db.is_readonly(url) or unproven_projection == true
  if table_name and not result.readonly then
    local pks, pk_err = db.get_primary_keys(table_name, url)
    result.primary_keys = (pk_err == nil) and pks or {}
  else
    result.primary_keys = {}
  end

  result.table_name = table_name
  result.url = url
  result.sql = query_sql
  return { result = result, elapsed_ms = elapsed_ms }
end

--- Render what fetch_refresh returned. Kept outside the spinner float so the
--- grid repaints after it is torn down, the same order init.open() uses.
local function apply_refresh(bufnr, fetched, owner, generation, query_update, write_result)
  local session = view._sessions[bufnr]
  if session ~= owner or not session or not vim.api.nvim_buf_is_valid(bufnr)
      or session._refresh_generation ~= generation then return end
  if write_result and write_result.is_current and not write_result.is_current() then return end
  if not fetched or not fetched.result then
    vim.notify("Grip: query failed: " .. tostring((fetched and fetched.err) or "unknown error"),
      vim.log.levels.ERROR)
    return
  end
  local new_state = data.new(fetched.result)
  -- Publish identity/count/rows/time together only after a successful SELECT.
  if query_update then
    session.query_spec = query_update.spec
    session.query_sql = query_update.sql
    session.total_rows = query_update.total_rows
  end
  session.elapsed_ms = fetched.elapsed_ms
  session.last_action = "query"
  session._query_times[new_state.rows] = fetched.elapsed_ms
  session._query_engine_times[new_state.rows] = fetched.result.engine_timing
  if write_result then
    session._write_times[new_state.rows] = write_result.write_elapsed_ms
    session._write_engine_times[new_state.rows] = write_result.write_engine_timing
  end
  view.render(bufnr, new_state)
end

local function begin_refresh(bufnr)
  local session = view._sessions[bufnr]
  if not session or not vim.api.nvim_buf_is_valid(bufnr) then return end
  session._refresh_generation = (session._refresh_generation or 0) + 1
  return session, session._refresh_generation
end

local function do_refresh(bufnr, url, query_sql, table_name, write_result)
  local owner, generation = begin_refresh(bufnr)
  if not owner then return end
  if write_result then
    write_result.is_current = require("dadbod-grip.write").capture_owner(bufnr, owner)
  end
  local fetched = ui.blocking("  querying " .. spinner_label(table_name) .. "...", function()
    return fetch_refresh(url, query_sql, table_name, owner.query_spec and owner.query_spec.is_raw)
  end)
  apply_refresh(bufnr, fetched, owner, generation, nil, write_result)
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
  local edited_row_idx = cell.row_idx
  local edited_col    = cell.col_name

  -- Detect JSON only for editor options. The saved text must start as stored:
  -- decoding/re-encoding can round numbers and change keys or whitespace.
  local initial_val = cell.value
  local is_json = false
  if initial_val and #initial_val > 1 then
    local json_ok, json_decoded = pcall(vim.fn.json_decode, initial_val)
    is_json = json_ok and type(json_decoded) == "table"
  end

  -- JSON cells get a taller/wider float with JSON syntax highlighting
  local edit_opts = {}
  if is_json then
    edit_opts.max_h = 25
    edit_opts.max_w = 110
    edit_opts.ft    = "json"
  end

  -- Enum hint: columns with few distinct values show them as virtual text
  -- in the editor (fetched once per session, cached on session.enum_cache).
  edit_opts.enum_values = view.enum_hint_values(session, cell.col_name)

  -- Capture cursor before the float opens. The editor.open/close cycle (stopinsert
  -- + window switch) shifts the grid cursor by 1, accumulating on every Enter.
  -- Pre-capturing gives us the ground truth for restoration in all three cases:
  -- cancel, no-mutation save, and valid mutation (where we advance the LINE only).
  local _pre_w = vim.fn.bufwinid(bufnr)
  local _pre_cursor = _pre_w ~= -1 and vim.api.nvim_win_get_cursor(_pre_w) or nil

  -- Restore cursor to target position, resisting plugin WinEnter chains via SafeState.
  local function _restore(target)
    if not target then return end
    local w = vim.fn.bufwinid(bufnr)
    if w ~= -1 then pcall(vim.api.nvim_win_set_cursor, w, target) end
    local tl, tc = target[1], target[2]
    vim.api.nvim_create_autocmd("SafeState", {
      group = _ag, once = true,
      callback = function()
        local w2 = vim.fn.bufwinid(bufnr)
        if w2 ~= -1 then pcall(vim.api.nvim_win_set_cursor, w2, { tl, tc }) end
      end,
    })
  end

  editor.open(prompt, initial_val, function(new_val)
    if new_val == nil then  -- cancelled
      _restore(_pre_cursor)
      return
    end

    -- Skip staging if nothing actually changed
    local was_null = cell.value == nil
    local now_null = new_val == editor.NULL_VALUE
    if now_null and was_null then
      _restore(_pre_cursor)
      return
    end
    if not now_null and not was_null and new_val == initial_val then
      _restore(_pre_cursor)
      return
    end

    -- Valid mutation: stage and advance to next row (spreadsheet style).
    local actual_val = editor.resolve_null(new_val)
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, actual_val)
    view.apply_edit(bufnr, new_state)

    -- Use _next_edit_cursor for the target LINE, but _pre_cursor[2] for the COLUMN
    -- so the column never drifts regardless of col_bp.start vs actual cursor offset.
    local s = view._sessions[bufnr]
    local next_pos = s and s._render and M._next_edit_cursor(s._render, edited_row_idx, edited_col)
    if next_pos and _pre_cursor then
      _restore({ next_pos.line, _pre_cursor[2] })
    else
      _restore(_pre_cursor)
    end
  end, edit_opts)
end

-- ── mutation preview ──────────────────────────────────────────────────────
local function preview_columns(names, kind)
  local columns, exact = {}, kind == "sqlserver" and {} or nil
  for _, column in ipairs(names) do
    local key = kind == "postgresql" and column or column:lower()
    -- SQL Server may distinguish Value and value under its catalog collation.
    -- Use exact metadata first; folded spelling is usable only when unique.
    if exact then
      exact[column] = column
      columns[key] = columns[key] == nil and column or false
    else
      columns[key] = column
    end
  end
  return columns, exact
end

-- Shows matching or current rows before executing UPDATE/DELETE/INSERT/REPLACE.
function M._mutation_preview(mutation_sql, url, stmt_type, caller_opts, execution_sql)
  local kind = adapters.kind(db.resolved_url(url))
  local parsed, parse_err = require("dadbod-grip.mutation").parse(
    mutation_sql, tokenize_select(mutation_sql, kind, true), kind, stmt_type)
  if not parsed then
    vim.notify("Could not preview " .. stmt_type .. ": " .. (parse_err or "unsupported SQL syntax"), vim.log.levels.ERROR)
    return
  end
  local inserting = stmt_type == "INSERT" or stmt_type == "REPLACE"
  local table_name = parsed.table_name
  local preview_sql = "SELECT * FROM " .. parsed.source_sql
  if parsed.where and parsed.where ~= "" then
    -- T-SQL does not require statement separators. Keep its balanced predicate
    -- inside one expression even if an unrecognized command follows it.
    local predicate = kind == "sqlserver" and ("(" .. parsed.where .. ")") or parsed.where
    preview_sql = preview_sql .. " WHERE " .. predicate
  end

  local preview = ui.blocking("  previewing " .. spinner_label(table_name) .. "...", function()
    -- Run preview query
    local result, err = db.query(preview_sql, url)
    if not result then
      return { err = err or "query error" }
    end

    -- Fetch columns from schema if needed (empty result)
    if #result.columns == 0 then
      local col_info = db.get_column_info(table_name, url)
      if col_info then
        for _, ci in ipairs(col_info) do table.insert(result.columns, ci.column_name) end
      end
    end

    -- Fetch PKs
    result.readonly = db.is_readonly(url)
    local pks = result.readonly and {} or (db.get_primary_keys(table_name, url) or {})
    result.primary_keys = pks
    result.table_name = table_name
    result.url = url
    result.sql = preview_sql

    local state = data.new(result)
    local row_count = #result.rows

    -- Stage only parsed literal assignments. Expressions are executed by the
    -- database on confirmation; their text is not a predicted cell value.
    if stmt_type == "UPDATE" and row_count > 0 then
      local columns, exact = preview_columns(state.columns, kind)
      local assignments = parsed.assignments
      if exact then
        -- Resolve names before discarding repeated or unknown assignments:
        -- differently-cased spellings may refer to one column or two.
        local latest = {}
        for _, assignment in ipairs(assignments) do
          local column = exact[assignment.column] or columns[assignment.column:lower()]
          if column then
            latest[column] = assignment.known ~= false and assignment or nil
          end
        end
        assignments = {}
        for _, assignment in pairs(latest) do assignments[#assignments + 1] = assignment end
      end
      for _, assignment in ipairs(assignments) do
        local key = kind == "postgresql" and assignment.column or assignment.column:lower()
        local column = (exact and exact[assignment.column]) or columns[key]
        if column then
          -- This state has not been published yet: fill it once instead of
          -- copying every previously staged row for each cell. SQL empty
          -- strings stay distinct from NULL (interactive edits normalize them).
          for row_idx = 1, #state.rows do
            local changes = state.changes[row_idx]
            if not changes then changes = {}; state.changes[row_idx] = changes end
            changes[column] = assignment.value == nil and data.NULL_SENTINEL or assignment.value
          end
        end
      end
    end

    -- For DELETE: mark all rows as deleted so they show red
    if stmt_type == "DELETE" and row_count > 0 then
      for row_idx = 1, #state.rows do
        state.deleted[row_idx] = true
      end
    end

    -- Stage complete literal tuples only. Conflict handling, defaults and
    -- computed rows show current state; confirmation still runs original SQL.
    if inserting then
      local insert_rows = {}
      local columns, exact = preview_columns(result.columns, kind)
      local fields = parsed.insert_columns or result.columns
      for _, tuple in ipairs(parsed.insert_values) do
        if tuple.n ~= #fields then parsed.current_state = true; break end
        local row, seen = {}, {}
        for idx, field in ipairs(fields) do
          local key = kind == "postgresql" and field or field:lower()
          local column = (exact and exact[field]) or columns[key]
          if not column or seen[column] then parsed.current_state = true; break end
          seen[column] = true
          row[column] = tuple[idx] == nil and data.NULL_SENTINEL or tuple[idx]
        end
        insert_rows[#insert_rows + 1] = row
      end
      if parsed.current_state then
        row_count = nil
      else
        state = data.insert_rows_with_values(state, #result.rows, insert_rows)
        row_count = #insert_rows
      end
    end
    return { state = state, row_count = row_count }
  end)
  if preview.err then
    vim.notify("Preview failed: " .. preview.err, vim.log.levels.ERROR)
    return
  end
  local state, row_count = preview.state, preview.row_count

  -- Open grid with pending_mutation metadata
  local reuse_win = caller_opts and caller_opts.reuse_win
  local view_opts = {
    max_col_width = OPTS.max_col_width,
    pending_mutation = {
      sql = execution_sql or mutation_sql,
      type = stmt_type,
      table_name = table_name,
      row_count = row_count,
      current_state = parsed.current_state or nil,
      -- MySQL ROW_COUNT() after COMMIT counts the commit, not the mutation.
      affected_count_unavailable = execution_sql ~= nil and kind == "mysql" or nil,
    },
  }
  if reuse_win then view_opts.reuse_win = reuse_win end

  local bufnr = view.open(state, url, preview_sql, view_opts)

  -- Store mutation info on session and re-render to pick up title/hints
  local session = view._sessions[bufnr]
  if session then
    session.pending_mutation = view_opts.pending_mutation
    session.query_spec = query.new_raw(preview_sql, OPTS.limit)
    if inserting then
      if row_count then
        session._mutation_title = string.format("%s into %s (%d new row%s)",
          stmt_type, table_name, row_count, row_count == 1 and "" or "s")
      else
        session._mutation_title = string.format("%s into %s (current state)", stmt_type, table_name)
      end
    else
      session._mutation_title = string.format("%s %s (%d row%s)",
        stmt_type, table_name, row_count, row_count == 1 and "" or "s")
    end

    -- Wire refresh callback so grid updates after mutation executes
    view.set_callbacks(bufnr, {
      on_refresh = function(bid, write_result)
        do_refresh(bid, url, preview_sql, table_name, write_result)
      end,
    })

    view.render(bufnr, session.state)  -- re-render with mutation title + hints
  end
end

-- ── open ──────────────────────────────────────────────────────────────────
---Open a table or raw SQL query in a grip grid.
---@param arg string  Table name or SQL query
---@param url? string Connection URL (uses active connection if nil)
---@param opts? table Additional options (write, watch_ms)
function M.open(arg, url, opts)
  -- Resolve connection URL
  local conn = url
  if not conn or conn == "" then
    conn = vim.b.db
    if not conn or conn == "" then conn = vim.g.db end
  end

  -- Resolve query spec (must happen before connection check for file-as-table).
  -- Pass the adapter kind when available so projection parsing can stay
  -- conservative around dialect-specific identifier quoting.
  local adapter_kind = adapters.kind(db.resolved_url(conn))
  local spec, table_name_arg, file_path, mutation_sql = resolve_query(arg, OPTS.limit, adapter_kind)

  -- Handle destructive statements (UPDATE/DELETE/INSERT/DDL)
  if mutation_sql then
    local exec_conn = url or conn or vim.b.db or vim.g.db
    if not exec_conn or exec_conn == "" then
      vim.notify("Grip: no database connection", vim.log.levels.WARN)
      return
    end
    local stmt_type = statement_type(mutation_sql, adapter_kind) or "SQL"

    -- Preview one committed mutation, but execute the exact transaction text.
    -- Never remove ROLLBACK or silently execute multiple hidden statements.
    if stmt_type == "BEGIN" or stmt_type == "START" then
      local tokens = tokenize_select(mutation_sql, adapter_kind, true)
      local last = tokens and #tokens or 0
      if last > 0 and tokens[last].kind == ";" then last = last - 1 end
      local first_end
      for idx, token in ipairs(tokens or {}) do
        if token.kind == ";" then first_end = idx; break end
      end
      local begin_pos = 2
      if stmt_type == "BEGIN" and tokens and tokens[begin_pos]
          and ({ DEFERRED = true, IMMEDIATE = true, EXCLUSIVE = true })[tokens[begin_pos].upper] then
        begin_pos = begin_pos + 1
      end
      if tokens and tokens[begin_pos]
          and (tokens[begin_pos].upper == "TRANSACTION" or tokens[begin_pos].upper == "WORK") then
        begin_pos = begin_pos + 1
      elseif stmt_type == "START" then
        begin_pos = -1
      end
      local commit_pos = last
      if tokens and tokens[commit_pos]
          and (tokens[commit_pos].upper == "TRANSACTION" or tokens[commit_pos].upper == "WORK") then
        commit_pos = commit_pos - 1
      end
      if not first_end or first_end ~= begin_pos or commit_pos <= first_end + 2
          or (tokens[commit_pos].upper ~= "COMMIT" and tokens[commit_pos].upper ~= "END")
          or tokens[commit_pos - 1].kind ~= ";" then
        vim.notify("Could not preview transaction: use one mutation followed by COMMIT",
          vim.log.levels.ERROR)
        return
      end
      local inner_type = tokens[first_end + 1].upper
      if inner_type ~= "UPDATE" and inner_type ~= "DELETE"
          and inner_type ~= "INSERT" and inner_type ~= "REPLACE" then
        vim.notify("Could not preview transaction: expected one mutation", vim.log.levels.ERROR)
        return
      end
      local inner = mutation_sql:sub(tokens[first_end + 1].start, tokens[commit_pos - 1].finish)
      M._mutation_preview(inner, exec_conn, inner_type, opts, mutation_sql)
      return
    end

    -- For UPDATE/DELETE/INSERT/REPLACE: show preview grid with a:execute / U:cancel
    if stmt_type == "UPDATE" or stmt_type == "DELETE" or stmt_type == "INSERT"
        or stmt_type == "REPLACE" then
      M._mutation_preview(mutation_sql, exec_conn, stmt_type, opts)
      return
    end

    -- For DDL (ALTER/DROP/CREATE/etc.): confirm then execute
    local label = ("Execute " .. stmt_type .. "?")
    local choice = vim.fn.confirm(label .. "\n\n" .. mutation_sql:sub(1, 200), "&Execute\n&Cancel", 2)
    if choice ~= 1 then return end

    local _, exec_err, ms = require("dadbod-grip.write").execute(mutation_sql, exec_conn, stmt_type)
    if exec_err then
      vim.notify("Grip: " .. exec_err, vim.log.levels.ERROR)
    else
      vim.notify(string.format("%s executed (%dms)", stmt_type, ms), vim.log.levels.INFO)
      local history = require("dadbod-grip.history")
      history.record({ sql = mutation_sql, url = exec_conn, type = stmt_type:lower(), elapsed_ms = ms })
      -- Refresh the grids the user can actually see. Iterating _sessions and
      -- breaking on the first hit picked an arbitrary grid (pairs order), which
      -- could leave the visible one stale while refreshing a hidden buffer.
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr_r = vim.api.nvim_win_get_buf(wid)
        local session_r = view._sessions[bufnr_r]
        if session_r and session_r.on_refresh then session_r.on_refresh(bufnr_r) end
      end
    end
    return
  end

  if not spec then
    vim.notify("Grip: " .. (table_name_arg or "unknown error"), vim.log.levels.WARN)
    return
  end

  -- File-as-table: use the active DuckDB connection so ATTACHed databases
  -- remain accessible. Fall back to duckdb::memory: when no DuckDB session exists.
  if file_path then
    -- The scheme test needs the resolved URL (a whole-URL template hides it),
    -- but `conn` stays the template: everything downstream of here expands via
    -- db.resolve(), and history/view must not record the expansion.
    local active = vim.g.db
    local resolved = db.resolved_url(active)
    conn = (resolved and resolved:match("^duckdb:")) and active or "duckdb::memory:"
    if opts and opts.write and not filetypes.write_format(file_path) then
      vim.notify("Write mode does not support this file format; opened read-only",
        vim.log.levels.WARN)
      opts = vim.tbl_extend("force", {}, opts, { write = false })
    end
  end

  if not conn or conn == "" then
    vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
    return
  end

  local query_sql = query.build_sql(spec)

  -- Run query with loading indicator + timing
  local short_label = file_path and vim.fn.fnamemodify(file_path, ":t")
      or table_name_arg and (table_name_arg:match("[^.]+$") or table_name_arg)
      or "result"
  short_label = (short_label:match("^([^\n]+)") or "query"):sub(1, 50)
  -- Opening a table is three round-trips: the SELECT, the primary keys, and the
  -- pagination COUNT. All three run under one spinner. With only the SELECT
  -- covered, the float vanished and the editor then froze through the other two
  -- before the grid ever appeared -- which reads as the plugin hanging.
  local fetched, total_rows
  ui.blocking("  querying " .. short_label .. "...", function()
    fetched = fetch_refresh(conn, query_sql, table_name_arg, spec.is_raw)
    if not fetched.result then return end
    local count_result = db.query(query.build_count_sql(spec), conn)
    if count_result and count_result.rows[1] then
      total_rows = tonumber(count_result.rows[1][1]) or 0
    end
  end)

  local result = fetched.result
  if opts and opts.write_is_current and not opts.write_is_current() then return end
  if not result then
    vim.notify("Grip: " .. (fetched.err or "query failed"), vim.log.levels.ERROR)
    return
  end
  local elapsed_ms = fetched.elapsed_ms
  result.elapsed_ms = elapsed_ms

  local history = require("dadbod-grip.history")
  history.record({ sql = query_sql, url = conn, table_name = table_name_arg, type = "query", elapsed_ms = elapsed_ms })

  local state = data.new(result)

  -- Open the view
  -- query_spec/total_rows go in up front so the first render already draws the
  -- page counter; without them the grid had to be rendered a second time.
  local view_opts = vim.tbl_extend("force", {
    max_col_width = OPTS.max_col_width,
    elapsed_ms    = elapsed_ms,
    engine_timing = result.engine_timing,
    query_spec    = spec,
    total_rows    = total_rows,
  }, opts or {})
  -- The guard only owns this reload; do not retain the old session on the new one.
  view_opts.write_is_current = nil
  local bufnr = view.open(state, conn, query_sql, view_opts)

  -- Auto-sync query pad with the current grid query (passive background update).
  -- Use the clean original SQL (base_sql or table name) so the pad shows what the
  -- user wrote, not the internal pagination wrapper (SELECT * FROM (...) AS _grip ...).
  -- Skip when the query originated from the pad itself (from_pad=true): the SQL is
  -- already there and we must not clobber the user's buffer.
  vim.schedule(function()
    if opts and opts.from_pad then return end
    require("dadbod-grip.query_pad").sync_query(query.clean_sql(spec))
  end)

  -- Store query spec and run initial count for pagination
  local session = view._sessions[bufnr]
  if session then
    -- For file-as-table, store the file path so the schema sidebar can show columns
    if file_path then session.file_path = file_path end
    -- Both were handed to view.open() above and are already on the session; the
    -- assignments stay so a caller that reuses an existing buffer still gets them.
    session.query_spec = spec
    session.total_rows = total_rows
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
    on_refresh = function(bid, write_result)
      local s = view._sessions[bid]
      if not s then return end
      -- Read current table name from session state (may have been updated by rename)
      local current_table = (s.state and s.state.table_name) or table_name_arg
      local sql_str = s.query_spec and query.build_sql(s.query_spec) or query_sql
      do_refresh(bid, conn, sql_str, current_table, write_result)
    end,
    on_requery = function(bid, new_spec)
      local s, generation = begin_refresh(bid)
      if not s then return end

      -- COUNT and SELECT share a spinner, but pending metadata must not
      -- replace the displayed result's identity if SELECT fails/interruption
      -- returns an error, or a newer refresh completes while this one waits.
      local new_sql, page_fetch
      local pending_total = s.total_rows
      ui.blocking("  querying " .. spinner_label(table_name_arg) .. "...", function()
        local count_sql = query.build_count_sql(new_spec)
        local count_result = db.query(count_sql, conn)
        if count_result and count_result.rows[1] then
          pending_total = tonumber(count_result.rows[1][1]) or 0
        end
        if pending_total then
          local total_pages = math.max(1, math.ceil(pending_total / new_spec.page_size))
          if new_spec.page > total_pages then new_spec = query.set_page(new_spec, total_pages) end
        end
        new_sql = query.build_sql(new_spec)
        page_fetch = fetch_refresh(conn, new_sql, table_name_arg, new_spec.is_raw)
      end)
      apply_refresh(bid, page_fetch, s, generation,
        { spec = new_spec, sql = new_sql, total_rows = pending_total })
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

  -- Switch to a specific view if requested via opts.view (view name string)
  if opts and type(opts.view) == "string" then
    local view_name = opts.view
    vim.schedule(function()
      view.switch_view(bufnr, view_name)
    end)
  end
end

-- ── open_smart ───────────────────────────────────────────────────────────
-- DBUI-aware smart open: detects context from current buffer and opens
-- the appropriate table in the grid. Works from SQL query buffers,
-- dbout result buffers, and normal buffers (word under cursor).
---Open the table under cursor, adapting to the current buffer context.
function M.open_smart()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Case 1: DBUI SQL query buffer: has b:dbui_table_name + b:db (string URL)
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

  -- Case 2: dbout result buffer: b:db is a dict with db_url
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

  -- Case 3: No DBUI/dbout context: show table picker
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

-- ── welcome screen ────────────────────────────────────────────────────────
---Open the welcome screen (Chonk mascot + feature hints).
---Called automatically when :Grip is invoked with no arguments.
function M.open_welcome()
  -- Find existing welcome buffer
  local welcome_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_get_name(b) == "grip://welcome" then
      welcome_buf = b
      break
    end
  end

  -- If already visible in any window, just focus it: reuse, don't replace
  if welcome_buf then
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(winid) == welcome_buf then
        vim.api.nvim_set_current_win(winid)
        return
      end
    end
  end

  -- Not visible: if called from the sidebar, find a non-sidebar window to place
  -- the welcome screen in. Query pad and grid replace their own window.
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_ft  = vim.bo[cur_buf].filetype
  local is_special = cur_ft == "grip_schema"
  if is_special then
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local wbuf  = vim.api.nvim_win_get_buf(winid)
      local wname = vim.api.nvim_buf_get_name(wbuf)
      local wft   = vim.bo[wbuf].filetype
      if wft ~= "grip_schema"
          and not (wname:match("^grip://") and wname ~= "grip://welcome") then
        vim.api.nvim_set_current_win(winid)
        break
      end
    end
  end

  if not welcome_buf then
    welcome_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(welcome_buf, "grip://welcome")
  end

  vim.bo[welcome_buf].buftype = "nofile"
  vim.bo[welcome_buf].filetype = "grip-welcome"
  vim.bo[welcome_buf].swapfile = false
  vim.api.nvim_win_set_buf(0, welcome_buf)
  local km = require("dadbod-grip.keymaps")
  local rows = require("dadbod-grip.welcome").render(welcome_buf)
  local first
  for row in pairs(rows) do first = math.min(first or row, row) end
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.foldcolumn = "0"
  vim.wo.cursorline = true
  vim.api.nvim_win_set_cursor(0, { first, 2 })
  vim.fn.winrestview({ topline = 1, leftcol = 0 })

  -- Keymaps
  local function wmap(action, fn, desc)
    km.bind("welcome", welcome_buf, action, "n", fn, { nowait = true, desc = desc })
  end
  require("dadbod-grip.keymaps").bind("welcome", welcome_buf, "zoom", "n", function()
    require("dadbod-grip.zoom").toggle()
  end)
  local function do_connect()
    require("dadbod-grip.connections").pick()
  end
  local function cur_conn()
    local c = vim.g.db
    if type(c) ~= "string" or c == "" then c = os.getenv("DATABASE_URL") end
    return (c and c ~= "") and c or nil
  end
  wmap("welcome_close",     function() pcall(vim.api.nvim_buf_delete, welcome_buf, { force = true }) end, "Close welcome")
  wmap("welcome_close_esc", function() pcall(vim.api.nvim_buf_delete, welcome_buf, { force = true }) end, "Close welcome")
  wmap("welcome_connect",    do_connect, "Connect to database")
  wmap("connections",    do_connect, "Connect to database")
  wmap("connections_alt", do_connect, "Connect to database")
  local function do_tables()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.picker").pick_table(conn, function(t) M.open(t, conn) end)
  end
  wmap("table_picker_go", do_tables, "Open table picker")
  wmap("schema_browser",    function()
    require("dadbod-grip.schema").toggle(cur_conn())
  end, "Schema browser")
  wmap("er_diagram", function()
    local conn = cur_conn()
    if not conn then
      vim.notify("ER Diagram: no database connection", vim.log.levels.WARN)
      return
    end
    require("dadbod-grip.er_diagram").toggle(conn)
  end, "ER diagram")
  wmap("help",     function() view.show_help() end, "Full keymap help")
  wmap("ai",     function()
    local ai = require("dadbod-grip.ai")
    if not ai.is_enabled() then
      vim.notify("AI is disabled. Enable it in setup({ ai = { ... } })", vim.log.levels.INFO)
      return
    end
    ai.ask(cur_conn())
  end, "AI SQL assistant")

  -- 1-9: surface navigation from welcome screen
  wmap("tab_1", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.schema").toggle(conn)
  end, "Schema sidebar")
  local function do_query()
    local conn = cur_conn()
    if conn then
      require("dadbod-grip.query_pad").open(conn)
    else
      do_connect()
    end
  end
  wmap("tab_2", do_query, "Query pad")
  wmap("tab_3", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.picker").pick_table(conn, function(t) M.open(t, conn) end)
  end, "Table picker")
  wmap("tab_4", function()
    local conn = cur_conn()
    if not conn then do_connect(); return end
    require("dadbod-grip.er_diagram").toggle(conn)
  end, "ER diagram")
  -- 5-9: pick a table and open it straight into that view. Slot 4 (ER diagram)
  -- is a float, not a grid view, so it is wired separately above.
  for n = 5, 9 do
    local vname = require("dadbod-grip.keymaps").TAB_VIEWS[n]
    wmap("tab_" .. n, function()
      local conn = cur_conn()
      if not conn then do_connect(); return end
      require("dadbod-grip.picker").pick_table(conn, function(t) M.open(t, conn, { view = vname }) end)
    end, vname .. " view")
  end

  local actions = {
    demo = function() vim.cmd("GripStart") end,
    connect = do_connect,
    tables = do_tables,
    query = do_query,
  }
  wmap("welcome_activate", function()
    local action = actions[rows[vim.api.nvim_win_get_cursor(0)[1]]]
    if action then action() end
  end, "Run welcome action")
  local function move_action(direction)
    local ordered = {}
    for row in pairs(rows) do ordered[#ordered + 1] = row end
    table.sort(ordered)
    local current = vim.api.nvim_win_get_cursor(0)[1]
    local target = direction > 0 and ordered[1] or ordered[#ordered]
    for _, row in ipairs(ordered) do
      if direction > 0 and row > current then target = row; break end
      if direction < 0 and row < current then target = row end
    end
    vim.api.nvim_win_set_cursor(0, { target, 2 })
  end
  wmap("welcome_next", function() move_action(1) end, "Next welcome action")
  wmap("welcome_prev", function() move_action(-1) end, "Previous welcome action")

  -- Dev secret: Chonk at the center of the grip vortex
  wmap("welcome_secret", function()
    local secret = {
      "",
      "∿ ∿  dadbod-grip vortex  ∿ ∿",
      "",
      "·   · · · · · · · · · · ·   ·",
      "·   ╭───────────────────╮   ·",
      "·   │ · · · · · · · · · │   ·",
      "·   │  ╭─────────────╮  │   ·",
      "·   │  │    ▄▄▄▄▄    │  │   ·",
      "·   │  │   ▐█████▌   │  │   ·",
      "·   │  │ ▄█████████▄ │  │   ·",
      "·   │  │▐█  ◦   ◦  █▌│  │   ·",
      "·   │  │▐█  ─────  █▌│  │   ·",
      "·   │  │▐███████████▌│  │   ·",
      "·   │  │▐█  D·B·G  █▌│  │   ·",
      "·   │  │▀███████████▀│  │   ·",
      "·   │  │  ▐██▌ ▐██▌  │  │   ·",
      "·   │  │  ████ ████  │  │   ·",
      "·   │  │  ▀▀▀▀ ▀▀▀▀  │  │   ·",
      "·   │  ╰─────────────╯  │   ·",
      "·   │ · · · · · · · · · │   ·",
      "·   ╰───────────────────╯   ·",
      "·   · · · · · · · · · · ·   ·",
      "",
      "   Chonk holds the center.",
      "",
      "q to close",
      "",
    }
    local sbuf = vim.api.nvim_create_buf(false, true)
    -- Center the art as a block: all lines share the same left offset based
    -- on the widest line.  Per-line centering causes shorter lines (like
    -- "q to close") to drift right and misalign with the frame.
    -- · (U+00B7) and ∿ (U+223F) are ambiguous-width; floor of 40 pads for
    -- terminals that render them as 2-wide while ambiwidth=single counts 1.
    local max_lw = 0
    for _, l in ipairs(secret) do
      max_lw = math.max(max_lw, vim.fn.strdisplaywidth(l))
    end
    local sw      = math.max(max_lw, 40)
    local base_pad = math.max(0, math.floor((sw - max_lw) / 2))
    local lines = {}
    for _, l in ipairs(secret) do
      table.insert(lines, string.rep(" ", base_pad) .. l)
    end
    vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
    local sh   = #lines
    local swin = ui.info_float({
      buf    = sbuf,
      width  = sw,
      height = sh,
      zindex = 60,
    })
    vim.bo[sbuf].modifiable = false
    vim.bo[sbuf].buftype    = "nofile"
    local function close_secret()
      if vim.api.nvim_win_is_valid(swin) then
        vim.api.nvim_win_close(swin, true)
      end
    end
    vim.keymap.set("n", "q",     close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", "<Esc>", close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", "<CR>",  close_secret, { buffer = sbuf, silent = true })
    vim.keymap.set("n", ";",     close_secret, { buffer = sbuf, silent = true })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = _ag, buffer = sbuf, once = true,
      callback = function() pcall(vim.api.nvim_win_close, swin, true) end,
    })
  end, "Dev secret")

end

-- ── setup ─────────────────────────────────────────────────────────────────

---@class DadbodGripAIOpts
---@field provider? string   "anthropic"|"openai"|"gemini"|"ollama"|nil (auto-detect)
---@field model? string      Override the default model name
---@field ollama_url? string Ollama base URL (default: http://localhost:11434)

---@class DadbodGripOpts
---@field engine_timing? boolean  Collect opt-in DuckDB profiler latency (default: false)
---@field limit? integer         Rows per page (default: 100)
---@field max_col_width? integer Max display width per column (default: 40)
---@field timeout? integer       Query timeout in ms (default: 10000)
---@field ai? DadbodGripAIOpts   AI SQL generation config
---@field keymaps? table         Key overrides: { action_name = "key" } or { action_name = false }
---@field pinned_max? integer    Max number of pinned results allowed (nil = unlimited)
---@field border? string|table   Float window border style (default: "rounded")
---@field cell_split? string     Cell buffer (gB) split style: "horizontal"|"vertical"
---@field open_sidebar? boolean  Open the schema sidebar on connection (default: true)
---@field show_running_time? boolean Show elapsed time in the loading float (default: true)
---@field show_result_time? boolean Show retained query/action durations (default: true)
---@field show_hints? boolean Show automatic shortcut help (default: true)
---@field highlights? table<string, table> Grip group replacements using nvim_set_hl style attributes

---Setup dadbod-grip with user options.
---@param opts? DadbodGripOpts
function M.setup(opts)
  opts = opts or {}
  -- Deliberately the old table form of vim.validate: the per-argument signature
  -- (vim.validate("name", value, "type")) needs Neovim 0.11, we support 0.10.
  vim.validate({
    limit         = { opts.limit,         "number",  true },
    max_col_width = { opts.max_col_width,  "number",  true },
    timeout       = { opts.timeout,        "number",  true },
    engine_timing = { opts.engine_timing, "boolean", true },
    completion       = { opts.completion,      "boolean", true },
    connections_path = { opts.connections_path, "string",  true },
    picker           = { opts.picker, function(v)
      return v == nil or v == "builtin" or v == "telescope" or v == "snacks"
    end, '"builtin", "telescope", or "snacks"' },
    ai            = { opts.ai,             function(v) return v == nil or type(v) == "table" or v == false end, "table, false, or nil" },
    keymaps       = { opts.keymaps,        "table",   true },
    pinned_max    = { opts.pinned_max,     "number",  true },
    border        = { opts.border, function(v) return v == nil or type(v) == "string" or type(v) == "table" end, "string, table, or nil" },
    cell_split    = { opts.cell_split, function(v)
      return v == nil or v == "horizontal" or v == "vertical"
    end, '"horizontal" or "vertical"' },
    discovery     = { opts.discovery, "boolean", true },
    sticky_header = { opts.sticky_header, "boolean", true },
    open_sidebar  = { opts.open_sidebar,  "boolean", true },
    show_running_time = { opts.show_running_time, "boolean", true },
    show_result_time  = { opts.show_result_time,  "boolean", true },
    show_hints        = { opts.show_hints,        "boolean", true },
    highlights        = { opts.highlights,       "table",   true },
  })
  -- Nested definitions are validated before any live config is changed.
  view.set_highlights(opts.highlights or {})
  OPTS.highlights = vim.deepcopy(opts.highlights or {})
  OPTS.limit        = opts.limit        or 100
  OPTS.max_col_width = opts.max_col_width or 40
  OPTS.timeout      = opts.timeout      or 10000
  if opts.engine_timing ~= nil then OPTS.engine_timing = opts.engine_timing end
  if opts.completion ~= nil then OPTS.completion = opts.completion end
  OPTS.connections_path = opts.connections_path or nil
  OPTS.picker = opts.picker or "builtin"
  if opts.pinned_max ~= nil then OPTS.pinned_max = opts.pinned_max end
  if opts.border ~= nil then OPTS.border = opts.border end
  OPTS.cell_split = opts.cell_split or "horizontal"
  if opts.discovery ~= nil then OPTS.discovery = opts.discovery end
  if opts.sticky_header ~= nil then OPTS.sticky_header = opts.sticky_header end
  OPTS.open_sidebar = opts.open_sidebar ~= false
  if opts.show_running_time ~= nil then OPTS.show_running_time = opts.show_running_time end
  if opts.show_result_time ~= nil then OPTS.show_result_time = opts.show_result_time end
  if opts.show_hints ~= nil then OPTS.show_hints = opts.show_hints end

  -- Keymap overrides: stored at module level for keymaps.get() to read.
  if opts.keymaps then
    M._keymaps = opts.keymaps
  end

  -- AI configuration (optional). Accepts a config table OR false to disable.
  if opts.ai ~= nil then
    require("dadbod-grip.ai").setup(opts.ai)
  end

  -- Register :Grip command
  vim.api.nvim_create_user_command("Grip", function(cmd_opts)
    local arg = vim.trim(cmd_opts.args or "")
    -- Parse --write and --watch[=Ns] flags, stripping them from the query arg
    local grip_opts = {}
    arg = arg:gsub("%s*%-%-write%s*", function() grip_opts.write = true; return " " end)
    arg = arg:gsub("%s*%-%-watch=(%d+)s?%s*", function(n)
      grip_opts.watch_ms = tonumber(n) * 1000
      return " "
    end)
    arg = arg:gsub("%s*%-%-watch%s*", function()
      if not grip_opts.watch_ms then grip_opts.watch_ms = 5000 end
      return " "
    end)
    arg = vim.trim(arg)
    -- No arg: show welcome screen (resolve_query handles <cword> fallback when needed)
    if arg == "" then
      M.open_welcome()
      return
    end
    M.open(arg, nil, next(grip_opts) and grip_opts or nil)
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

    local hist = require("dadbod-grip.history")
    hist.record({ sql = arg, url = conn, type = "explain" })

    -- Parse and render as Query Doctor
    local adapter_type = explain.detect_adapter(conn)
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
      border = ui.border(),
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
      group  = _ag,
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
    local bufnr = vim.api.nvim_get_current_buf()
    if name == "" then
      saved.save_prompt(bufnr)
    else
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      saved.save(name, table.concat(lines, "\n"), vim.b[bufnr].db or vim.g.db)
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
      local content, bound_url = saved.load(name)
      if content then
        local query_pad = require("dadbod-grip.query_pad")
        local url = bound_url or db.get_url()
        query_pad.open(url, { initial_sql = content })
      end
    else
      saved.pick(function(content, _, bound_url)
        local query_pad = require("dadbod-grip.query_pad")
        local url = bound_url or db.get_url()
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
    local tbl, conn = resolve_target(cmd_opts, "GripProfile")
    if not tbl then return end
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
    if deny_if_readonly("GripCreate") then return end
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
    if deny_if_readonly("GripDrop") then return end
    local table_name, url = resolve_target(cmd_opts, "GripDrop", "provide a table name")
    if not table_name then return end
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
    -- Guarded on the URL the ALTER below actually runs against, not on the
    -- ambient one: this command is the only one whose action reads
    -- session.url, and guarding the ambient connection instead let a rename
    -- through against a ro connection whenever the two had drifted apart.
    if deny_if_readonly("GripRename", url) then return end

    local ddl_mod = require("dadbod-grip.ddl")
    if #args >= 2 then
      -- :GripRename old_name new_name
      local old_name, new_name = args[1], args[2]
      local sql_mod = require("dadbod-grip.sql")
      local ddl_sql = string.format('ALTER TABLE %s RENAME COLUMN %s TO %s',
        sql_mod.quote_ident(table_name), sql_mod.quote_ident(old_name), sql_mod.quote_ident(new_name))
      local is_current = require("dadbod-grip.write").capture_owner(bufnr, session)
      local _, err, _, unknown = require("dadbod-grip.write").execute(ddl_sql, url, "rename column")
      if err then
        vim.notify((unknown and "" or "Rename failed: ") .. err, vim.log.levels.ERROR)
      else
        vim.notify("Renamed " .. old_name .. " to " .. new_name, vim.log.levels.INFO)
        if is_current() and session.on_refresh then session.on_refresh(bufnr) end
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
    local table_name, url = resolve_target(cmd_opts, "GripProperties")
    if not table_name then return end
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

  -- :GripAttach [dsn] [alias]: attach external DB to DuckDB session
  vim.api.nvim_create_user_command("GripAttach", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
    local schema_mod = require("dadbod-grip.schema")

    -- url is the active connection as stored (templated: the key its entry
    -- lives under in connections.json); conn_url is the expanded form the
    -- adapter's attachment registry is keyed by. This command bypasses
    -- db.resolve(), so it expands by hand.
    local url = vim.g.db
    local conn_url = connections.expand_url(url)
    if not conn_url or not conn_url:find("^duckdb:") then
      vim.notify("GripAttach: requires a DuckDB connection. Use :GripConnect to switch.", vim.log.levels.WARN)
      return
    end

    local args = vim.split(vim.trim(cmd_opts.args or ""), "%s+")
    local dsn, alias
    if #args >= 2 then
      alias = args[#args]
      dsn = table.concat(args, " ", 1, #args - 1)
    else
      local d = ui.input({ prompt = "Connection (e.g. postgres:dbname=mydb user=me): " })
      if not d then return end
      dsn = d
      local a = ui.input({ prompt = "Alias (used in queries, e.g. pg): " })
      if not a then return end
      alias = a
    end

    -- A hand-typed DSN may reference ${VAR} too; resolve it against the
    -- active connection's env_file and keep the placeholder for persistence.
    local live_dsn, dsn_err = connections.expand_dsn(dsn, url)
    if not live_dsn then
      vim.notify("GripAttach: " .. (dsn_err or "unresolved secrets in DSN"), vim.log.levels.ERROR)
      return
    end
    local err = duckdb_adapter.attach(conn_url, live_dsn, alias, live_dsn ~= dsn and dsn or nil)
    if err then
      vim.notify("GripAttach: " .. err, vim.log.levels.ERROR)
      return
    end
    connections.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
    require("dadbod-grip.completion").invalidate(url)
    schema_mod.refresh(url)
    -- Pre-warm completion cache after manual attach (M.attach no longer does this).
    vim.schedule(function()
      pcall(function() require("dadbod-grip.completion").warm_schema(url) end)
    end)
    vim.notify(string.format("Attached '%s' as %s", dsn, alias), vim.log.levels.INFO)
  end, {
    nargs = "*",
    desc  = "Attach external database to DuckDB session",
  })

  -- :GripDetach [alias]: detach a previously attached database
  vim.api.nvim_create_user_command("GripDetach", function(cmd_opts)
    local connections = require("dadbod-grip.connections")
    local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
    local schema_mod = require("dadbod-grip.schema")

    -- Same template/expanded split as :GripAttach above.
    local url = vim.g.db
    local conn_url = connections.expand_url(url)
    if not conn_url or not conn_url:find("^duckdb:") then
      vim.notify("GripDetach: requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end

    local alias = vim.trim(cmd_opts.args or "")
    if alias == "" then
      local atts = duckdb_adapter.get_attachments(conn_url)
      if #atts == 0 then
        vim.notify("GripDetach: no databases attached.", vim.log.levels.INFO)
        return
      end
      local names = {}
      for _, a in ipairs(atts) do table.insert(names, a.alias) end
      local val = ui.input({ prompt = "Detach alias (" .. table.concat(names, ", ") .. "): " })
      if not val then return end
      alias = val
    end

    duckdb_adapter.detach(conn_url, alias)
    connections.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
    require("dadbod-grip.completion").invalidate(url)
    schema_mod.refresh(url)
    vim.notify(string.format("Detached '%s'", alias), vim.log.levels.INFO)
  end, {
    nargs = "?",
    desc  = "Detach database from DuckDB session",
  })

  -- :GripOpen [path]: open any data source without saving to connections
  vim.api.nvim_create_user_command("GripOpen", function(cmd_opts)
    local path = vim.fn.trim(cmd_opts.args or "")
    local connections = require("dadbod-grip.connections")
    if path == "" then
      connections.pick()
      return
    end
    path = vim.fn.expand(path)
    -- S3 prefix (no file extension): open query pad pre-filled with glob()
    if path:match("^s3://") and not path:match("%.[a-zA-Z0-9]+$") then
      local safe = esc(path)
      local sql_str = string.format("SELECT * FROM glob('%s*') LIMIT 100", safe)
      local cur = connections.current()
      require("dadbod-grip.query_pad").open(cur and cur.url or "", { initial_sql = sql_str })
    else
      -- file path, HTTPS URL, or s3://...parquet: ephemeral (nil name = not saved)
      connections.switch(path, nil, nil, nil)
    end
  end, { nargs = "?", complete = "file",
         desc = "Open any data source (file, HTTPS, s3://) without saving" })

  -- :GripStart: open the Softrear Analyst Portal directly
  vim.api.nvim_create_user_command("GripStart", function()
    local demo_module = require("dadbod-grip.demo")
    local demo, err = demo_module.prepare(true)
    if not demo then
      vim.notify("Grip: " .. err, vim.log.levels.ERROR)
      return
    end
    local connections = require("dadbod-grip.connections")
    connections.switch(demo.url, demo_module.label, nil, { on_ready = function()
      local md_files = vim.api.nvim_get_runtime_file("demo/softrear-internal.md", false)
      if #md_files == 0 then return end
      local qpad = require("dadbod-grip.query_pad")
      qpad.open(demo.url)
      local pad = qpad.get_pad_bufnr()
      if not pad or not vim.api.nvim_buf_is_valid(pad) then return end
      local lines = vim.fn.readfile(md_files[1])
      vim.bo[pad].modifiable = true
      vim.api.nvim_buf_set_lines(pad, 0, -1, false, lines)
      vim.bo[pad].modified = false
      for i, line in ipairs(lines) do
        if line == "```sql" then
          vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
          vim.cmd("normal! zt")
          break
        end
      end
      local run_key = require("dadbod-grip.keymaps").get("qpad_execute")
      vim.notify(run_key and ("Demo ready: " .. run_key .. " runs this SQL block.")
        or "Demo ready. Use :GripQuery to edit SQL.", vim.log.levels.INFO)
    end })
    local attached
    attached, err = demo_module.attach_supplier(demo)
    if not attached then vim.notify("Grip: " .. err, vim.log.levels.WARN) end
    if demo.supplier_error then vim.notify("Grip: " .. demo.supplier_error, vim.log.levels.WARN) end

  end, { desc = "Open the Softrear Inc. Analyst Portal" })

  -- :GripHome: return to the welcome screen from anywhere
  vim.api.nvim_create_user_command("GripHome", function()
    M.open_welcome()
  end, { desc = "Open dadbod-grip welcome screen" })

  vim.api.nvim_create_user_command("GripZoom", function()
    require("dadbod-grip.zoom").toggle()
  end, { desc = "Zoom current pane or restore its split layout" })

  vim.api.nvim_create_user_command("GripZen", function()
    local windows = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      windows[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
    OPTS.show_hints = not OPTS.show_hints
    for buf, session in pairs(view._sessions) do
      if vim.api.nvim_buf_is_valid(buf) then view.render(buf, session.state) end
    end
    require("dadbod-grip.query_pad").refresh_hints()
    require("dadbod-grip.schema").redraw()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == "grip://welcome" then
        require("dadbod-grip.welcome").render(buf)
      end
    end
    for win, saved in pairs(windows) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function() vim.fn.winrestview(saved) end)
      end
    end
    vim.cmd("redraw")
  end, { desc = "Toggle automatic Grip shortcut hints for this session" })

  -- :GripToggle: close all grip windows if visible, reopen if hidden
  vim.api.nvim_create_user_command("GripToggle", function()
    -- Find all windows showing grip:// buffers
    local grip_wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("^grip://") then
        grip_wins[#grip_wins + 1] = { win = win, buf = buf }
      end
    end

    if #grip_wins > 0 then
      -- Close: wipe all grip buffers (triggers bufhidden=wipe cleanup)
      local seen = {}
      for _, gw in ipairs(grip_wins) do
        if not seen[gw.buf] and vim.api.nvim_buf_is_valid(gw.buf) then
          seen[gw.buf] = true
          pcall(vim.api.nvim_buf_delete, gw.buf, { force = true })
        end
      end
    else
      -- Open: reconnect to previous connection or show picker
      local connections = require("dadbod-grip.connections")
      local cur = connections.current()
      if cur and cur.url then
        connections.switch(cur.url, cur.name)
      else
        connections.pick()
      end
    end
  end, { desc = "Toggle dadbod-grip windows on/off" })

  -- :GripExport: export current result set to a file
  vim.api.nvim_create_user_command("GripExport", function()
    local bufnr = vim.api.nvim_get_current_buf()
    view.do_export(bufnr)
  end, { desc = "Export grip result to file (csv/json/sql)" })

  -- :GripImport: parse clipboard rows, or stdout from an explicit !command,
  -- then stage them as inserts in the current editable grid.
  vim.api.nvim_create_user_command("GripImport", function(cmd_opts)
    M.do_import(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Preview and stage CSV, TSV, or JSON rows from clipboard or !command",
  })

  -- :GripFill [N]: stage N AI-generated realistic rows (default 1, max 50)
  vim.api.nvim_create_user_command("GripFill", function(cmd_opts)
    -- do_fill_rows works on the session's connection, so guard on that one and
    -- not on the ambient one, which can be a different connection entirely
    -- after a :GripConnect. With no session there is nothing to fill and no
    -- URL to check; nil falls back to the ambient connection so the refusal
    -- still names the mode rather than the missing session.
    local fill_session = view._sessions[vim.api.nvim_get_current_buf()]
    if deny_if_readonly("GripFill", fill_session and fill_session.url) then return end
    local n = math.max(1, math.min(50, tonumber(cmd_opts.args) or 1))
    M.do_fill_rows(n)
  end, { nargs = "?", desc = "Stage N AI-generated rows for current table (default 1, max 50)" })
end

-- Exposed for testing
M._is_queryable_file = is_queryable_file
M._resolve_query = resolve_query

--- Compute where the cursor should land after editing a cell (spreadsheet-style advance).
--- Returns {line, col} (1-indexed line, 0-indexed byte col) or nil if position cannot be
--- determined. Always uses the NEXT row's byte_positions, never the current cursor offset.
function M._next_edit_cursor(r, edited_row_idx, edited_col)
  local ordered = r.ordered
  if not ordered or #ordered == 0 then return nil end
  local edit_order
  for i, ri in ipairs(ordered) do
    if ri == edited_row_idx then edit_order = i; break end
  end
  if not edit_order then return nil end
  local next_order = math.min(edit_order + 1, #ordered)
  local next_line  = (r.data_start or 4) + next_order - 1
  local bp     = r.byte_positions and r.byte_positions[next_order]
  local col_bp = bp and bp[edited_col]
  if not col_bp then return nil end
  return { line = next_line, col = col_bp.start }
end

--- Preview and stage CSV, TSV, or JSON rows in the current editable grid.
--- An empty source reads the + register; !command captures stdout while the
--- producer script is delivered to a constant parent shell argv over stdin.
function M.do_import(source)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = view._sessions[bufnr]
  if not session then
    vim.notify("GripImport: no grip session on this buffer", vim.log.levels.WARN)
    return
  end
  if not session.state.table_name or session.state.readonly then
    vim.notify("GripImport: requires an editable table grid", vim.log.levels.WARN)
    return
  end
  if deny_if_readonly("GripImport", session.url) then return end
  if db.is_readonly(session.url) then
    vim.notify("GripImport: this adapter is read-only", vim.log.levels.WARN)
    return
  end

  source = vim.trim(source or "")
  local raw, source_name
  if source == "" then
    raw = vim.fn.getreg("+")
    source_name = "clipboard"
  elseif source:sub(1, 1) == "!" then
    local command = vim.trim(source:sub(2))
    if command == "" then
      vim.notify("GripImport: provide a command after !", vim.log.levels.WARN)
      return
    end
    local stdout, _, code = require("dadbod-grip.adapters").run_cmd(
      { "sh", "-s" }, OPTS.timeout, { stdin = command .. "\n" })
    if code ~= 0 then
      vim.notify("GripImport: pipe command failed (exit " .. tostring(code) .. ")", vim.log.levels.ERROR)
      return
    end
    raw = stdout
    source_name = "pipe"
  else
    vim.notify("GripImport: use no argument for the clipboard or !command for a pipe",
      vim.log.levels.WARN)
    return
  end

  local parsed, err = importer.parse(raw, session.state.columns)
  if not parsed then
    vim.notify("GripImport: " .. err, vim.log.levels.ERROR)
    return
  end

  local prompt = string.format("Import %d %s rows into %s?\nColumns: %s (y/N): ",
    #parsed.rows, parsed.format, session.state.table_name, table.concat(parsed.columns, ", "))
  if not ui.confirm(prompt) then return end

  local state = data.insert_rows_with_values(session.state, #session.state.rows, parsed.rows)
  view.apply_edit(bufnr, state)
  vim.notify(string.format("GripImport: staged %d rows from %s; press a to apply",
    #parsed.rows, source_name), vim.log.levels.INFO)
end

--- Stage N AI-generated realistic rows into the current grip grid.
--- Validates session, calls ai.generate_rows(), stages each row via
--- data.insert_row_with_values(), then re-renders with view.apply_edit().
---@param n number  number of rows to stage (max 50, enforced by caller)
function M.do_fill_rows(n)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = view._sessions[bufnr]
  if not session then
    vim.notify("GripFill: no grip session on this buffer", vim.log.levels.WARN)
    return
  end
  if not session.state.table_name then
    vim.notify("GripFill: requires an editable table (not a raw query result)", vim.log.levels.WARN)
    return
  end

  local ai_mod = require("dadbod-grip.ai")
  local db_url  = session.url
  local tbl     = session.state.table_name

  -- Build single-table DDL so the AI knows exactly what to fill.
  local db_mod = require("dadbod-grip.db")
  -- Checked here too, not only in :GripFill: the AI keymap calls this
  -- directly, and the adapter check below would refuse a read-only *connection*
  -- with the wrong reason when its adapter is perfectly writable.
  if deny_if_readonly("GripFill", db_url) then return end
  if db_mod.is_readonly(db_url) then
    vim.notify("GripFill: this adapter is read-only", vim.log.levels.WARN)
    return
  end
  local cols  = db_mod.get_column_info(tbl, db_url)
  local pks   = db_mod.get_primary_keys(tbl, db_url)
  local ok_fk, fks = pcall(db_mod.get_foreign_keys, tbl, db_url)
  if not ok_fk then fks = {} end
  local ddl     = ai_mod._format_ddl_line(tbl, cols or {}, pks or {}, fks)

  -- Detect adapter for value-format hints. SQLite stays the fallback for
  -- URLs no adapter claims (its value syntax is the most permissive) -- which
  -- is why a "${VAR}" template is resolved first: the generated rows are
  -- executed, so falling back to the wrong dialect is not a cosmetic miss.
  local adapter = require("dadbod-grip.adapters").display_name(db_mod.resolved_url(db_url)) or "SQLite"

  ui.blocking("Generating " .. n .. " row(s)...", function()
    local done = false
    local gen_rows, gen_err

    ai_mod.generate_rows(n, ddl, adapter, tbl, db_url, function(rows, err)
      gen_rows, gen_err = rows, err
      done = true
    end)

    vim.wait(30000, function() return done end, 50)

    if gen_err then
      vim.notify("GripFill: " .. gen_err, vim.log.levels.ERROR)
      return
    end
    if not gen_rows or #gen_rows == 0 then
      vim.notify("GripFill: AI returned no rows", vim.log.levels.WARN)
      return
    end

    local st = session.state
    local after_idx = #st.rows
    for _, row_values in ipairs(gen_rows) do
      local values = {}
      for col, val in pairs(row_values) do
        if val == nil or val == vim.NIL then
          values[col] = nil
        else
          values[col] = tostring(val)
        end
      end
      st = data.insert_row_with_values(st, after_idx, values)
      after_idx = after_idx + 1
    end
    view.apply_edit(bufnr, st)
    vim.notify("GripFill: staged " .. #gen_rows .. " row(s); press a to apply", vim.log.levels.INFO)
  end)
end

return M
