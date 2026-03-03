-- ddl.lua — DDL operations (rename, add, drop columns; create/drop tables).
-- Each operation previews the SQL, asks for confirmation, then executes.

local db   = require("dadbod-grip.db")
local sql  = require("dadbod-grip.sql")

local M = {}

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
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 60,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
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

local function destructive_confirm(title, ddl_sql, confirm_word, callback)
  local lines = {
    "  WARNING: " .. title,
    "",
  }
  for line in (ddl_sql .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, "  " .. line)
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
    border = "rounded",
    title = " Confirm ",
    title_pos = "center",
    zindex = 60,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = popup_buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  -- y: close float, then ask for typed confirmation
  vim.keymap.set("n", "y", function()
    close()
    local CANCEL = "\0"
    local ok, input = pcall(vim.fn.input, { prompt = 'Type "' .. confirm_word .. '" to confirm: ', cancelreturn = CANCEL })
    if ok and input == confirm_word then
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
  local CANCEL = "\0"
  local ok, new_name = pcall(vim.fn.input, { prompt = "Rename '" .. old_name .. "' to: ", cancelreturn = CANCEL })
  if not ok or new_name == CANCEL or new_name == "" or new_name == old_name then return end

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
  local CANCEL = "\0"
  local ok, new_name = pcall(vim.fn.input, { prompt = "Rename table '" .. old_name .. "' to: ", cancelreturn = CANCEL })
  if not ok or new_name == CANCEL or new_name == "" or new_name == old_name then return end

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
  local CANCEL = "\0"
  local ok1, col_name = pcall(vim.fn.input, { prompt = "Column name: ", cancelreturn = CANCEL })
  if not ok1 or col_name == CANCEL or col_name == "" then return end

  local ok2, col_type = pcall(vim.fn.input, { prompt = "Column type: ", default = "text", cancelreturn = CANCEL })
  if not ok2 or col_type == CANCEL or col_type == "" then return end

  local ok3, default_val = pcall(vim.fn.input, { prompt = "Default value (blank for none): ", cancelreturn = CANCEL })
  if not ok3 or default_val == CANCEL then return end

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

function M.drop_table(table_name, url, on_done)
  local ddl_sql = "DROP TABLE " .. sql.quote_ident(table_name)

  -- Check for FK dependents
  local fks = {}
  local tables, _ = db.list_tables(url)
  if tables then
    for _, tbl in ipairs(tables) do
      if tbl.name ~= table_name then
        local t_fks, _ = db.get_foreign_keys(tbl.name, url)
        if t_fks then
          for _, fk in ipairs(t_fks) do
            if fk.ref_table == table_name then
              table.insert(fks, tbl.name .. "." .. fk.column .. " -> " .. table_name .. "." .. fk.ref_column)
            end
          end
        end
      end
    end
  end

  if #fks > 0 then
    ddl_sql = ddl_sql .. " CASCADE"
  end

  destructive_confirm("DROP TABLE", ddl_sql, table_name, function()
    local _, err = db.execute(ddl_sql, url)
    if err then
      vim.notify("Drop table failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Dropped table " .. table_name, vim.log.levels.INFO)
    if on_done then on_done() end
  end)
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
  local CANCEL = "\0"
  local ok, table_name = pcall(vim.fn.input, { prompt = "Table name: ", cancelreturn = CANCEL })
  if not ok or table_name == CANCEL or table_name == "" then return end

  -- Collect columns interactively via a while loop (replaces recursive async pattern)
  local columns = {}
  while true do
    local ok2, col_name = pcall(vim.fn.input, { prompt = "Column name (blank to finish): ", cancelreturn = CANCEL })
    if not ok2 or col_name == CANCEL or col_name == "" then break end

    local ok3, col_type = pcall(vim.fn.input, { prompt = "Type for " .. col_name .. ": ", default = "text", cancelreturn = CANCEL })
    if not ok3 or col_type == CANCEL then break end
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

return M
