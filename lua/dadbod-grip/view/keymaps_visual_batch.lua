-- view/keymaps_visual_batch.lua: Visual-mode batch keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local editor = require("dadbod-grip.editor")

local M = {}

--- Visual mode: selection clamped to the data rows (gg/G/j/k) plus batch
--- edit / delete / NULL over the selected rows.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local kvmap, get_visual_rows = ctx.kvmap, ctx.get_visual_rows

  -- Visual gg/G/j/k: clamp selection to the data-row range so it stops at the
  -- last data row instead of overshooting onto the separator/footer/hint line
  -- (issue #20). Mirrors the normal-mode clamps; like them, it ignores counts.
  local function visual_nav(target_fn)
    return function()
      local session = ctx.session()
      if not session or not session._render then return end
      local r = session._render
      local cursor = vim.api.nvim_win_get_cursor(0)
      local target = view._clamp_data_line(r, target_fn(r, cursor[1]))
      vim.api.nvim_win_set_cursor(0, { target, cursor[2] })
    end
  end
  kvmap("grid_row_first", visual_nav(function() return 0 end), "First data row (visual)")
  kvmap("grid_row_last", visual_nav(function() return math.huge end), "Last data row (visual)")
  kvmap("grid_row_down", visual_nav(function(_, line) return line + 1 end), "Down, clamped to data rows")
  kvmap("grid_row_up", visual_nav(function(_, line) return line - 1 end), "Up, clamped to data rows")

  -- Visual e: batch edit (set all selected cells in column to same value)
  kvmap("grid_v_edit", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    -- Exit visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local col_name = cell.col_name
    local enum_vals = view.enum_hint_values(session, col_name)
    editor.open("Set " .. #row_indices .. " cells (" .. col_name .. ")", cell.value, function(new_val)
      if new_val == nil then return end
      local actual = editor.resolve_null(new_val)
      local st = session.state
      for _, ri in ipairs(row_indices) do
        st = data.add_change(st, ri, col_name, actual)
      end
      view.apply_edit(bufnr, st)
      vim.notify("Set " .. #row_indices .. " cells in " .. col_name, vim.log.levels.INFO)
    end, { enum_values = enum_vals })
  end, "Batch edit selected cells")

  -- Visual d: toggle delete on all selected rows
  kvmap("grid_v_delete", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local st = session.state
    for _, ri in ipairs(row_indices) do
      if st.inserted[ri] then
        st = data.undo_row(st, ri)
      else
        st = data.toggle_delete(st, ri)
      end
    end
    view.apply_edit(bufnr, st)
  end, "Batch toggle delete")

  -- Visual x: set all selected cells to NULL
  kvmap("grid_v_null", function()
    local session = ctx.session()
    if not session then return end
    if not ctx.session_is_editable() then
      vim.notify("Read-only: no primary key detected", vim.log.levels.INFO)
      return
    end
    local cell = view.get_cell(bufnr)
    if not cell then return end
    local row_indices = get_visual_rows()
    if not row_indices or #row_indices == 0 then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local col_name = cell.col_name
    local st = session.state
    for _, ri in ipairs(row_indices) do
      st = data.add_change(st, ri, col_name, nil)
    end
    view.apply_edit(bufnr, st)
    vim.notify("Set " .. #row_indices .. " cells to NULL in " .. col_name, vim.log.levels.INFO)
  end, "Batch set NULL")
end

return M
