-- view/keymaps_nav.lua: Grid navigation keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local ui     = require("dadbod-grip.ui")

local M = {}

--- Cursor movement and column layout: column/row navigation, first/last
--- column, hide/restore columns, width cycling, visibility picker.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local resolve_row_bp = ctx.resolve_row_bp
  local reveal_col_edge = ctx.reveal_col_edge
  local augroup = ctx.augroup
  local NULL_DISPLAY = ctx.NULL_DISPLAY
  local kmap = ctx.kmap

  -- Shared helper: navigate to column by visible index offset.
  -- Works on data rows, header row, and type annotation row.
  local function nav_col(offset, use_finish)
    local session_n = ctx.session()
    if not session_n or not session_n._render then
      vim.notify("nav_col: no session or render", vim.log.levels.WARN)
      return
    end
    local r = session_n._render
    local cols = r.visible_columns or session_n.state.columns
    if #cols == 0 then
      vim.notify("nav_col: 0 columns", vim.log.levels.WARN)
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)

    -- Use current row's byte positions (handles per-row multibyte differences like ·NULL·).
    -- Header/type/separator rows and lines past the last row fall back.
    local ref_bp = resolve_row_bp(r, cursor[1], true)
    if not ref_bp then
      vim.notify("nav_col: no byte positions", vim.log.levels.WARN)
      return
    end

    -- Determine current column index from cursor byte offset
    local col_nr = cursor[2]
    local current_idx = 1
    for i, col in ipairs(cols) do
      local bp = ref_bp[col]
      if bp and col_nr >= bp.start and col_nr <= bp.finish then
        current_idx = i
        break
      elseif bp and col_nr < bp.start then
        current_idx = math.max(1, i - 1)
        break
      end
      current_idx = i  -- past all known columns, snap to last
    end

    local target_idx
    if offset > 0 then
      target_idx = (current_idx % #cols) + 1
    else
      target_idx = current_idx == 1 and #cols or current_idx - 1
    end
    local target_col = cols[target_idx]
    local bp = ref_bp[target_col]
    if not bp then return end
    local win = vim.api.nvim_get_current_win()
    local target_byte = bp.start
    if use_finish then
      -- Land on the start of the cell's last character, not bp.finish, which can
      -- point mid-glyph (… / ·NULL·) where the cursor cannot rest.
      local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
      target_byte = view._cell_end_byte(line, bp.finish)
    end
    vim.api.nvim_win_set_cursor(win, { cursor[1], target_byte })
    -- Reveal the target column's right edge when it runs off-screen (wide columns).
    reveal_col_edge(win, bufnr, cursor[1], bp)
  end

  -- h/l remain native character motions, but registering them makes setup()
  -- remaps and disables effective. Preserve Vim counts and edge behavior.
  local function native_horizontal(motion)
    return function() vim.cmd("normal! " .. vim.v.count1 .. motion) end
  end
  kmap("grid_col_left", native_horizontal("h"), "Move left")
  kmap("grid_col_right", native_horizontal("l"), "Move right")

  -- Tab: next column
  kmap("grid_col_tab", function() nav_col(1) end, "Next column")
  -- S-Tab: previous column
  kmap("grid_col_tab_back", function() nav_col(-1) end, "Previous column")
  -- w: next column (alias for Tab)
  kmap("grid_col_next", function() nav_col(1) end, "Next column")
  -- b: previous column (alias for S-Tab)
  kmap("grid_col_prev", function() nav_col(-1) end, "Previous column")

  -- gg: first data row, same column
  kmap("grid_row_first", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local ds = r.data_start or 4
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { ds, cursor[2] })
  end, "First data row")

  -- G: last data row, same column
  kmap("grid_row_last", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local ds = r.data_start or 4
    local last = ds + #r.ordered - 1
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { last, cursor[2] })
  end, "Last data row")

  -- k: move up, skipping separator and type rows (jump from first data row → header/type row)
  kmap("grid_row_up", function()
    local session = ctx.session()
    if not session or not session._render then
      vim.api.nvim_feedkeys("k", "n", false)
      return
    end
    local r = session._render
    local ds = r.data_start or 4
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1]
    local col_nr = cursor[2]
    local vis_cols = r.visible_columns or (session.state and session.state.columns) or {}
    -- From first data row or separator: jump to nearest useful row above (type row or header)
    if line == ds or line == ds - 1 then
      local target_line = ds - 2  -- line 3 (type row) when ds=5, line 2 (header) when ds=4
      -- Use type_row_byte_positions when landing on type row, else hdr_byte_positions
      local ref_bp = (ds == 5 and r.type_row_byte_positions) or r.hdr_byte_positions
      -- Snap to same column using first data row byte positions
      local data_bp = r.byte_positions and r.byte_positions[1]
      local snap = data_bp and view._snap_col(vis_cols, data_bp, col_nr)
      local col_name = snap and snap.col_name
      local target_col = (col_name and ref_bp and ref_bp[col_name] and ref_bp[col_name].start) or col_nr
      vim.api.nvim_win_set_cursor(0, { target_line, target_col })
    else
      vim.api.nvim_feedkeys("k", "n", false)
    end
  end, "Move up (skip separator)")

  -- j: move down, skipping separator and type rows (jump from header/type row → first data row)
  kmap("grid_row_down", function()
    local session = ctx.session()
    if not session or not session._render then
      vim.api.nvim_feedkeys("j", "n", false)
      return
    end
    local r = session._render
    local ds = r.data_start or 4
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1]
    local col_nr = cursor[2]
    local vis_cols = r.visible_columns or (session.state and session.state.columns) or {}
    -- From header/type/separator zone: jump directly to first data row
    if line >= 2 and line < ds then
      if not r.ordered or #r.ordered == 0 then
        vim.api.nvim_feedkeys("j", "n", false)
        return
      end
      -- Identify column from source row byte positions
      local ref_bp
      if line == 2 then
        ref_bp = r.hdr_byte_positions
      elseif r.type_row_byte_positions and line == ds - 2 then
        ref_bp = r.type_row_byte_positions
      else
        ref_bp = r.hdr_byte_positions
      end
      local snap = ref_bp and view._snap_col(vis_cols, ref_bp, col_nr)
      local col_name = snap and snap.col_name
      -- Land on same column in first data row
      local data_bp = r.byte_positions and r.byte_positions[1]
      local target_col = (col_name and data_bp and data_bp[col_name] and data_bp[col_name].start) or col_nr
      vim.api.nvim_win_set_cursor(0, { ds, target_col })
    else
      vim.api.nvim_feedkeys("j", "n", false)
    end
  end, "Move down (skip separator)")

  -- ^: first column of current row (works on header, type, and data rows)
  kmap("grid_col_first2", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local bp_row = resolve_row_bp(r, cursor[1])
    if not bp_row then return end
    local bp = bp_row[cols[1]]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], bp.start })
  end, "First column")

  -- 0: first column (same as ^)
  kmap("grid_col_first", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local bp_row = resolve_row_bp(r, cursor[1])
    if not bp_row then return end
    local bp = bp_row[cols[1]]
    if not bp then return end
    vim.api.nvim_win_set_cursor(0, { cursor[1], bp.start })
  end, "First column")

  -- -: hide column under cursor
  kmap("grid_hide_col", function()
    local session = ctx.session()
    if not session then return end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a column to hide", vim.log.levels.INFO)
      return
    end
    if not session.hidden_columns then session.hidden_columns = {} end
    -- Count visible columns
    local visible = 0
    for _, col in ipairs(session.state.columns) do
      if not session.hidden_columns[col] then visible = visible + 1 end
    end
    if visible <= 1 then
      vim.notify("Cannot hide last visible column", vim.log.levels.INFO)
      return
    end
    session.hidden_columns[cell.col_name] = true
    vim.notify("Hidden: " .. cell.col_name, vim.log.levels.INFO)
    view.render(bufnr, session.state)
  end, "Hide column under cursor")

  -- g-: restore all hidden columns
  kmap("grid_restore_cols", function()
    local session = ctx.session()
    if not session then return end
    if not session.hidden_columns or not next(session.hidden_columns) then
      vim.notify("No hidden columns", vim.log.levels.INFO)
      return
    end
    local count = 0
    for _ in pairs(session.hidden_columns) do count = count + 1 end
    session.hidden_columns = {}
    vim.notify("Restored " .. count .. " hidden column(s)", vim.log.levels.INFO)
    view.render(bufnr, session.state)
  end, "Restore all hidden columns")

  -- =: minimize column to name width, or reset to default if already minimized
  kmap("grid_col_width", function()
    local session = ctx.session()
    if not session then return end
    local col = ctx.cursor_column()
    if not col then
      vim.notify("Move cursor to a column to resize", vim.log.levels.INFO)
      return
    end
    if not session.col_width_overrides then session.col_width_overrides = {} end
    if not session._col_cycle        then session._col_cycle = {} end

    -- Fixed indicator budget: 3 display chars covers " ▲1"/`` ▼2" (stacked sort).
    -- Using a fixed constant means adding/removing stacked sorts after pressing `=`
    -- never clips the header: the budget doesn't shrink when you press `=` on
    -- a column with only a single-arrow sort (▲ = ind_w 2) and then stack more.
    local ind_w = 3

    local cycle = session._col_cycle[col]
    if cycle == "compact" then
      -- compact → expanded: scan ALL rows, no MAX_COL_WIDTH cap
      local st = session.state
      local full_w = vim.fn.strdisplaywidth(col) + ind_w
      if st then
        local ordered = data.get_ordered_rows(st)
        for _, row_idx in ipairs(ordered) do
          local v = data.effective_value(st, row_idx, col)
          local display = (v == nil or v == "") and NULL_DISPLAY or tostring(v)
          full_w = math.max(full_w, vim.fn.strdisplaywidth(display))
        end
      end
      session.col_width_overrides[col] = full_w
      session._col_cycle[col] = "expanded"
      vim.notify("Column expanded: " .. col, vim.log.levels.INFO)
    elseif cycle == "expanded" then
      -- expanded → auto: remove override
      session.col_width_overrides[col] = nil
      session._col_cycle[col] = nil
      vim.notify("Column reset: " .. col, vim.log.levels.INFO)
    else
      -- auto → compact: collapse to name width only; indicator will clip, that's intentional
      local compact_w = vim.fn.strdisplaywidth(col)
      session.col_width_overrides[col] = compact_w
      session._col_cycle[col] = "compact"
      vim.notify("Column compacted: " .. col, vim.log.levels.INFO)
    end
    view.render(bufnr, session.state)
  end, "Compact/expand/reset column width (cycles)")

  -- gH: multi-select column visibility picker
  kmap("grid_col_vis", function()
    local session = ctx.session()
    if not session then return end
    if not session.hidden_columns then session.hidden_columns = {} end

    local cols = session.state.columns
    -- Pending is a shadow copy; only written to session on <CR>
    local pending = {}
    for k, v in pairs(session.hidden_columns) do pending[k] = v end

    local max_w = 6  -- "[✓] " prefix = 4, plus min width
    for _, col in ipairs(cols) do
      if #col + 6 > max_w then max_w = #col + 6 end
    end
    local width  = math.min(max_w + 4, vim.o.columns - 4)
    local height = math.min(#cols + 2, vim.o.lines - 6)

    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = pbuf })

    local function render_lines()
      local lines = {}
      for _, col in ipairs(cols) do
        local vis = not pending[col]
        lines[#lines + 1] = (vis and "  [✓] " or "  [ ] ") .. col
      end
      vim.api.nvim_set_option_value("modifiable", true, { buf = pbuf })
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = pbuf })
    end

    render_lines()

    local pwin = vim.api.nvim_open_win(pbuf, true, {
      relative   = "editor",
      row        = math.floor((vim.o.lines - height) / 2),
      col        = math.floor((vim.o.columns - width) / 2),
      width      = width,
      height     = height,
      style      = "minimal",
      border     = ui.border(),
      title      = " Columns  <Space> toggle  <CR> apply  q cancel ",
      title_pos  = "center",
      zindex     = 55,
    })
    vim.api.nvim_set_option_value("cursorline", true, { win = pwin })
    vim.api.nvim_win_set_cursor(pwin, { 1, 0 })

    local function close_picker()
      if vim.api.nvim_win_is_valid(pwin) then vim.api.nvim_win_close(pwin, true) end
    end

    local function apply()
      -- Guard: must keep at least one visible column
      local visible_count = 0
      for _, col in ipairs(cols) do
        if not pending[col] then visible_count = visible_count + 1 end
      end
      if visible_count == 0 then
        vim.notify("Cannot hide all columns", vim.log.levels.INFO)
        return
      end
      session.hidden_columns = pending
      close_picker()
      view.render(bufnr, session.state)
    end

    local bopts = { buffer = pbuf, nowait = true }
    vim.keymap.set("n", "<Space>", function()
      local lnum = vim.api.nvim_win_get_cursor(pwin)[1]
      local col = cols[lnum]
      if not col then return end
      if pending[col] then
        pending[col] = nil
      else
        pending[col] = true
      end
      render_lines()
      vim.api.nvim_win_set_cursor(pwin, { lnum, 0 })
    end, bopts)
    vim.keymap.set("n", "<CR>", apply, bopts)
    vim.keymap.set("n", "q",    close_picker, bopts)
    vim.keymap.set("n", "<Esc>", close_picker, bopts)

    vim.api.nvim_create_autocmd("WinLeave", {
      group  = augroup,
      buffer = pbuf, once = true,
      callback = function() close_picker() end,
    })
  end, "Toggle column visibility (multi-select)")

  -- $: last column of current row (works on header, type, and data rows)
  kmap("grid_col_last", function()
    local session = ctx.session()
    if not session or not session._render then return end
    local r = session._render
    local cols = r.visible_columns or session.state.columns
    local cursor = vim.api.nvim_win_get_cursor(0)
    local bp_row = resolve_row_bp(r, cursor[1])
    if not bp_row then return end
    local bp = bp_row[cols[#cols]]
    if not bp then return end
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(win, { cursor[1], bp.start })
    reveal_col_edge(win, bufnr, cursor[1], bp)
  end, "Last column")

  -- e: vim-like end-of-cell. First moves to end of current cell; when already there, advances.
  kmap("grid_col_end", function()
    local session_e = ctx.session()
    if not session_e or not session_e._render then return end
    local r = session_e._render
    local cols = r.visible_columns or session_e.state.columns
    if #cols == 0 then return end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local ref_bp = resolve_row_bp(r, cursor[1], true)
    if not ref_bp then return end
    local col_nr = cursor[2]
    local current_idx = 1
    for i, col in ipairs(cols) do
      local bp = ref_bp[col]
      if bp and col_nr >= bp.start and col_nr <= bp.finish then
        current_idx = i
        break
      elseif bp and col_nr < bp.start then
        current_idx = math.max(1, i - 1)
        break
      end
      current_idx = i
    end
    local current_col = cols[current_idx]
    local bp = ref_bp[current_col]
    if not bp then nav_col(1, true); return end
    -- Use the start byte of the cell's last character: bp.finish can point
    -- mid-glyph (… / ·NULL·) where the normal-mode cursor can never rest, which
    -- would wedge `e` in place. When already at that end, advance to next column.
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
    local end_col = view._cell_end_byte(line, bp.finish)
    if cursor[2] < end_col then
      vim.api.nvim_win_set_cursor(0, { cursor[1], end_col })
    else
      nav_col(1, true)
    end
  end, "End of current cell (then next)")
end

return M
