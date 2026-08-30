-- view/keymaps_aggregate.lua: Aggregate, stats and export keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local data   = require("dadbod-grip.data")
local db     = require("dadbod-grip.db")
local qmod   = require("dadbod-grip.query")

local M = {}

--- Aggregates and column stats, table profile, clipboard export, EXPLAIN of
--- the current query and opening a URL from the cell under the cursor.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local open_info_float = ctx.open_info_float
  local kmap, kvmap, get_visual_rows = ctx.kmap, ctx.kvmap, ctx.get_visual_rows

  -- ga: aggregate current column (normal: all rows, visual: selected rows).
  -- row_indices = nil means "the whole column". Normal mode must NOT consult
  -- '< / '>: those marks hold the *previous* visual selection, so ga silently
  -- aggregated a stale range once the user had selected anything at all.
  local function aggregate_column(row_indices)
    local session_a = ctx.session()
    if not session_a or not session_a._render then return end
    local r = session_a._render
    local st_a = session_a.state

    -- Works from a data row, the header row or the type row.
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column first", vim.log.levels.INFO)
      return
    end

    -- Collect values for the single column
    local targets = row_indices or r.ordered
    local values = {}
    local numeric_values = {}
    for _, row_idx in ipairs(targets) do
      local val = data.effective_value(st_a, row_idx, col_name)
      if val ~= nil then
        table.insert(values, val)
        local num = tonumber(val)
        if num then table.insert(numeric_values, num) end
      end
    end

    if #values == 0 then
      vim.notify("ga: " .. col_name .. ": no values", vim.log.levels.INFO)
      return
    end

    local agg_parts = { "ga: " .. col_name .. "  Count: " .. #values }
    if #numeric_values > 0 then
      local sum = 0
      local min_v, max_v = numeric_values[1], numeric_values[1]
      for _, n in ipairs(numeric_values) do
        sum = sum + n
        if n < min_v then min_v = n end
        if n > max_v then max_v = n end
      end
      local avg = sum / #numeric_values
      table.insert(agg_parts, string.format("Sum: %g", sum))
      table.insert(agg_parts, string.format("Avg: %.2f", avg))
      table.insert(agg_parts, string.format("Min: %g", min_v))
      table.insert(agg_parts, string.format("Max: %g", max_v))
    end

    vim.notify(table.concat(agg_parts, "  │  "), vim.log.levels.INFO)
  end

  kmap("grid_aggregate", function() aggregate_column(nil) end, "Aggregate current column")
  kvmap("grid_aggregate", function()
    local rows_a = get_visual_rows()
    if not rows_a or #rows_a == 0 then return end
    aggregate_column(rows_a)
  end, "Aggregate selected rows in column")

  -- gS: column statistics with a distribution histogram
  kmap("grid_col_stats", function()
    local session_cs = ctx.session()
    if not session_cs or not session_cs.state.table_name then
      vim.notify("Column stats requires a table name", vim.log.levels.INFO)
      return
    end
    local col_name = ctx.cursor_column()
    if not col_name then
      vim.notify("Move cursor to a column", vim.log.levels.INFO)
      return
    end
    local st_cs = session_cs.state

    -- The data type decides bucketed-vs-top-values, so fill the session cache
    -- if some other view has not already (same lazy pattern as K and gy). A
    -- failure here is not fatal: an unknown type profiles as top values.
    if not session_cs._column_info then
      local info, info_err = db.get_column_info(st_cs.table_name, st_cs.url)
      if not info_err then session_cs._column_info = info end
    end
    local data_type
    for _, ci in ipairs(session_cs._column_info or {}) do
      if ci.column_name == col_name then
        data_type = ci.data_type
        break
      end
    end

    local profile = require("dadbod-grip.profile")
    local cs, cs_err = profile.gather_column(st_cs.table_name, col_name, data_type, st_cs.url)
    if not cs then
      vim.notify("Stats query failed: " .. (cs_err or "unknown error"), vim.log.levels.WARN)
      return
    end

    local grip_win = vim.api.nvim_get_current_win()
    open_info_float(grip_win, profile.build_column_lines(cs), { title = " Column Stats " })
  end, "Column statistics")

  -- gR: table profile report
  kmap("grid_profile", function()
    local session_pr = ctx.session()
    if not session_pr or not session_pr.state.table_name then
      vim.notify("Profile requires a table name", vim.log.levels.INFO)
      return
    end
    local profile = require("dadbod-grip.profile")
    profile.open(session_pr.state.table_name, session_pr.state.url)
  end, "Table profile report")

  -- gE: export in multiple formats
  kmap("grid_export_clip", function()
    view.export_to_clipboard(bufnr)
  end, "Export in multiple formats")

  -- gQ: explain current query (shortcut for :GripExplain)
  kmap("grid_explain", function()
    local session_x = ctx.session()
    if not session_x then return end
    local explain_sql
    if session_x.query_spec then
      explain_sql = qmod.build_sql(session_x.query_spec)
    elseif session_x.query_sql then
      explain_sql = session_x.query_sql
    end
    if not explain_sql or explain_sql == "" then
      vim.notify("No query to explain", vim.log.levels.INFO)
      return
    end
    -- Table arg form: keeps multi-line SQL in one piece (see switch_view).
    vim.cmd({ cmd = "GripExplain", args = { explain_sql } })
  end, "Explain current query")

  -- gx: open URL in current cell (mirrors cell editor gx and Vim convention)
  kmap("grid_url_open", function()
    local cell = view.get_cell(bufnr)
    if not cell or not cell.value then
      vim.notify("No cell value", vim.log.levels.INFO)
      return
    end
    local val = tostring(cell.value):match("^%s*(.-)%s*$")
    if val:match("^https?://") or val:match("^ftp://") then
      if vim.ui.open then
        vim.ui.open(val)
      elseif vim.fn.has("mac") == 1 then
        vim.fn.jobstart({ "open", val }, { detach = true })
      else
        vim.fn.jobstart({ "xdg-open", val }, { detach = true })
      end
    else
      vim.notify("Not a URL", vim.log.levels.INFO)
    end
  end, "Open URL in current cell")
end

return M
