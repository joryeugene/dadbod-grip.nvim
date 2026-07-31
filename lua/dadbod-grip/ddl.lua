-- ddl.lua: DDL operations (rename, add, drop columns; create/drop tables).
-- Each operation previews the SQL, asks for confirmation, then executes.

local adapters = require("dadbod-grip.adapters")
local db       = require("dadbod-grip.db")
local sql      = require("dadbod-grip.sql")
local ui       = require("dadbod-grip.ui")

local M = {}

-- CLI adapters whose DROP TABLE actually understands CASCADE. sqlite rejects
-- it as a syntax error; mysql parses but silently ignores it (misleading);
-- sqlserver has no such clause at all.
local CASCADE_KINDS = { postgresql = true, duckdb = true }

-- Adapters whose db.get_referencing_foreign_keys() has a dedicated query that
-- filters by schema+table server-side (see each adapter's own
-- get_referencing_foreign_keys). An adapter missing one falls back to db.lua's
-- bare-name scan (matches any table sharing the bare name, regardless of
-- schema), which guard (2) in M._filter_referencing below has to discard.
local SCHEMA_EXACT_REF_KINDS = {
  postgresql = true, mysql = true, duckdb = true, sqlite = true, sqlserver = true,
}

-- Deliberately not sql.split_table_name: verified divergent for inputs this
-- module can plausibly see. split_table_name splits on the *first* dot and
-- unquotes each half, so a 3-part name ("a.b.c", the shape a DuckDB catalog
-- attachment name could take before it collapses to 2 parts elsewhere)
-- returns "b.c" from it, not "c" as bare() does; a quoted identifier
-- ('schema."quoted table"') comes back unquoted from split_table_name but
-- untouched from bare(); and the degenerate inputs "", "." and "schema."
-- disagree too: bare() returns nil for all three (there is no non-dot run
-- for "([^.]+)$" to match at all), while split_table_name's tbl half returns
-- "", "" and "schema" respectively (its regex falls back to the whole
-- string, but unquote_ident's gmatch-based rebuild drops a trailing dot with
-- nothing after it).
-- None of that is reachable through the adapters today (every
-- get_referencing_foreign_keys() and table_name passed to drop_table is a
-- plain, unquoted, at-most-one-dot string), so the two happen to agree on
-- every real input -- but they are not the same function, and swapping would
-- trade a correct narrow helper for a general-purpose one whose extra
-- behavior (unquoting, first-dot split) is untested here.
local function bare(name)
  return (name or ""):match("([^.]+)$")
end

-- Two guards keeping the single-query lookup as strict as the old per-table
-- scan it replaced.
--
-- (1) Self-references. No adapter's reverse-FK query excludes the target table
-- itself, but the old scan did (`if tbl.name ~= table_name`). A hierarchy
-- column (parent_id, manager_id) is not a reason to CASCADE: dropping the
-- table drops its own constraint anyway. Counting it would silently widen
-- DROP TABLE into "CASCADE" on postgresql/duckdb -- which also drops dependent
-- views and other tables' constraints -- and produce a bogus "dependent
-- foreign keys won't be dropped" warning elsewhere. Names are compared bare
-- because postgresql returns child tables schema-qualified while table_name
-- may not be; the worst case is dropping a genuine inbound FK from a
-- same-named table in another schema, which only loses a CASCADE the server
-- would then refuse -- the safe direction.
--
-- (2) A schema-qualified table_name on an adapter with no dedicated reverse-FK
-- query, so the match came from db.lua's bare-name fallback and may actually
-- belong to a same-named table in a different schema. None of the returned
-- rows carry which schema they matched against, so there is no way to tell the
-- genuine ones apart -- drop the whole batch rather than risk a false CASCADE
-- or warning. This is also exactly what the old scan did in that combination:
-- it compared against fk.ref_table, which every adapter returns unqualified,
-- so a schema-qualified table_name never matched there either.
local function filter_referencing(refs, table_name, kind)
  if not SCHEMA_EXACT_REF_KINDS[kind] and table_name:find(".", 1, true) then
    return {}
  end
  local target = bare(table_name)
  local out = {}
  for _, ref in ipairs(refs) do
    if bare(ref.table) ~= target then table.insert(out, ref) end
  end
  return out
end

local _ag = vim.api.nvim_create_augroup("DadbodGripDDL", { clear = true })

