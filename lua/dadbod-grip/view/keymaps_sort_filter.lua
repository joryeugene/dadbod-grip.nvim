-- view/keymaps_sort_filter.lua: Sort, filter and query-shape keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local qmod   = require("dadbod-grip.query")
local ui     = require("dadbod-grip.ui")

local M = {}

--- Sorting, filtering, filter presets, export-to-file and pagination.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local kmap = ctx.kmap

  -- Helper: warn if pending changes, return true if user wants to proceed
  local function confirm_discard_changes(action_name)
    local session_c = ctx.session()
    if not session_c then return true end
    if not data.has_changes(session_c.state) then return true end
    local staged = data.count_staged(session_c.state)
    local choice = vim.fn.confirm(
      string.format("%s will discard %d unapplied change(s). Continue?", action_name, staged),
      "&Yes\n&Cancel", 2
    )
    return choice == 1
  end

  -- s: sort by column (replaces existing sort)
  kmap("grid_sort", function()
    local session_s = ctx.session()
    if not session_s or not session_s.query_spec then return end
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column to sort", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Sort") then return end
    local new_spec = qmod.toggle_sort(session_s.query_spec, col_name)
    if session_s.on_requery then session_s.on_requery(bufnr, new_spec) end
  end, "Sort by column")

  -- S: add/toggle secondary sort (stacked)
  kmap("grid_sort_stack", function()
    local session_s = ctx.session()
    if not session_s or not session_s.query_spec then return end
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column to sort", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Sort") then return end
    local new_spec = qmod.add_sort(session_s.query_spec, col_name)
    if session_s.on_requery then session_s.on_requery(bufnr, new_spec) end
  end, "Add secondary sort")

  -- f: quick filter by cell value
  kmap("grid_filter_cell", function()
    local session_f = ctx.session()
    if not session_f or not session_f.query_spec then return end
    local cell = view.get_cell(bufnr)
    if not cell then
      vim.notify("Move cursor to a cell to filter", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Filter") then return end
    local new_spec = qmod.quick_filter(session_f.query_spec, cell.col_name, cell.value)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
    local display = cell.value and (cell.col_name .. " = " .. tostring(cell.value):sub(1, 30)) or (cell.col_name .. " IS NULL")
    vim.notify("Filtered: " .. display, vim.log.levels.INFO)
  end, "Quick filter by cell value")

  -- <C-f>: freeform WHERE clause filter
  kmap("grid_filter_where", function()
    local session_f = ctx.session()
    if not session_f or not session_f.query_spec then return end
    if not confirm_discard_changes("Filter") then return end
    local input = ui.input({ prompt = "WHERE clause (e.g. status='x' AND amount>0): " })
    if not input then return end
    local new_spec = qmod.add_filter(session_f.query_spec, input)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
  end, "Filter rows (WHERE clause)")

  -- F: clear all filters
  kmap("grid_filter_clear", function()
    local session_f = ctx.session()
    if not session_f or not session_f.query_spec then return end
    if not qmod.has_filters(session_f.query_spec) then
      vim.notify("No active filters", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Clear filters") then return end
    local new_spec = qmod.clear_filters(session_f.query_spec)
    if session_f.on_requery then session_f.on_requery(bufnr, new_spec) end
    vim.notify("Filters cleared", vim.log.levels.INFO)
  end, "Clear all filters")

  -- gn: filter column IS NULL
  kmap("grid_filter_null", function()
    local session_n = ctx.session()
    if not session_n or not session_n.query_spec then return end
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column first", vim.log.levels.INFO)
      return
    end
    local new_spec = qmod.quick_filter(session_n.query_spec, col_name, nil)
    if session_n.on_requery then session_n.on_requery(bufnr, new_spec) end
    vim.notify(col_name .. " IS NULL", vim.log.levels.INFO)
  end, "Filter: column IS NULL")

  -- gF: interactive filter builder (=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL)
  kmap("grid_filter_build", function()
    local session_gF = ctx.session()
    if not session_gF or not session_gF.query_spec then return end

    -- Resolve column name from cursor (data row or header/type row)
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column first", vim.log.levels.INFO)
      return
    end

    if not confirm_discard_changes("Filter") then return end

    local op = ui.input({
      prompt = "Filter " .. col_name .. " [=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL]: ",
    })
    if not op then return end
    op = op:upper():match("^%s*(.-)%s*$")  -- trim + uppercase

    local value
    if op ~= "NULL" and op ~= "NOT NULL" then
      local value_prompt = op == "LIKE" and "Value (wildcards auto-added, or type %custom%): "
        or op == "IN" and "Values (comma-separated, e.g. 1,2,3 or alice,bob): "
        or op == "BETWEEN" and "Range (low,high, e.g. 10,100 or 2024-01-01,2024-12-31): "
        or "Value: "
      -- Empty is a legal filter value (e.g. `= ''`), so it is not a cancel.
      local val = ui.input({ prompt = value_prompt, allow_empty = true })
      if not val then return end
      value = val
    end

    local ok3, clause = pcall(qmod.build_filter_clause, col_name, op, value)
    if not ok3 then
      vim.notify("Invalid filter: " .. tostring(clause), vim.log.levels.WARN)
      return
    end

    local new_spec = qmod.add_filter(session_gF.query_spec, clause)
    if session_gF.on_requery then session_gF.on_requery(bufnr, new_spec) end
    local display
    if op == "NULL" or op == "NOT NULL" then
      display = col_name .. " IS " .. (op == "NULL" and "" or "NOT ") .. "NULL"
    elseif op == "BETWEEN" then
      display = col_name .. " BETWEEN " .. tostring(value or "")
    else
      display = col_name .. " " .. op .. " " .. tostring(value or "")
    end
    vim.notify("Filtered: " .. display:sub(1, 60) .. "  (F to clear)", vim.log.levels.INFO)
  end, "Filter builder (=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL)")

  -- gX: export result set to file (csv/json/sql)
  kmap("grid_export_file", function() view.do_export(bufnr) end, "Export to file (csv/json/sql)")

  -- gp: load a saved filter preset
  kmap("grid_preset_load", function()
    local session_fp = ctx.session()
    if not session_fp or not session_fp.query_spec then return end
    local tbl = session_fp.state.table_name
    if not tbl then
      vim.notify("Filter presets require a table context", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Load filter preset") then return end
    local filters = require("dadbod-grip.filters")
    filters.pick(tbl, function(preset)
      local new_spec = qmod.set_filters(session_fp.query_spec, preset.clause)
      if session_fp.on_requery then session_fp.on_requery(bufnr, new_spec) end
      vim.notify("Filter: " .. preset.name, vim.log.levels.INFO)
    end)
  end, "Load filter preset")

  -- gP: save current filter as preset
  kmap("grid_preset_save", function()
    local session_fp = ctx.session()
    if not session_fp or not session_fp.query_spec then return end
    local tbl = session_fp.state.table_name
    if not tbl then
      vim.notify("Filter presets require a table context", vim.log.levels.INFO)
      return
    end
    if not qmod.has_filters(session_fp.query_spec) then
      vim.notify("No active filters to save", vim.log.levels.INFO)
      return
    end
    -- Combine the user's filters into one clause. Pinned filters are excluded:
    -- an FK-navigation clause is bound to one parent row, so baking it into a
    -- reusable preset would silently scope every later load to that row.
    local clauses = {}
    for _, f in ipairs(qmod.user_filters(session_fp.query_spec)) do
      table.insert(clauses, "(" .. f.clause .. ")")
    end
    local combined = table.concat(clauses, " AND ")
    local name = ui.input({ prompt = "Save filter as: " })
    if not name then return end
    local filters = require("dadbod-grip.filters")
    filters.save(tbl, name, combined)
  end, "Save filter as preset")

  -- ]p: next page
  kmap("grid_next_page2", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    -- Check if we're on the last page
    if session_p.total_rows then
      local total_pages = math.max(1, math.ceil(session_p.total_rows / session_p.query_spec.page_size))
      if session_p.query_spec.page >= total_pages then
        vim.notify("Already on last page", vim.log.levels.INFO)
        return
      end
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.next_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Next page")

  -- [p: previous page
  kmap("grid_prev_page2", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    if session_p.query_spec.page <= 1 then
      vim.notify("Already on first page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.prev_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Previous page")

  -- ]P: jump to last page
  kmap("grid_last_page", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    if not session_p.total_rows then
      vim.notify("Total rows unknown", vim.log.levels.INFO)
      return
    end
    local total_pages = math.max(1, math.ceil(session_p.total_rows / session_p.query_spec.page_size))
    if session_p.query_spec.page >= total_pages then
      vim.notify("Already on last page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.set_page(session_p.query_spec, total_pages)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Last page")

  -- [P: jump to first page
  kmap("grid_first_page", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    if session_p.query_spec.page <= 1 then
      vim.notify("Already on first page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.set_page(session_p.query_spec, 1)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "First page")

  -- H/L: ergonomic page navigation (prev/next): single-key aliases for [p/]p
  kmap("grid_prev_page", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    if session_p.query_spec.page <= 1 then
      vim.notify("Already on first page", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.prev_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Previous page")

  kmap("grid_next_page", function()
    local session_p = ctx.session()
    if not session_p or not session_p.query_spec then return end
    if session_p.total_rows then
      local total_pages = math.max(1, math.ceil(session_p.total_rows / session_p.query_spec.page_size))
      if session_p.query_spec.page >= total_pages then
        vim.notify("Already on last page", vim.log.levels.INFO)
        return
      end
    end
    if not confirm_discard_changes("Page change") then return end
    local new_spec = qmod.next_page(session_p.query_spec)
    if session_p.on_requery then session_p.on_requery(bufnr, new_spec) end
  end, "Next page")

  -- X: reset all query modifiers (sorts, filters, page)
  kmap("grid_reset_view", function()
    local session_x = ctx.session()
    if not session_x or not session_x.query_spec then return end
    local spec = session_x.query_spec
    -- Pinned filters are the grid's baseline (FK context), not something a reset
    -- clears — a grid holding only those IS at its defaults.
    if #spec.sorts == 0 and not qmod.has_filters(spec) and spec.page == 1 then
      vim.notify("View already at defaults", vim.log.levels.INFO)
      return
    end
    if not confirm_discard_changes("Reset view") then return end
    local new_spec = qmod.reset(session_x.query_spec)
    if session_x.on_requery then session_x.on_requery(bufnr, new_spec) end
    vim.notify("View reset", vim.log.levels.INFO)
  end, "Reset view (clear sort/filter/page)")
end

return M
