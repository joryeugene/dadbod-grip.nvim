-- view/keymaps_fk.lua: Foreign-key navigation keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local sql    = require("dadbod-grip.sql")
local db     = require("dadbod-grip.db")
local qmod   = require("dadbod-grip.query")

local M = {}

--- Foreign key navigation: follow (gf), reverse lookup (gr), back (<C-o>).
function M.setup(bufnr, ctx)
  local view = ctx.view
  local kmap = ctx.kmap

  -- gf: navigate to FK referenced row
  kmap("grid_fk_follow", function()
    local session_fk = ctx.session()
    if not session_fk or not session_fk.state.table_name then
      vim.notify("FK navigation requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a cell", vim.log.levels.INFO)
      return
    end
    if cell.value == nil then
      vim.notify("NULL value: cannot follow FK", vim.log.levels.INFO)
      return
    end

    -- Fetch FK metadata (cached per table)
    if not session_fk.fk_cache then session_fk.fk_cache = {} end
    local tbl = session_fk.state.table_name
    if not session_fk.fk_cache[tbl] then
      local fks, fk_err = db.get_foreign_keys(tbl, session_fk.state.url)
      if fk_err then
        vim.notify("FK lookup failed: " .. fk_err, vim.log.levels.WARN)
        return
      end
      session_fk.fk_cache[tbl] = fks or {}
    end

    -- Find FK for this column
    local fk_info
    for _, fk in ipairs(session_fk.fk_cache[tbl]) do
      if fk.column == cell.col_name then
        fk_info = fk
        break
      end
    end
    if not fk_info then
      vim.notify(cell.col_name .. " is not a foreign key", vim.log.levels.INFO)
      return
    end

    -- Push current state to nav stack
    if not session_fk.nav_stack then session_fk.nav_stack = {} end
    table.insert(session_fk.nav_stack, {
      query_spec = session_fk.query_spec,
      state = session_fk.state,
      table_name = tbl,
      cursor_pos = vim.api.nvim_win_get_cursor(0),
      total_rows = session_fk.total_rows,
    })

    -- Build query for referenced row. The clause is pinned: it is the identity of
    -- the grid we are jumping to, not a filter the user applied, so F/X must not
    -- drop it and the [filtered] badge must not claim otherwise.
    local ref_spec = qmod.new_table(fk_info.ref_table, session_fk.query_spec.page_size)
    ref_spec = qmod.add_filter(ref_spec,
      sql.quote_ident(fk_info.ref_column) .. " = " .. sql.quote_value(cell.value),
      { pinned = true })
    local ref_sql = qmod.build_sql(ref_spec)

    local result, err = db.query(ref_sql, session_fk.state.url)
    if err then
      table.remove(session_fk.nav_stack) -- pop on failure
      vim.notify("FK query failed: " .. err, vim.log.levels.WARN)
      return
    end

    -- Empty result: fetch columns from schema (same guard as do_refresh in init.lua)
    if #result.columns == 0 then
      local col_info = db.get_column_info(fk_info.ref_table, session_fk.state.url)
      if col_info then
        for _, ci in ipairs(col_info) do
          table.insert(result.columns, ci.column_name)
        end
      end
    end

    -- Fetch PKs for referenced table
    local pks = db.get_primary_keys(fk_info.ref_table, session_fk.state.url) or {}
    result.primary_keys = pks
    -- Same connection as the grid we jumped from: a read-only one stays
    -- read-only on the referenced table too.
    result.readonly = db.is_readonly(session_fk.state.url)
    result.table_name = fk_info.ref_table
    result.url = session_fk.state.url
    result.sql = ref_sql

    local new_state = data.new(result)
    session_fk.query_spec = ref_spec
    session_fk.total_rows = #result.rows
    view.render(bufnr, new_state)
    view._sync_pad(ref_spec)
    vim.notify(tbl .. "." .. cell.col_name .. " → " .. fk_info.ref_table, vim.log.levels.INFO)
  end, "Follow FK to referenced row")

  -- gr: reverse FK — jump to rows in other tables that reference this row
  kmap("grid_fk_referencing", function()
    view._fk_referencing(bufnr)
  end, "Find referencing rows (reverse FK)")

  -- <C-o>: go back in FK navigation stack
  kmap("grid_fk_back", function()
    local session_nav = ctx.session()
    if not session_nav then return end
    if not session_nav.nav_stack or #session_nav.nav_stack == 0 then
      vim.notify("No FK navigation history", vim.log.levels.INFO)
      return
    end
    local frame = table.remove(session_nav.nav_stack)
    session_nav.query_spec = frame.query_spec
    session_nav.total_rows = frame.total_rows
    view.render(bufnr, frame.state)
    view._sync_pad(frame.query_spec)
    -- Restore cursor
    if frame.cursor_pos then
      pcall(vim.api.nvim_win_set_cursor, 0, frame.cursor_pos)
    end
    vim.notify("Back to " .. (frame.table_name or "previous"), vim.log.levels.INFO)
  end, "Go back (FK navigation)")
end

return M
