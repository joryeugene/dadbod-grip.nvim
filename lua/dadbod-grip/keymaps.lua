-- keymaps.lua: catalog and validated binding for persistent Grip surfaces.

local M = { catalog = {}, defaults = {} }
local by_action = {}

local function add(category, surfaces, modes, entries, requires)
  for _, entry in ipairs(entries) do
    local action, default, description = entry[1], entry[2], entry[3]
    assert(not by_action[action], "duplicate keymap action: " .. action)
    local record = {
      action = action,
      default = default,
      description = description,
      category = category,
      surfaces = surfaces,
      modes = modes,
    }
    if requires then record.requires = requires end
    table.insert(M.catalog, record)
    M.defaults[action] = default
    by_action[action] = record
  end
end

local all = { "grid", "query_pad", "sidebar" }
local grid = { "grid" }
local query_pad = { "query_pad" }
local sidebar = { "sidebar" }
local editor = { "cell_editor" }
local normal = { "n" }
local visual = { "x" }

add("navigation", all, normal, {
  { "palette", "<C-p>", "Opens the searchable command palette." },
  { "help", "?", "Opens the keymap help." },
  { "er_diagram", "gG", "Opens the entity-relationship diagram." },
  { "connections", "gC", "Opens the connection picker." },
  { "connections_alt", "<C-g>", "Opens the connection picker with its alternate key." },
  { "table_picker", "gT", "Opens the table picker." },
  { "table_picker_alt", "gt", "Opens the table picker with its alternate key." },
  { "query_history", "gh", "Opens the query history." },
  { "load_saved", "gq", "Loads a saved query." },
  { "welcome", "Q", "Returns to the welcome screen." },
})

add("navigation", { "grid", "sidebar" }, normal, {
  { "query_pad", "q", "Opens or focuses the query pad." },
})

add("ai", grid, normal, {
  { "ai", "A", "Generates SQL from the grid with the configured AI provider." },
})

add("navigation", all, normal, {
  { "schema_browser", "gb", "Opens, focuses, or closes the schema browser." },
})

add("navigation", { "query_pad", "sidebar" }, normal, {
  { "goto_grid", "gw", "Focuses the grid window." },
  { "open_notebook", "gn", "Opens a SQL or Markdown notebook in the query pad." },
})

add("navigation", { "grid", "query_pad" }, normal, {
  { "table_picker_go", "go", "Opens the table picker with the short key." },
})

add("views", all, normal, {
  { "tab_1", "1", "Opens the first surface-specific view." },
  { "tab_2", "2", "Opens the second surface-specific view." },
  { "tab_3", "3", "Opens the third surface-specific view." },
  { "tab_4", "4", "Opens the entity-relationship view." },
  { "tab_5", "5", "Opens the column statistics view." },
  { "tab_6", "6", "Opens the columns view." },
  { "tab_7", "7", "Opens the foreign-keys view." },
  { "tab_8", "8", "Opens the indexes view." },
  { "tab_9", "9", "Opens the constraints view." },
})

add("grid navigation", grid, { "n", "x" }, {
  { "grid_row_down", "j", "Moves down within the data rows." },
  { "grid_row_up", "k", "Moves up within the data rows." },
  { "grid_row_first", "gg", "Moves to the first data row." },
  { "grid_row_last", "G", "Moves to the last data row." },
})

add("grid navigation", grid, normal, {
  { "grid_col_left", "h", "Moves left with native Vim count and boundary behavior." },
  { "grid_col_right", "l", "Moves right with native Vim count and boundary behavior." },
  { "grid_col_next", "w", "Moves to the next column." },
  { "grid_col_prev", "b", "Moves to the previous column." },
  { "grid_col_tab", "<Tab>", "Moves to the next column with Tab." },
  { "grid_col_tab_back", "<S-Tab>", "Moves to the previous column with Shift-Tab." },
  { "grid_col_end", "e", "Moves to the end of the cell and then advances." },
  { "grid_col_first", "0", "Moves to the first column." },
  { "grid_col_first2", "^", "Moves to the first column with the alternate key." },
  { "grid_col_last", "$", "Moves to the last column." },
  { "grid_prev_mod", "{", "Moves to the previous modified row." },
  { "grid_next_mod", "}", "Moves to the next modified row." },
})

