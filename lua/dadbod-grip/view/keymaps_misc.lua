-- view/keymaps_misc.lua: Paging, sidebar and window keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local db     = require("dadbod-grip.db")

local M = {}

--- Saved queries (gq), modified-row jumps ({ }), paste (p/P), visual yank,
--- live SQL float (gl) and the column type row (T).
function M.setup(bufnr, ctx)
  local view = ctx.view
  local kmap, kvmap, get_visual_rows = ctx.kmap, ctx.kvmap, ctx.get_visual_rows

  -- gq: load saved query (open query pad + picker)
  kmap("load_saved", function()
    local session_q = ctx.session()
    local s_url = session_q and session_q.url
    local query_pad = require("dadbod-grip.query_pad")
    local saved = require("dadbod-grip.saved")
    query_pad.open(s_url, {})
    vim.schedule(function()
      saved.pick(function(sql_content, _, bound_url)
        -- Find the query pad buffer and load SQL into it
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf):match("grip://query") then
            if bound_url then vim.b[buf].db = bound_url end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sql_content, "\n"))
            vim.bo[buf].modified = false
            break
          end
        end
      end)
    end)
  end, "Load saved query")

  -- {: previous modified/staged row
  kmap("grid_prev_mod", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local current_order = cursor[1] - ds + 1
    local st = session.state
    -- Scan backwards from current position, wrapping around
    for offset = 1, #r.ordered do
      local idx = current_order - offset
      if idx < 1 then idx = idx + #r.ordered end
      local row_idx = r.ordered[idx]
      if data.row_status(st, row_idx) ~= "clean" then
        vim.api.nvim_win_set_cursor(0, { ds + idx - 1, cursor[2] })
        return
      end
    end
    vim.notify("No modified rows", vim.log.levels.INFO)
  end, "Previous modified row")

  -- }: next modified/staged row
  kmap("grid_next_mod", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ds = r.data_start or 4
    local current_order = cursor[1] - ds + 1
    local st = session.state
    -- Scan forward from current position, wrapping around
    for offset = 1, #r.ordered do
      local idx = ((current_order - 1 + offset) % #r.ordered) + 1
      local row_idx = r.ordered[idx]
      if data.row_status(st, row_idx) ~= "clean" then
        vim.api.nvim_win_set_cursor(0, { ds + idx - 1, cursor[2] })
        return
      end
    end
    vim.notify("No modified rows", vim.log.levels.INFO)
  end, "Next modified row")

  -- p: paste clipboard value into cell
  kmap("grid_paste", function()
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
    local clipboard = vim.fn.getreg("+")
    if clipboard == "" then
      vim.notify("Clipboard is empty", vim.log.levels.INFO)
      return
    end
    -- Trim trailing newline from clipboard
    clipboard = clipboard:gsub("\n$", "")
    local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, clipboard)
    vim.notify(cell.col_name .. " = " .. clipboard:sub(1, 30), vim.log.levels.INFO)
    view.apply_edit(bufnr, new_state)
  end, "Paste into cell")

  -- P: paste multi-line clipboard into consecutive rows (spread down)
  kmap("grid_paste_rows", function()
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
    local clipboard = vim.fn.getreg("+")
    if clipboard == "" then
      vim.notify("Clipboard is empty", vim.log.levels.INFO)
      return
    end
    -- Split clipboard by newlines into values
    local values = {}
    for line in (clipboard .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(values, line)
    end
    -- Trim trailing empty entry from final newline
    if #values > 0 and values[#values] == "" then
      table.remove(values)
    end
    if #values <= 1 then
      -- Single value: just paste into one cell (same as p)
      local val = values[1] or clipboard:gsub("\n$", "")
      local new_state = data.add_change(session.state, cell.row_idx, cell.col_name, val)
      view.apply_edit(bufnr, new_state)
      vim.notify(cell.col_name .. " = " .. val:sub(1, 30), vim.log.levels.INFO)
      return
    end
    -- Multiple values: spread into consecutive rows
    local r = session._render
    if not r then return end
    local ds = r.data_start or 4
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local start_order = cursor_line - ds + 1
    if start_order < 1 then return end
    local st = session.state
    local pasted = 0
    for i, val in ipairs(values) do
      local order_idx = start_order + i - 1
      if order_idx > #r.ordered then break end
      local row_idx = r.ordered[order_idx]
      st = data.add_change(st, row_idx, cell.col_name, val)
      pasted = pasted + 1
    end
    view.apply_edit(bufnr, st)
    vim.notify("Pasted " .. pasted .. " values into " .. cell.col_name, vim.log.levels.INFO)
  end, "Paste multi-line into consecutive rows")

  -- Visual y: yank selected cells in column (newline-separated)
  kvmap("grid_v_yank", function()
    local session = ctx.session()
    if not session then return end
    local cell = view.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local values = {}
    for _, ri in ipairs(row_indices) do
      local val = data.effective_value(session.state, ri, cell.col_name)
      table.insert(values, val or "")
    end
    local text = table.concat(values, "\n")
    vim.fn.setreg("+", text)
    vim.notify("Yanked " .. #values .. " cells from " .. cell.col_name, vim.log.levels.INFO)
  end, "Yank selected cells in column")

  -- gl: toggle live SQL preview float
  kmap("grid_live_sql", function()
    local session = ctx.session()
    if not session then return end

    -- Mutation preview mode: use gs instead
    if session.pending_mutation then
      vim.notify("gs: view mutation SQL  |  a: execute  |  U: cancel", vim.log.levels.INFO)
      return
    end

    if not session.state.table_name then
      vim.notify("Live SQL requires a table name", vim.log.levels.INFO)
      return
    end
    session.live_sql = not session.live_sql
    if session.live_sql then
      vim.notify("Live SQL: ON", vim.log.levels.INFO)
      view._update_live_sql_float(session)
    else
      vim.notify("Live SQL: OFF", vim.log.levels.INFO)
      view._close_live_sql_float(session)
    end
  end, "Toggle live SQL")

  -- T: toggle column types overlay
  kmap("grid_type_row", function()
    local session = ctx.session()
    if not session then return end
    if not session.state.table_name then
      vim.notify("Column types requires a table name", vim.log.levels.INFO)
      return
    end
    -- Fetch column info if not cached
    if not session._column_info then
      local info, err = db.get_column_info(session.state.table_name, session.state.url)
      if err then
        vim.notify("Failed to get column info: " .. err, vim.log.levels.WARN)
        return
      end
      session._column_info = info
    end
    session.show_types = not session.show_types
    vim.notify("Column types: " .. (session.show_types and "ON" or "OFF"), vim.log.levels.INFO)
    view.render(bufnr, session.state)
  end, "Toggle column types")
end

return M
