-- view/keymaps_edit.lua: Row and cell editing keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local db     = require("dadbod-grip.db")
local qmod   = require("dadbod-grip.query")
local sql    = require("dadbod-grip.sql")

local M = {}

--- Row and cell editing: welcome/query pad entry, refresh, edit, delete,
--- insert, clone, apply, undo/redo, yank, NULL, column set.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local kmap, edit_cell = ctx.kmap, ctx.edit_cell

  -- Q: go to welcome screen (home)
  kmap("welcome", function() require("dadbod-grip").open_welcome() end, "Welcome screen")

  -- q: open query pad (pre-filled with current query)
  kmap("query_pad", function()
    local query_pad = require("dadbod-grip.query_pad")
    local session_q = ctx.session()
    local s_url = session_q and session_q.url
    local initial_sql
    if session_q and session_q.query_spec then
      initial_sql = qmod.clean_sql(session_q.query_spec)
    elseif session_q and session_q.query_sql then
      initial_sql = session_q.query_sql
    end
    query_pad.open(s_url, initial_sql and { initial_sql = initial_sql } or nil)
  end, "Open query pad")

  -- r: refresh
  kmap("grid_refresh", function()
    local session = ctx.session()
    if not session then return end
    if data.has_changes(session.state) then
      local staged = data.count_staged(session.state)
      local choice = vim.fn.confirm(
        string.format("Refresh will discard %d unapplied change(s). Continue?", staged),
        "&Yes\n&Cancel", 2
      )
      if choice ~= 1 then return end
    end
    if session.on_refresh then session.on_refresh(bufnr) end
  end, "Refresh query")

  kmap("grid_edit", edit_cell, "Edit cell")

  -- d: toggle delete row
  kmap("grid_delete", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    if session.on_delete then session.on_delete(bufnr, cell.row_idx) end
  end, "Toggle delete row")

  -- o: insert new row
  kmap("grid_insert", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    local after = cell and cell.row_idx or #session.state.rows
    if session.on_insert then session.on_insert(bufnr, after) end
  end, "Insert row after cursor")

  -- c: clone current row (staged INSERT with copied values, PKs cleared)
  kmap("grid_clone", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to clone", vim.log.levels.INFO)
      return
    end
    if session.on_clone then session.on_clone(bufnr, cell.row_idx) end
  end, "Clone row (copy values, clear PKs)")

  -- a: apply all staged changes
  kmap("grid_apply", function()
    local session = ctx.session()
    if not session then return end

    -- Mutation preview mode: execute the pending mutation
    if session.pending_mutation then
      local pm = session.pending_mutation
      local choice = vim.fn.confirm(
        string.format("Execute %s? (%d row%s affected)\n\n%s",
          pm.type, pm.row_count, pm.row_count == 1 and "" or "s",
          pm.sql:sub(1, 200)),
        "&Execute\n&Cancel", 2)
      if choice ~= 1 then return end
      local t0 = vim.uv.hrtime()
      local _, err = db.execute(pm.sql, session.url)
      local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
      if err then
        vim.notify("Failed: " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify(string.format("%s executed (%dms, %d row%s)",
        pm.type, ms, pm.row_count, pm.row_count == 1 and "" or "s"), vim.log.levels.INFO)
      local history = require("dadbod-grip.history")
      history.record({ sql = pm.sql, url = session.url, type = pm.type:lower(), elapsed_ms = ms })
      -- Clear mutation state and reopen the full table
      local tbl = pm.table_name
      local s_url = session.url
      session.pending_mutation = nil
      session._mutation_title = nil
      -- Reopen the full table (not the WHERE-filtered preview)
      local current_win = vim.api.nvim_get_current_win()
      local grip = require("dadbod-grip")
      grip.open(tbl, s_url, { reuse_win = current_win })
      return
    end

    -- Normal mode: apply staged changes
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    if not data.has_changes(session.state) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    local staged = data.count_staged(session.state)
    local choice = vim.fn.confirm(
      string.format("Apply %d staged change(s) to database?", staged),
      "&Apply\n&Cancel", 2
    )
    if choice ~= 1 then return end
    if session.on_apply then session.on_apply(bufnr) end
  end, "Apply staged changes")

  -- u: two-tier undo
  -- Tier 0: mutation preview cancel
  -- Tier 1: local staging undo (uncommitted changes)
  -- Tier 2: transaction undo (reverse committed SQL)
  kmap("grid_undo", function()
    local session = ctx.session()
    if not session then return end

    -- Tier 0: mutation preview: cancel (close the preview)
    if session.pending_mutation then
      session.pending_mutation = nil
      session._mutation_title = nil
      vim.notify("Mutation cancelled", vim.log.levels.INFO)
      -- Close the preview grid window
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then
        pcall(vim.api.nvim_win_close, win, true)
      end
      return
    end

    -- Tier 1: local staging undo
    if session._undo_stack and #session._undo_stack > 0 then
      if not session._redo_stack then session._redo_stack = {} end
      table.insert(session._redo_stack, session.state)
      local prev_state = table.remove(session._undo_stack)
      view.render(bufnr, prev_state)
      local remaining = #session._undo_stack
      if remaining > 0 then
        vim.notify("Undo (" .. remaining .. " more)", vim.log.levels.INFO)
      else
        vim.notify("Undo (back to original)", vim.log.levels.INFO)
      end
      return
    end

    -- Tier 2: transaction undo
    if session._txn_undo_stack and #session._txn_undo_stack > 0 then
      local reverse = session._txn_undo_stack[#session._txn_undo_stack]
      local count = #reverse
      local choice = vim.fn.confirm(
        "Undo last committed transaction? (" .. count .. " statement(s))",
        "&Yes\n&No", 2)
      if choice ~= 1 then return end
      local txn = sql.wrap_transaction(reverse,
        require("dadbod-grip.adapters").kind(session.url))
      local _, err = db.execute(txn, session.url)
      if err then
        vim.notify("Undo failed: " .. err, vim.log.levels.ERROR)
        return
      end
      table.remove(session._txn_undo_stack)
      vim.notify("Undid transaction (" .. count .. " statement(s))", vim.log.levels.INFO)
      if session.on_refresh then session.on_refresh(bufnr) end
      return
    end

    vim.notify("Nothing to undo", vim.log.levels.INFO)
  end, "Undo last edit")

  -- U: undo all (resets to original state) or cancel mutation
  kmap("grid_undo_all", function()
    local session = ctx.session()
    if not session then return end
    -- Mutation preview: cancel
    if session.pending_mutation then
      session.pending_mutation = nil
      session._mutation_title = nil
      vim.notify("Mutation cancelled", vim.log.levels.INFO)
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then pcall(vim.api.nvim_win_close, win, true) end
      return
    end
    if not session._undo_stack or #session._undo_stack == 0 then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    local original = session._undo_stack[1]
    local count = #session._undo_stack
    session._undo_stack = {}
    view.render(bufnr, original)
    vim.notify("Undid all " .. count .. " change(s)", vim.log.levels.INFO)
  end, "Undo all changes")

  -- <C-r>: redo
  kmap("grid_redo", function()
    local session = ctx.session()
    if not session then return end
    if not session._redo_stack or #session._redo_stack == 0 then
      vim.notify("Nothing to redo", vim.log.levels.INFO)
      return
    end
    if not session._undo_stack then session._undo_stack = {} end
    table.insert(session._undo_stack, session.state)
    local redo_state = table.remove(session._redo_stack)
    view.render(bufnr, redo_state)
    local remaining = #session._redo_stack
    vim.notify("Redo" .. (remaining > 0 and " (" .. remaining .. " more)" or ""), vim.log.levels.INFO)
  end, "Redo")

  -- y: yank cell value
  kmap("grid_yank_cell", function()
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to yank", vim.log.levels.INFO)
      return
    end
    local val = cell.value or ""
    vim.fn.setreg("+", val)
    vim.notify("Yanked: " .. val, vim.log.levels.INFO)
  end, "Yank cell value")

  -- Y: yank row as CSV
  kmap("grid_yank_row", function()
    local session = ctx.session()
    if not session then return end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row to yank", vim.log.levels.INFO)
      return
    end
    local st = session.state
    local parts = {}
    for _, col in ipairs(st.columns) do
      local val = data.effective_value(st, cell.row_idx, col)
      table.insert(parts, val or "")
    end
    local csv = table.concat(parts, ",")
    vim.fn.setreg("+", csv)
    vim.notify("Yanked row as CSV", vim.log.levels.INFO)
  end, "Yank row as CSV")

  -- gY: yank table as CSV
  kmap("grid_yank_table", function()
    local session = ctx.session()
    if not session then return end
    local st = session.state
    local r = session._render
    if not r then return end
    local lines_out = { table.concat(st.columns, ",") }
    for _, row_idx in ipairs(r.ordered) do
      local parts = {}
      for _, col in ipairs(st.columns) do
        local val = data.effective_value(st, row_idx, col)
        table.insert(parts, val or "")
      end
      table.insert(lines_out, table.concat(parts, ","))
    end
    vim.fn.setreg("+", table.concat(lines_out, "\n"))
    vim.notify("Yanked " .. #r.ordered .. " rows as CSV", vim.log.levels.INFO)
  end, "Yank table as CSV")

  -- gy: yank table as Markdown pipe table
  kmap("grid_yank_md", function()
    local session_gy = ctx.session()
    if not session_gy or not session_gy._render then return end
    local st_gy = session_gy.state
    local r_gy = session_gy._render
    local cols = st_gy.columns
    local rows_data = {}
    for _, row_idx in ipairs(r_gy.ordered) do
      local row = {}
      for _, col in ipairs(cols) do
        -- effective_value returns nil for NULL; table.insert(row, nil) is a
        -- no-op that would shift the remaining columns left, so map to "".
        table.insert(row, data.effective_value(st_gy, row_idx, col) or "")
      end
      table.insert(rows_data, row)
    end
    vim.fn.setreg("+", table.concat(view._format_export(rows_data, cols, "markdown"), "\n"))
    vim.notify("Copied as Markdown table (" .. #rows_data .. " rows)", vim.log.levels.INFO)
  end, "Yank table as Markdown")

  -- x: set cell to NULL
  kmap("grid_null", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, nil)
    vim.notify(cell.col_name .. " set to NULL", vim.log.levels.INFO)
    view.apply_edit(bufnr, new_state)
  end, "Set cell to NULL")

  -- gU: multi-cursor column set (same value for all visible rows)
  kmap("grid_column_set", function()
    view._column_set(bufnr)
  end, "Set column value for all visible rows")

end

return M