add("grid editing", grid, normal, {
  { "grid_edit", "i", "Opens the current cell for editing." },
  { "grid_edit_enter", "<CR>", "Opens the current cell for editing with Enter." },
  { "grid_cell_buffer", "gB", "Opens the current cell in a split buffer." },
  { "grid_null", "x", "Stages NULL for the current cell." },
  { "grid_column_set", "gU", "Stages one value across the visible column." },
  { "grid_paste", "p", "Pastes the clipboard into the current cell." },
  { "grid_paste_rows", "P", "Pastes lines into consecutive rows." },
  { "grid_insert", "o", "Stages a new blank row." },
  { "grid_clone", "c", "Clones the current row with primary keys cleared." },
  { "grid_delete", "d", "Toggles staged deletion for the current row." },
  { "grid_apply", "a", "Applies all staged database changes." },
  { "grid_undo", "u", "Undoes the latest staged change." },
  { "grid_redo", "<C-r>", "Redoes the latest undone change." },
  { "grid_undo_all", "U", "Clears all staged changes." },
})

add("grid editing", grid, visual, {
  { "grid_v_edit", "e", "Stages one value across the selected cells." },
  { "grid_v_delete", "d", "Toggles staged deletion for the selected rows." },
  { "grid_v_null", "x", "Stages NULL across the selected cells." },
  { "grid_v_yank", "y", "Yanks the selected cells." },
  { "grid_v_compare", "gd", "Compares exactly two selected rows." },
})

add("grid display", grid, normal, {
  { "grid_hide_col", "-", "Hides the current column." },
  { "grid_restore_cols", "g-", "Restores all hidden columns." },
  { "grid_col_vis", "gH", "Opens the column visibility picker." },
  { "grid_col_width", "=", "Cycles the current column width." },
  { "grid_type_row", "T", "Toggles the column type row." },
  { "grid_live_sql", "gl", "Toggles the live SQL preview." },
})

add("grid display", grid, { "n", "x" }, {
  { "grid_row_view", "K", "Opens the current row or selection as key-value pairs." },
})

add("grid filtering", grid, normal, {
  { "grid_sort", "s", "Cycles sorting for the current column." },
  { "grid_sort_stack", "S", "Adds or cycles a stacked sort." },
  { "grid_filter_cell", "f", "Filters by the current cell value." },
  { "grid_filter_null", "gn", "Filters the current column for NULL values." },
  { "grid_filter_build", "gF", "Opens the structured filter builder." },
  { "grid_filter_where", "<C-f>", "Prompts for a free-form WHERE expression." },
  { "grid_filter_clear", "F", "Clears user filters while preserving pinned context." },
  { "grid_preset_load", "gp", "Loads a saved filter preset." },
  { "grid_preset_save", "gP", "Saves the current filters as a preset." },
  { "grid_reset_view", "X", "Clears sorting and user filters and returns to page one." },
  { "grid_next_page", "L", "Loads the next page." },
  { "grid_prev_page", "H", "Loads the previous page." },
  { "grid_next_page2", "]p", "Loads the next page with the bracket alias." },
  { "grid_prev_page2", "[p", "Loads the previous page with the bracket alias." },
  { "grid_last_page", "]P", "Loads the last page." },
  { "grid_first_page", "[P", "Loads the first page." },
})

add("grid inspection", grid, normal, {
  { "grid_explain_cell", "ge", "Explains the current cell." },
  { "grid_json_tree", "gK", "Opens the current JSON value as a tree." },
  { "grid_preview_sql", "gs", "Previews the staged SQL." },
  { "grid_copy_sql", "gc", "Copies the staged SQL." },
  { "grid_table_info", "gi", "Opens compact table information." },
  { "grid_table_props", "gI", "Opens detailed table properties." },
  { "grid_rename_col", "gN", "Renames the displayed column header." },
  { "grid_col_stats", "gS", "Opens statistics for the current column." },
  { "grid_profile", "gR", "Profiles every column in the current table." },
  { "grid_show_ddl", "gV", "Shows the CREATE TABLE statement." },
  { "grid_explain", "gQ", "Shows the query plan." },
  { "grid_url_open", "gx", "Opens the URL in the current cell." },
  { "grid_diff", "gD", "Compares the current table with another table." },
})

