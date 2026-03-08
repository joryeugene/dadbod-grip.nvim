-- keymaps.lua: default key bindings for all grip surfaces.
--
-- Single source of truth. Users override any binding via setup():
--
--   require("dadbod-grip").setup({
--     keymaps = {
--       palette   = "<F1>",      -- remap to a different key
--       query_pad = false,       -- disable entirely (pass false)
--     }
--   })
--
-- Action names are stable API. Keys are just defaults.
-- Shared actions (same key, same semantic, multiple surfaces) use one name.
-- Surface-prefixed actions (grid_*, qpad_*, sidebar_*) are unique to that surface.

local M = {}

M.defaults = {

  -- ── Shared: all three surfaces (grid, query pad, sidebar) ──────────────
  palette          = "<C-p>",  -- command palette (searchable action list)
  help             = "?",      -- help popup
  er_diagram       = "gG",     -- ER diagram float
  connections      = "gC",     -- switch database connection
  connections_alt  = "<C-g>",  -- alternate connections key
  table_picker     = "gT",     -- table picker (floating)
  table_picker_alt = "gt",     -- table picker (alternate)
  query_history    = "gh",     -- query history browser
  load_saved       = "gq",     -- load saved query
  welcome          = "Q",      -- welcome / home screen

  -- ── Shared: grid + sidebar ─────────────────────────────────────────────
  query_pad        = "q",      -- open query pad
  ai               = "A",      -- AI SQL generation
  schema_browser   = "gb",     -- schema sidebar (open / focus / close)

  -- ── Shared: grid + query pad ───────────────────────────────────────────
  goto_grid        = "gw",     -- jump to grid window

  -- ── Tab views 1-9 ──────────────────────────────────────────────────────
  -- Same key per slot; behaviour is surface-specific.
  -- view.lua: tab_1/2/3 are individual map() calls; tab_4-9 are in a loop.
  tab_1            = "1",  -- grid: sidebar  | qpad: sidebar  | sidebar: connections
  tab_2            = "2",  -- grid: query pad | qpad: history  | sidebar: query pad
  tab_3            = "3",  -- grid: records/table-picker | qpad: jump grid | sidebar: open table
  tab_4            = "4",  -- ER diagram float (all surfaces)
  tab_5            = "5",  -- column stats / stats view
  tab_6            = "6",  -- columns view
  tab_7            = "7",  -- foreign keys view
  tab_8            = "8",  -- indexes view
  tab_9            = "9",  -- constraints view

  -- ── Grid: row / column navigation ──────────────────────────────────────
  grid_row_down    = "j",
  grid_row_up      = "k",
  grid_col_left    = "h",
  grid_col_right   = "l",
  grid_col_next    = "w",        -- next column (word-motion style)
  grid_col_prev    = "b",        -- prev column
  grid_col_tab     = "<Tab>",    -- next column
  grid_col_tab_back= "<S-Tab>",  -- prev column
  grid_col_end     = "e",        -- end of cell / advance to next column
  grid_row_first   = "gg",       -- first data row
  grid_row_last    = "G",        -- last data row
  grid_col_first   = "0",        -- first column
  grid_col_first2  = "^",        -- first column (alt)
  grid_col_last    = "$",        -- last column
  grid_prev_mod    = "{",        -- previous modified row
  grid_next_mod    = "}",        -- next modified row

  -- ── Grid: editing ──────────────────────────────────────────────────────
  grid_edit        = "i",        -- edit cell (open inline editor)
  grid_edit_enter  = "<CR>",     -- edit cell (enter)
  grid_null        = "x",        -- set cell NULL
  grid_paste       = "p",        -- paste clipboard into cell
  grid_paste_rows  = "P",        -- paste multi-line into consecutive rows
  grid_insert      = "o",        -- insert new blank row
  grid_clone       = "c",        -- clone row (clear PKs)
  grid_delete      = "d",        -- toggle row deletion staging
  grid_apply       = "a",        -- apply all staged changes to DB
  grid_undo        = "u",        -- undo last staged edit
  grid_redo        = "<C-r>",    -- redo
  grid_undo_all    = "U",        -- undo all (reset to original state)

  -- ── Grid: visual mode ──────────────────────────────────────────────────
  grid_v_edit      = "e",        -- set selected cells to same value
  grid_v_delete    = "d",        -- toggle delete on selected rows
  grid_v_null      = "x",        -- set selected cells NULL
  grid_v_yank      = "y",        -- yank selected cells in column
  grid_v_compare   = "gd",       -- diff exactly 2 selected rows side-by-side

  -- ── Grid: display ──────────────────────────────────────────────────────
  grid_hide_col    = "-",        -- hide column under cursor
  grid_restore_cols= "g-",       -- restore all hidden columns
  grid_col_vis     = "gH",       -- column visibility picker
  grid_col_width   = "=",        -- cycle column width (compact → expanded → reset)
  grid_type_row    = "T",        -- toggle column type annotations row
  grid_row_view    = "K",        -- row view (vertical key-value transpose)
  grid_live_sql    = "gl",       -- toggle live SQL preview float

  -- ── Grid: sort / filter / pagination ───────────────────────────────────
  grid_sort        = "s",        -- sort column ASC → DESC → off
  grid_sort_stack  = "S",        -- stacked sort (up to 3 levels)
  grid_filter_cell = "f",        -- quick filter by cell value
  grid_filter_null = "gn",       -- filter: column IS NULL
  grid_filter_build= "gF",       -- interactive filter builder
  grid_filter_where= "<C-f>",    -- freeform WHERE expression
  grid_filter_clear= "F",        -- clear all active filters
  grid_preset_load = "gp",       -- load saved filter preset
  grid_preset_save = "gP",       -- save current filters as preset
  grid_reset_view  = "X",        -- clear sort + filter, return to page 1
  grid_next_page   = "L",        -- next page
  grid_prev_page   = "H",        -- previous page
  grid_next_page2  = "]p",       -- next page (bracket alias)
  grid_prev_page2  = "[p",       -- previous page (bracket alias)
  grid_last_page   = "]P",       -- last page
  grid_first_page  = "[P",       -- first page

  -- ── Grid: inspection / analysis ────────────────────────────────────────
  grid_explain_cell= "ge",       -- explain cell (type, value, status)
  grid_preview_sql = "gs",       -- preview staged SQL
  grid_copy_sql    = "gc",       -- copy staged SQL to clipboard
  grid_table_info  = "gi",       -- table info popup (columns, types, PKs)
  grid_table_props = "gI",       -- table properties float (indexes, FK, etc.)
  grid_rename_col  = "gN",       -- rename column display header
  grid_aggregate   = "ga",       -- aggregate column (count/sum/avg/min/max)
  grid_col_stats   = "gS",       -- column statistics popup
  grid_profile     = "gR",       -- table profile (sparkline distributions)
  grid_show_ddl    = "gV",       -- show CREATE TABLE DDL float
  grid_explain     = "gx",       -- EXPLAIN query plan
  grid_diff        = "gD",       -- diff against another table

  -- ── Grid: export / yank ────────────────────────────────────────────────
  grid_export_clip = "gE",       -- export to clipboard (CSV/TSV/JSON/SQL/MD)
  grid_export_file = "gX",       -- export to file (csv/json/sql)
  grid_yank_cell   = "y",        -- yank cell value to clipboard
  grid_yank_row    = "Y",        -- yank row as CSV
  grid_yank_table  = "gY",       -- yank entire result set as CSV
  grid_yank_md     = "gy",       -- yank table as Markdown pipe table

  -- ── Grid: FK navigation ────────────────────────────────────────────────
  grid_fk_follow   = "gf",       -- follow foreign key to referenced table
  grid_fk_back     = "<C-o>",    -- back in FK navigation stack

  -- ── Grid: workflow ─────────────────────────────────────────────────────
  grid_refresh     = "r",        -- re-run query, refresh results
  grid_watch       = "gW",       -- toggle watch mode (auto-refresh on timer)
  grid_write_mode  = "g!",       -- toggle write mode (apply overwrites file)
  grid_open_edit   = "gO",       -- reopen read-only result as editable table
  grid_fill        = "gA",       -- AI-generated staged rows (:GripFill)

  -- ── Query pad ──────────────────────────────────────────────────────────
  qpad_execute     = "<C-CR>",   -- execute full query
  qpad_save        = "<C-s>",    -- save query as named entry
  qpad_ai          = "gA",       -- AI SQL generation
  qpad_format      = "gF",       -- format SQL (external tool cascade → Lua fallback)
  qpad_close       = "q",        -- close query pad (go to welcome screen)
  open_notebook    = "gn",       -- open notebook file (.md/.sql) in query pad

  -- ── Schema sidebar ─────────────────────────────────────────────────────
  sidebar_open     = "<CR>",     -- open table under cursor (plain)
  sidebar_open_spl = "<S-CR>",   -- open table in new split
  sidebar_expand   = "l",        -- expand node
  sidebar_collapse = "h",        -- collapse node
  sidebar_expand_z = "zo",       -- expand (vim fold style)
  sidebar_collap_z = "zc",       -- collapse (vim fold style)
  sidebar_expand_all  = "L",     -- expand all tables
  sidebar_collap_all  = "H",     -- collapse all tables
  sidebar_filter   = "/",        -- filter by table name (pattern input)
  sidebar_filter_c = "F",        -- clear filter, jump to first table
  sidebar_next     = "n",        -- next table node (wraps)
  sidebar_prev     = "N",        -- previous table node (wraps)
  sidebar_refresh  = "r",        -- refresh schema
  sidebar_refresh2 = "R",        -- force-refresh schema
  sidebar_yank     = "y",        -- yank table/column name to clipboard
  sidebar_open_s   = "go",       -- open table with smart ORDER BY (latest first)
  sidebar_close    = "<Esc>",    -- close sidebar
  sidebar_drop     = "D",        -- drop table (with confirm prompt)
  sidebar_create   = "+",        -- create new table
  sidebar_attach   = "ga",       -- attach external DB (DuckDB federation)
  sidebar_detach   = "gd",       -- detach attached database
  sidebar_conns    = "gc",       -- switch connection (sidebar alias)

}

--- Return the configured key for an action, or false to disable.
--- Reads from the user overrides stored by setup({ keymaps = {...} }).
---@param action string  key from M.defaults
---@return string|false
function M.get(action)
  local user = require("dadbod-grip")._keymaps
  if user and user[action] ~= nil then return user[action] end
  return M.defaults[action]
end

return M