-- ── helpers ─────────────────────────────────────────────────────────────────

local function confirm_ddl(title, ddl_sql, callback)
  local lines = {}
  for line in (ddl_sql .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, "  " .. line)
  end
  table.insert(lines, "")
  table.insert(lines, "  Apply? [y/N]")

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = popup_buf })

  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local width = math.min(math.max(max_w + 4, 40), vim.o.columns - 10)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.5))

  local win = vim.api.nvim_open_win(popup_buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = ui.border(),
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 60,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    group  = _ag,
    buffer = popup_buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  vim.keymap.set("n", "y", function()
    close()
    callback()
  end, { buffer = popup_buf })

  for _, key in ipairs({ "n", "N", "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      vim.notify("Cancelled", vim.log.levels.INFO)
    end, { buffer = popup_buf })
  end
end

local function destructive_confirm(title, ddl_sql, confirm_word, callback, note)
  local lines = {
    "  WARNING: " .. title,
    "",
  }
  for line in (ddl_sql .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, "  " .. line)
  end
  if note then
    table.insert(lines, "")
    for line in (note .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, "  " .. line)
    end
  end
  table.insert(lines, "")
  table.insert(lines, '  Press y to confirm, then type "' .. confirm_word .. '"')
  table.insert(lines, "  Press q or Esc to cancel")

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = popup_buf })

  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, vim.fn.strdisplaywidth(l)) end
  local width = math.min(math.max(max_w + 4, 40), vim.o.columns - 10)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.5))

  local win = vim.api.nvim_open_win(popup_buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = ui.border(),
    title = " Confirm ",
    title_pos = "center",
    zindex = 60,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    group  = _ag,
    buffer = popup_buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  -- y: close float, then ask for typed confirmation
  vim.keymap.set("n", "y", function()
    close()
    local input = ui.input({
      prompt = 'Type "' .. confirm_word .. '" to confirm: ', allow_empty = true,
    })
    if input == confirm_word then
      callback()
    else
      vim.notify("Cancelled (input did not match)", vim.log.levels.INFO)
    end
  end, { buffer = popup_buf })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      vim.notify("Cancelled", vim.log.levels.INFO)
    end, { buffer = popup_buf })
  end
end

-- ── column rename ───────────────────────────────────────────────────────────