add("grid inspection", grid, { "n", "x" }, {
  { "grid_aggregate", "ga", "Aggregates the current column or selection." },
})

add("grid export", grid, normal, {
  { "grid_export_clip", "gE", "Exports the chosen result scope to the clipboard." },
  { "grid_export_file", "gX", "Exports the chosen result scope to a file." },
  { "grid_yank_cell", "y", "Yanks the current cell." },
  { "grid_yank_row", "Y", "Yanks the current row as CSV." },
  { "grid_yank_table", "gY", "Yanks the complete result as CSV." },
  { "grid_yank_md", "gy", "Yanks the result as a Markdown table." },
})

add("grid relationships", grid, normal, {
  { "grid_fk_follow", "gf", "Follows the foreign key in the current cell." },
  { "grid_fk_referencing", "gm", "Opens rows that reference the current row." },
  { "grid_fk_back", "<C-o>", "Returns to the previous relationship result." },
})

add("grid workflow", grid, normal, {
  { "grid_refresh", "r", "Refreshes the current result." },
  { "grid_watch", "gW", "Toggles automatic result refresh." },
  { "grid_write_mode", "g!", "Toggles write-back for supported local files." },
  { "grid_open_edit", "gO", "Reopens a read-only result as an editable table." },
  { "grid_fill", "gA", "Stages rows generated by the configured AI provider." },
  { "grid_pin", "gL", "Pins or unpins the current result." },
  { "grid_results", "gJ", "Opens the result switcher." },
})

add("query pad", query_pad, { "n", "i", "x" }, {
  { "qpad_execute", "<C-CR>", "Executes the current SQL block or selection." },
})

add("query pad", query_pad, { "n", "x" }, {
  { "qpad_execute_new", "<S-CR>", "Executes SQL in a new result split." },
})

add("query pad", query_pad, normal, {
  { "qpad_save", "<C-s>", "Saves the query." },
  { "qpad_ai", "gA", "Generates SQL in the query pad with the configured AI provider." },
  { "qpad_format", "gF", "Formats the query pad SQL." },
  { "qpad_close", "q", "Closes the query pad and returns to the welcome screen." },
})

add("query completion", query_pad, { "i" }, {
  { "qpad_complete", "<C-Space>", "Triggers SQL completion." },
  { "qpad_complete_next", "<Tab>", "Triggers completion or selects the next item." },
  { "qpad_complete_prev", "<S-Tab>", "Selects the previous completion item or inserts Shift-Tab." },
  { "qpad_complete_down", "<Down>", "Selects the next completion item or moves down." },
  { "qpad_complete_up", "<Up>", "Selects the previous completion item or moves up." },
  { "qpad_complete_accept", "<CR>", "Accepts the selected completion item or inserts a newline." },
}, "completion")

add("sidebar", sidebar, normal, {
  { "sidebar_open", "<CR>", "Opens the table under the cursor." },
  { "sidebar_open_spl", "<S-CR>", "Opens the table under the cursor in a new split." },
  { "sidebar_expand", "l", "Expands the table under the cursor." },
  { "sidebar_collapse", "h", "Collapses the table under the cursor." },
  { "sidebar_expand_z", "zo", "Expands the table with the fold-style key." },
  { "sidebar_collap_z", "zc", "Collapses the table with the fold-style key." },
  { "sidebar_expand_all", "L", "Expands every table." },
  { "sidebar_collap_all", "H", "Collapses every table." },
  { "sidebar_filter", "/", "Filters tables by name." },
  { "sidebar_filter_c", "F", "Clears the sidebar filter." },
  { "sidebar_next", "n", "Moves to the next table." },
  { "sidebar_prev", "N", "Moves to the previous table." },
  { "sidebar_refresh", "r", "Refreshes the schema." },
  { "sidebar_refresh2", "R", "Force-refreshes the schema." },
  { "sidebar_yank", "y", "Yanks the current table or column name." },
  { "sidebar_open_s", "go", "Opens the current table with newest rows first." },
  { "sidebar_close", "<Esc>", "Closes the schema sidebar." },
  { "sidebar_drop", "D", "Drops the current table after confirmation." },
  { "sidebar_create", "+", "Creates a table." },
  { "sidebar_attach", "ga", "Attaches a database to the current DuckDB connection." },
  { "sidebar_detach", "gd", "Detaches a database from the current DuckDB connection." },
  { "sidebar_conns", "gc", "Opens the connection picker from the sidebar." },
})

