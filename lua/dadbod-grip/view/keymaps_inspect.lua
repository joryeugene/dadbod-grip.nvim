-- view/keymaps_inspect.lua: Cell and row inspection keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local sql    = require("dadbod-grip.sql")
local db     = require("dadbod-grip.db")

local M = {}

--- Inspection floats: staged SQL preview/copy, table info and properties,
--- column rename, cell explain, cell expand, row view, cell buffer, JSON
--- tree, visual stack-inspect and two-row compare.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local open_info_float = ctx.open_info_float
  local kmap, kvmap, get_visual_rows, edit_cell, km = ctx.kmap, ctx.kvmap, ctx.get_visual_rows, ctx.edit_cell, ctx.km

  -- gs: preview staged SQL (or pending mutation SQL) in float
  kmap("grid_preview_sql", function()
    local session = ctx.session()
    if not session then return end

    -- Mutation pending: show the pending SQL
    if session.pending_mutation then
      if session._live_sql_win and vim.api.nvim_win_is_valid(session._live_sql_win) then
        view._close_live_sql_float(session)
      else
        local pm_lines = {}
        for line in (session.pending_mutation.sql .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(pm_lines, line)
        end
        local grip_win = vim.api.nvim_get_current_win()
        open_info_float(grip_win, pm_lines, { title = " " .. session.pending_mutation.type .. " SQL ", filetype = "sql" })
      end
      return
    end

    local st = session.state
    if not data.has_changes(st) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    if not st.table_name then
      vim.notify("SQL preview requires a table name", vim.log.levels.INFO)
      return
    end
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    local lines = {}
    for line in (preview .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, { title = " Staged SQL ", filetype = "sql" })
  end, "Preview staged SQL")

  -- gc: copy staged SQL to clipboard
  kmap("grid_copy_sql", function()
    local session = ctx.session()
    if not session then return end
    local st = session.state
    if not data.has_changes(st) then
      vim.notify("No staged changes", vim.log.levels.INFO)
      return
    end
    if not st.table_name then
      vim.notify("SQL preview requires a table name", vim.log.levels.INFO)
      return
    end
    local preview = sql.preview_staged(
      st.table_name,
      data.get_updates(st),
      data.get_deletes(st),
      data.get_inserts(st)
    )
    vim.fn.setreg("+", preview)
    vim.notify("Copied SQL to clipboard", vim.log.levels.INFO)
  end, "Copy staged SQL")

  -- gi: table info float
  kmap("grid_table_info", function()
    local session = ctx.session()
    if not session then return end
    local st = session.state
    if not st.table_name then
      vim.notify("Table info requires a table name", vim.log.levels.INFO)
      return
    end
    -- Use cached column info if available
    if not session._column_info then
      local info, err = db.get_column_info(st.table_name, st.url)
      if err then
        vim.notify("Failed to get column info: " .. err, vim.log.levels.WARN)
        return
      end
      session._column_info = info
    end
    local info = session._column_info
    -- Pre-compute column widths for aligned display
    local max_name_w, max_type_w = 0, 0
    for _, col in ipairs(info) do
      max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col.column_name))
      max_type_w = math.max(max_type_w, vim.fn.strdisplaywidth(col.data_type))
    end
    max_name_w = math.min(max_name_w, 30)
    max_type_w = math.min(max_type_w, 32)
    local lines = { " " .. st.table_name, " " .. string.rep("─", 40) }
    for _, col in ipairs(info) do
      local name_pad = string.rep(" ", math.max(0, max_name_w - vim.fn.strdisplaywidth(col.column_name)))
      local type_pad = string.rep(" ", math.max(0, max_type_w - vim.fn.strdisplaywidth(col.data_type)))
      local parts = { "  " .. col.column_name .. name_pad .. "  " .. col.data_type .. type_pad }
      if col.is_nullable == "NO" then table.insert(parts, "NOT NULL") end
      if col.column_default ~= "" then table.insert(parts, "DEFAULT " .. col.column_default) end
      if col.constraints ~= "" then table.insert(parts, "[" .. col.constraints .. "]") end
      table.insert(lines, table.concat(parts, "  "))
    end
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, { title = " Table Info " })
  end, "Table info")

  -- gI: full table properties float
  kmap("grid_table_props", function()
    local session = ctx.session()
    if not session then return end
    local st = session.state
    if not st.table_name then
      vim.notify("Table properties requires a table name", vim.log.levels.INFO)
      return
    end
    local properties = require("dadbod-grip.properties")
    local grip_win = vim.api.nvim_get_current_win()
    properties.open(st.table_name, st.url, grip_win)
  end, "Table properties")

  -- gN: rename column under cursor
  kmap("grid_rename_col", function()
    local session = ctx.session()
    if session and require("dadbod-grip.connections").deny_if_readonly("Rename column", session.url) then
      return
    end
    if not session or not session.state.table_name then
      vim.notify("Rename requires a table name", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column", vim.log.levels.INFO)
      return
    end
    local ddl_mod = require("dadbod-grip.ddl")
    ddl_mod.rename_column(session.state.table_name, cell.col_name, session.url, function()
      if session.on_refresh then session.on_refresh(bufnr) end
    end)
  end, "Rename column")

  -- ge: explain cell
  kmap("grid_explain_cell", function()
    local session = ctx.session()
    if not session then return end
    local st = session.state
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    -- Fetch column info (cached)
    if not session._column_info and st.table_name then
      local info, err = db.get_column_info(st.table_name, st.url)
      if not err then session._column_info = info end
    end
    local col_info
    if session._column_info then
      for _, ci in ipairs(session._column_info) do
        if ci.column_name == cell.col_name then col_info = ci; break end
      end
    end
    local status = data.row_status(st, cell.row_idx)
    local cell_staged = status == "modified"
      and st.changes[cell.row_idx]
      and st.changes[cell.row_idx][cell.col_name] ~= nil
    local display_status
    if status == "deleted" then
      display_status = "deleted"
    elseif status == "inserted" then
      display_status = "inserted"
    elseif cell_staged then
      display_status = "staged"
    else
      display_status = "original"
    end
    local lines = { " " .. cell.col_name }
    lines[#lines + 1] = " " .. string.rep("─", 30)
    if col_info then
      lines[#lines + 1] = "  Type: " .. col_info.data_type
      lines[#lines + 1] = "  Nullable: " .. col_info.is_nullable
      if col_info.column_default ~= "" then
        lines[#lines + 1] = "  Default: " .. col_info.column_default
      end
      if col_info.constraints ~= "" then
        lines[#lines + 1] = "  Constraints: " .. col_info.constraints
      end
    end
    lines[#lines + 1] = "  Value: " .. (cell.value or "NULL")
    lines[#lines + 1] = "  Status: " .. display_status
    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, lines, {
      title = " Cell Info ",
      relative = "cursor",
      row = 1, col = 0,
    })
  end, "Explain cell")

  -- <CR>: expand cell popup (suppressed on meta views; FK view navigates to referenced table)
  kmap("grid_edit_enter", function()
    local session_cr = ctx.session()
    if not session_cr or not session_cr._render then return end

    -- Meta views: no editing. FK view navigates to the referenced table; others do nothing.
    local cv = session_cr.current_view
    if cv and cv ~= "records" then
      if cv == "fk" then
        local cell = view.get_cell(bufnr)
        if cell and cell.row_idx then
          -- Use _meta_state: session.state was restored to records after render
          local ms   = session_cr._meta_state
          local row  = ms and ms.rows[cell.row_idx]
          local cols = ms and ms.columns
          if row and cols then
            local dir_idx, ref_tbl_idx, col_idx
            for i, c in ipairs(cols) do
              if c == "direction" then dir_idx = i
              elseif c == "ref_table" then ref_tbl_idx = i
              elseif c == "column" then col_idx = i
              end
            end
            local direction = dir_idx and (row[dir_idx] or "") or ""
            local target
            if direction:find("outbound", 1, true) and ref_tbl_idx then
              target = row[ref_tbl_idx]
            elseif direction:find("inbound", 1, true) and col_idx then
              -- column value is "tablename.column_name"
              target = (row[col_idx] or ""):match("^([^.]+)%.")
            end
            if target and target ~= "" and target ~= "(none)" then
              require("dadbod-grip").open(target, session_cr.url)
              return
            end
          end
        end
      end
      -- All other meta views: Enter does nothing (no cell editing in read-only views)
      return
    end

    local cell = view.get_cell(bufnr)
    if cell then
      -- Data row: edit cell (spreadsheet-style Enter to edit)
      edit_cell()
    else
      -- Header/type row: detect column under cursor, show full name/type
      local r = session_cr._render
      local ref_bp = r.hdr_byte_positions
      if not ref_bp then return end
      local cols = r.visible_columns or session_cr.state.columns
      local col_nr = vim.api.nvim_win_get_cursor(0)[2]
      local found_col
      for _, col in ipairs(cols) do
        local bp = ref_bp[col]
        if bp and col_nr >= bp.start and col_nr <= bp.finish then
          found_col = col
          break
        end
      end
      if found_col then
        local info = { found_col }
        if session_cr._column_info then
          for _, ci in ipairs(session_cr._column_info) do
            if ci.column_name == found_col then
              table.insert(info, "Type: " .. (ci.data_type or "unknown"))
              if ci.is_nullable then table.insert(info, "Nullable: " .. ci.is_nullable) end
              break
            end
          end
        end
        local grip_win = vim.api.nvim_get_current_win()
        open_info_float(grip_win, info, {
          title = " " .. found_col .. " ",
          relative = "cursor",
          row = 1, col = 0,
        })
      end
    end
  end, "Expand cell value")

  -- K: row view (vertical transpose)
  kmap("grid_row_view", function()
    local session = ctx.session()
    if not session then return end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    local st = session.state
    local max_name_w = 0
    for _, col in ipairs(st.columns) do
      max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col))
    end
    local lines = {}
    -- col_line_ranges[col] = { start=1-indexed first line, count=n lines, is_null=bool }
    local col_line_ranges = {}
    for _, col in ipairs(st.columns) do
      local val = data.effective_value(st, cell.row_idx, col)
      local pad = string.rep(" ", max_name_w - vim.fn.strdisplaywidth(col))
      local prefix = " " .. col .. pad .. "   "
      local start_line = #lines + 1
      -- JSON-aware display: try to pretty-print JSON/jsonb values
      local json_ok, json_decoded = val and pcall(vim.fn.json_decode, val) or false, nil
      if json_ok then json_decoded = vim.fn.json_decode(val) end
      if json_ok and type(json_decoded) == "table" then
        local json_lines = view._json_to_lines(json_decoded)
        if json_lines and #json_lines > 0 then
          table.insert(lines, prefix .. json_lines[1])
          for ji = 2, #json_lines do
            table.insert(lines, string.rep(" ", #prefix) .. json_lines[ji])
          end
        else
          table.insert(lines, prefix .. (val or "NULL"))
        end
      else
        local display_val = val and val:gsub("\n", "↵"):gsub("\r", "") or "NULL"
        table.insert(lines, prefix .. display_val)
      end
      col_line_ranges[col] = { start = start_line, count = #lines - start_line + 1, is_null = (val == nil) }
    end
    local grip_win = vim.api.nvim_get_current_win()
    local _, popup_buf = open_info_float(grip_win, lines, {
      title = " Row " .. cell.row_idx .. " ",
    })
    -- Shadow ]p/[p: Vim's built-in "put indented" would E21 on modifiable=false popup buffers
    vim.keymap.set("n", "]p", "<Nop>", { buffer = popup_buf, silent = true })
    vim.keymap.set("n", "[p", "<Nop>", { buffer = popup_buf, silent = true })
    -- gK inside the row view: JSON tree drilldown for the column under cursor
    local jt_key = km.get("grid_json_tree")
    if jt_key then
      vim.keymap.set("n", jt_key, function()
        local cur = vim.api.nvim_win_get_cursor(0)[1]
        for _, col in ipairs(st.columns) do
          local range = col_line_ranges[col]
          if range and cur >= range.start and cur < range.start + range.count then
            require("dadbod-grip.json_tree").open(
              data.effective_value(st, cell.row_idx, col),
              { title = " " .. col .. " (JSON) ", origin_win = grip_win })
            return
          end
        end
      end, { buffer = popup_buf, silent = true, nowait = true })
    end
    -- Apply highlights using actual line ranges (not column index, which breaks on multi-line JSON)
    local status = data.row_status(st, cell.row_idx)
    local row_ns = vim.api.nvim_create_namespace("grip_row_view")
    local function hl_range(range, hl_group)
      for li = range.start, range.start + range.count - 1 do
        vim.api.nvim_buf_set_extmark(popup_buf, row_ns, li - 1, 0, {
          end_col = #lines[li],
          hl_group = hl_group,
        })
      end
    end
    if status == "modified" and st.changes[cell.row_idx] then
      for _, col in ipairs(st.columns) do
        local range = col_line_ranges[col]
        if range then
          if range.is_null and st.changes[cell.row_idx][col] ~= nil then
            -- Modified + null → orange (matches mutation preview staging color)
            hl_range(range, "GripNullStaged")
          elseif range.is_null then
            hl_range(range, "GripNull")
          elseif st.changes[cell.row_idx][col] ~= nil then
            hl_range(range, "GripModified")
          end
        end
      end
    elseif status == "inserted" then
      for li = 1, #lines do
        vim.api.nvim_buf_set_extmark(popup_buf, row_ns, li - 1, 0, {
          end_col = #lines[li],
          hl_group = "GripInserted",
        })
      end
    elseif status == "deleted" then
      for li = 1, #lines do
        vim.api.nvim_buf_set_extmark(popup_buf, row_ns, li - 1, 0, {
          end_col = #lines[li],
          hl_group = "GripDeleted",
        })
      end
    else
      -- Normal row: highlight NULL values
      for _, col in ipairs(st.columns) do
        local range = col_line_ranges[col]
        if range and range.is_null then
          hl_range(range, "GripNull")
        end
      end
    end
  end, "Row view")

  -- gB: open cell value in a full split buffer (large JSON, long text)
  kmap("grid_cell_buffer", function()
    require("dadbod-grip.cell_buffer").open(bufnr)
  end, "Open cell in buffer")

  -- gK: JSON tree drilldown for the cell under cursor
  kmap("grid_json_tree", function()
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a data row", vim.log.levels.INFO)
      return
    end
    require("dadbod-grip.json_tree").open(cell.value, {
      title      = " " .. cell.col_name .. " (JSON) ",
      origin_win = vim.api.nvim_get_current_win(),
    })
  end, "JSON tree drilldown")

  -- K (visual): stack-inspect multiple selected rows in one float.
  -- Each row becomes a labeled block separated by a blank line.
  -- 1 row selected → same float as normal K. N rows → stacked blocks.
  kvmap("grid_row_view", function()
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    local session = ctx.session()
    if not session then return end
    local st = session.state

    local max_name_w = 0
    for _, col in ipairs(st.columns) do
      max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col))
    end

    local lines = {}
    for bi, row_idx in ipairs(row_indices) do
      -- Header: PK=value pairs, or fallback row number
      local pk_vals = {}
      for _, pk in ipairs(st.pks or {}) do
        local v = data.effective_value(st, row_idx, pk)
        table.insert(pk_vals, pk .. "=" .. (v or "NULL"))
      end
      local header = #pk_vals > 0 and table.concat(pk_vals, " ") or ("Row " .. bi)
      table.insert(lines, " \226\148\128\226\148\128 " .. header .. " " .. string.rep("\226\148\128", 28))

      for _, col in ipairs(st.columns) do
        local val = data.effective_value(st, row_idx, col)
        local pad = string.rep(" ", max_name_w - vim.fn.strdisplaywidth(col))
        local prefix = " " .. col .. pad .. "   "
        local json_ok, json_decoded = val and pcall(vim.fn.json_decode, val) or false, nil
        if json_ok then json_decoded = vim.fn.json_decode(val) end
        if json_ok and type(json_decoded) == "table" then
          local jlines = view._json_to_lines(json_decoded)
          if jlines and #jlines > 0 then
            table.insert(lines, prefix .. jlines[1])
            for ji = 2, #jlines do
              table.insert(lines, string.rep(" ", #prefix) .. jlines[ji])
            end
          else
            table.insert(lines, prefix .. (val or "NULL"))
          end
        else
          local display_val = val and val:gsub("\n", "↵"):gsub("\r", "") or "NULL"
          table.insert(lines, prefix .. display_val)
        end
      end

      if bi < #row_indices then
        table.insert(lines, "")
      end
    end

    local title = #row_indices == 1
      and " Row " .. row_indices[1] .. " "
      or  " " .. #row_indices .. " rows "
    local grip_win = vim.api.nvim_get_current_win()
    local _, popup_buf = open_info_float(grip_win, lines, { title = title })
    vim.keymap.set("n", "]p", "<Nop>", { buffer = popup_buf, silent = true })
    vim.keymap.set("n", "[p", "<Nop>", { buffer = popup_buf, silent = true })
  end, "Stack-inspect selected rows")

  -- gd (visual): diff exactly 2 selected rows, highlighting what differs.
  -- Pure display: no DB interaction. Differing cells get GripModified / DiffAdd.
  kvmap("grid_v_compare", function()
    local rows = get_visual_rows()
    if not rows or #rows ~= 2 then
      vim.notify("Select exactly 2 rows to compare", vim.log.levels.INFO)
      return
    end
    local session = ctx.session()
    if not session then return end
    local st = session.state

    local max_name_w = 0
    for _, col in ipairs(st.columns) do
      max_name_w = math.max(max_name_w, vim.fn.strdisplaywidth(col))
    end

    local lines  = {}
    local marks  = {}  -- { line_idx (0-based), hl_group }
    for _, col in ipairs(st.columns) do
      local a = data.effective_value(st, rows[1], col) or "NULL"
      local b = data.effective_value(st, rows[2], col) or "NULL"
      local pad = string.rep(" ", max_name_w - vim.fn.strdisplaywidth(col))
      local line_a = " " .. col .. pad .. "  A  " .. a:gsub("\n", "↵")
      local line_b = " " .. col .. pad .. "  B  " .. b:gsub("\n", "↵")
      if a ~= b then
        table.insert(marks, { idx = #lines,     hl = "GripModified" })
        table.insert(marks, { idx = #lines + 1, hl = "DiffAdd" })
      end
      table.insert(lines, line_a)
      table.insert(lines, line_b)
      table.insert(lines, "")
    end
    -- Remove trailing blank line
    if lines[#lines] == "" then table.remove(lines) end

    local title = " Row " .. rows[1] .. " vs Row " .. rows[2] .. " "
    local grip_win = vim.api.nvim_get_current_win()
    local _, popup_buf = open_info_float(grip_win, lines, { title = title })
    local ns = vim.api.nvim_create_namespace("grip_row_compare")
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(popup_buf, ns, m.idx, 0, {
        end_col = 0, end_row = m.idx + 1,
        hl_group = m.hl, hl_eol = true,
      })
    end
    vim.keymap.set("n", "]p", "<Nop>", { buffer = popup_buf, silent = true })
    vim.keymap.set("n", "[p", "<Nop>", { buffer = popup_buf, silent = true })
  end, "Compare two selected rows")
end

return M