function M.rename_column(table_name, old_name, url, on_done)
  local new_name = ui.input({ prompt = "Rename '" .. old_name .. "' to: " })
  if not new_name or new_name == old_name then return end

  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME COLUMN %s TO %s',
    sql.quote_ident(table_name),
    sql.quote_ident(old_name),
    sql.quote_ident(new_name)
  )

  confirm_ddl("Rename Column", ddl_sql, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Renamed " .. old_name .. " to " .. new_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end)
end

-- ── table rename ────────────────────────────────────────────────────────────

function M.rename_table(old_name, url, on_done)
  local new_name = ui.input({ prompt = "Rename table '" .. old_name .. "' to: " })
  if not new_name or new_name == old_name then return end

  local ddl_sql = string.format(
    'ALTER TABLE %s RENAME TO %s',
    sql.quote_ident(old_name),
    sql.quote_ident(new_name)
  )

  confirm_ddl("Rename Table", ddl_sql, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Rename failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Renamed table '" .. old_name .. "' → '" .. new_name .. "'", vim.log.levels.INFO)
    if on_done then on_done(new_name) end
  end)
end

-- ── column add ──────────────────────────────────────────────────────────────

function M.add_column(table_name, url, on_done)
  local col_name = ui.input({ prompt = "Column name: " })
  if not col_name then return end

  local col_type = ui.input({ prompt = "Column type: ", default = "text" })
  if not col_type then return end

  -- Blank is a meaningful answer here: "no default".
  local default_val = ui.input({ prompt = "Default value (blank for none): ", allow_empty = true })
  if not default_val then return end

  local parts = { "ALTER TABLE " .. sql.quote_ident(table_name) }
  local col_def = "ADD COLUMN " .. sql.quote_ident(col_name) .. " " .. col_type
  if default_val ~= "" then
    col_def = col_def .. " DEFAULT " .. sql.quote_value(default_val)
  end
  table.insert(parts, col_def)

  local ddl_sql = table.concat(parts, " ")

  confirm_ddl("Add Column", ddl_sql, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Add column failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Added column " .. col_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end)
end

-- ── column drop ─────────────────────────────────────────────────────────────

function M.drop_column(table_name, col_name, url, on_done)
  local ddl_sql = string.format(
    'ALTER TABLE %s DROP COLUMN %s',
    sql.quote_ident(table_name),
    sql.quote_ident(col_name)
  )

  destructive_confirm("DROP COLUMN", ddl_sql, col_name, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Drop column failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Dropped column " .. col_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end)
end

-- ── drop table ──────────────────────────────────────────────────────────────

-- Pure SQL builder: only postgresql/duckdb get " CASCADE" appended, since it's
-- the only pair where the CLI actually honors it (see CASCADE_KINDS above).
local function build_drop_sql(table_name, kind, has_referencing)
  local ddl_sql = "DROP TABLE " .. sql.quote_ident(table_name)
  if has_referencing and CASCADE_KINDS[kind] then
    ddl_sql = ddl_sql .. " CASCADE"
  end
  return ddl_sql
end

function M.drop_table(table_name, url, on_done)
  -- Dialect decisions need the real scheme, so a "${DATABASE_URL}" template
  -- has to be resolved first: a nil kind would silently drop CASCADE from the
  -- generated SQL, discard every schema-qualified FK dependent below, and
  -- print "This adapter doesn't support CASCADE" about PostgreSQL.
  local dialect_url = db.resolved_url(url)
  local kind = adapters.kind(dialect_url)

  -- Check for FK dependents: one query instead of a get_foreign_keys() spawn
  -- per other table in the schema (see filter_referencing above for the two
  -- adjustments needed to keep this as strict as that old per-table scan).
  local refs = db.get_referencing_foreign_keys(table_name, url) or {}
  refs = filter_referencing(refs, table_name, kind)

  local has_referencing = #refs > 0
  local ddl_sql = build_drop_sql(table_name, kind, has_referencing)

  -- On adapters that can't CASCADE, an explicit heads-up beats a confusing
  -- server error (or, on MySQL, a silently ignored keyword) after the fact.
  local note
  if has_referencing and not CASCADE_KINDS[kind] then
    local name = adapters.display_name(dialect_url) or "This adapter"
    note = name .. " doesn't support CASCADE: dependent foreign keys won't be"
      .. " dropped, so this may fail or leave dangling references."
  end

  destructive_confirm("DROP TABLE", ddl_sql, table_name, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Drop table failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Dropped table " .. table_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end, note)
end

-- ── create table ────────────────────────────────────────────────────────────

local function build_create_sql(table_name, columns, url, on_done)
  local col_defs = {}
  local pk_cols = {}

  for _, col in ipairs(columns) do
    local def = sql.quote_ident(col.name) .. " " .. col.type
    table.insert(col_defs, def)
    if col.pk then
      table.insert(pk_cols, sql.quote_ident(col.name))
    end
  end

  if #pk_cols > 0 then
    table.insert(col_defs, "PRIMARY KEY (" .. table.concat(pk_cols, ", ") .. ")")
  end

  local ddl_sql = string.format(
    "CREATE TABLE %s (\n  %s\n)",
    sql.quote_ident(table_name),
    table.concat(col_defs, ",\n  ")
  )

  confirm_ddl("Create Table", ddl_sql, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Create table failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Created table " .. table_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end)
end

function M.create_table(url, on_done)
  local table_name = ui.input({ prompt = "Table name: " })
  if not table_name then return end

  -- Collect columns interactively via a while loop (replaces recursive async pattern)
  local columns = {}
  while true do
    local col_name = ui.input({ prompt = "Column name (blank to finish): " })
    if not col_name then break end

    local col_type = ui.input({
      prompt = "Type for " .. col_name .. ": ", default = "text", allow_empty = true,
    })
    if not col_type then break end
    if col_type == "" then col_type = "text" end

    local is_pk = #columns == 0  -- first column defaults to PK
    table.insert(columns, { name = col_name, type = col_type, pk = is_pk })
  end

  if #columns == 0 then
    vim.notify("No columns defined, cancelled", vim.log.levels.INFO)
    return
  end

  build_create_sql(table_name, columns, url, on_done)
end

-- Exposed for testing
M._build_create_sql = build_create_sql
M._build_drop_sql = build_drop_sql
M._filter_referencing = filter_referencing

return M