add("cell editor", editor, { "n", "i" }, {
  { "editor_save", "<CR>", "Saves the edited cell." },
  { "editor_save_alt", "<C-s>", "Saves the edited cell with the alternate key." },
})

add("cell editor", editor, normal, {
  { "editor_cancel", "<Esc>", "Cancels the cell edit." },
  { "editor_cancel_q", "q", "Cancels the cell edit with the normal-mode key." },
  { "editor_open_url", "gx", "Opens the edited value when it is a URL." },
})

add("cell editor", editor, { "i" }, {
  { "editor_cancel_insert", "<C-c>", "Cancels the cell edit from insert mode." },
})

M.TAB_VIEWS = {
  [4] = "er_diagram",
  [5] = "stats",
  [6] = "columns",
  [7] = "fk",
  [8] = "indexes",
  [9] = "constraints",
}

local function contains(values, wanted)
  for _, value in ipairs(values) do
    if value == wanted then return true end
  end
  return false
end

--- Return the configured key for an action, or false to disable it.
---@param action string
---@return string|false|nil
function M.get(action)
  local user = require("dadbod-grip")._keymaps
  if user and user[action] ~= nil then return user[action] end
  return M.defaults[action]
end

--- Register a mapping after validating its catalog surface and mode.
---@param surface string
---@param bufnr integer
---@param action string
---@param mode string
---@param fn function|string
---@param opts? table
---@return boolean registered
function M.bind(surface, bufnr, action, mode, fn, opts)
  local record = by_action[action]
  assert(record, "unknown Dadbod Grip keymap action: " .. tostring(action))
  assert(contains(record.surfaces, surface),
    string.format("Dadbod Grip keymap %s is not declared for %s", action, surface))
  assert(contains(record.modes, mode),
    string.format("Dadbod Grip keymap %s is not declared for mode %s", action, mode))

  if record.requires and not require("dadbod-grip").get_opts()[record.requires] then
    return false
  end
  local key = M.get(action)
  if not key then return false end
  local map_opts = vim.tbl_extend("force", { silent = true }, opts or {}, { buffer = bufnr })
  if not map_opts.desc then map_opts.desc = "Grip: " .. record.description end
  vim.keymap.set(mode, key, fn, map_opts)
  return true
end

--- Encode the public catalog with stable record and field ordering.
---@return string
function M.to_json()
  local lines = { "{", '  "version": 1,', '  "keymaps": [' }
  local function encode(value)
    local encoded = vim.json.encode(value):gsub("\\/", "/")
    return encoded
  end
  local function array(values)
    local encoded = {}
    for _, value in ipairs(values) do table.insert(encoded, encode(value)) end
    return "[" .. table.concat(encoded, ", ") .. "]"
  end
  for i, record in ipairs(M.catalog) do
    table.insert(lines, "    {")
    table.insert(lines, '      "action": ' .. encode(record.action) .. ",")
    table.insert(lines, '      "default": ' .. encode(record.default) .. ",")
    table.insert(lines, '      "description": ' .. encode(record.description) .. ",")
    table.insert(lines, '      "category": ' .. encode(record.category) .. ",")
    table.insert(lines, '      "surfaces": ' .. array(record.surfaces) .. ",")
    local suffix = record.requires and "," or ""
    table.insert(lines, '      "modes": ' .. array(record.modes) .. suffix)
    if record.requires then
      table.insert(lines, '      "requires": ' .. encode(record.requires))
    end
    table.insert(lines, "    }" .. (i < #M.catalog and "," or ""))
  end
  table.insert(lines, "  ]")
  table.insert(lines, "}")
  return table.concat(lines, "\n") .. "\n"
end

return M
