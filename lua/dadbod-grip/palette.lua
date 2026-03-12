-- palette.lua: command palette for dadbod-grip.
--
-- <C-p> on any grip surface (grid, query pad, sidebar) opens this picker.
-- Backend: grip_picker.open() - consistent with history, saved queries, etc.
--
-- Antifragile: M.register(action) lets any module add to the palette.
-- Every new feature can self-register and appear automatically.
--
-- M.open(context)     open palette for current surface context
-- M.register(action)  add an action from outside this module
--
-- context: 'grid' | 'query' | 'sidebar'
--
-- action table: { label, key, desc, fn, contexts }
--   label    string  displayed in list, e.g. "[grid]     Export to file"
--   key      string  shortcut shown in preview pane, e.g. "gX"
--   desc     string  one-line description shown in preview pane
--   fn       fn()    called when the item is selected
--   contexts table   list of contexts where this action appears, e.g. {"grid","query"}
--                    or {"all"} for all contexts (default)

local M = {}

-- Actions registered by external modules (antifragile extension point).
local _extra = {}

--- Register an additional action into the palette from any module.
--- @param action table { label, key, desc, fn, contexts }
function M.register(action)
  assert(action.label, "palette.register: label required")
  assert(type(action.fn) == "function", "palette.register: fn required")
  action.contexts = action.contexts or { "all" }
  table.insert(_extra, action)
end

-- ── helpers ───────────────────────────────────────────────────────────────

-- Create an action that fires a keymap in the calling buffer via feedkeys.
-- vim.schedule ensures the keys land after the picker float has closed.
local function via_key(key)
  return function()
    vim.schedule(function()
      local k = vim.api.nvim_replace_termcodes(key, true, false, true)
      vim.api.nvim_feedkeys(k, "", false)
    end)
  end
end

local function act(label, key, desc, contexts)
  if not key then return nil end   -- key = false means user disabled it; omit from palette
  return {
    label    = label,
    key      = key,
    desc     = desc,
    contexts = contexts or { "all" },
    fn       = via_key(key),
  }
end

-- ── built-in action list ───────────────────────────────────────────────────
-- Labels use a fixed 10-char category tag for scannable alignment:
--   [nav]      [query]    [grid]     [filter]   [page]
--   [analysis] [export]   [fk]       [ddl]      [ai]
--
-- Keys are looked up from keymaps.lua at open() time so user remaps are
-- reflected in the palette preview and in the feedkeys firing.

local function _build_actions()
  local k = require("dadbod-grip.keymaps").get

  local raw = {

    -- ── Navigation (all surfaces) ──────────────────────────────────────────
    act("[nav]      Switch connection",      k("connections"),      "Pick a database connection",                { "all" }),
    act("[nav]      ER diagram",             k("er_diagram"),       "Show entity-relationship diagram float",    { "all" }),
    act("[nav]      Table picker",           k("table_picker"),     "Pick a table to open in the grid",          { "all" }),
    act("[nav]      Query history",          k("query_history"),    "Browse and reload a past query",            { "all" }),
    act("[nav]      Load saved query",       k("load_saved"),       "Pick a saved query to load",                { "all" }),
    act("[nav]      Help",                   k("help"),             "Show full keymap reference popup",          { "all" }),

    -- ── Query pad ─────────────────────────────────────────────────────────
    act("[query]    Open query pad",         k("query_pad"),        "Open query editor (pre-filled with current SQL)",             { "grid", "sidebar" }),
    act("[query]    Execute SQL",            k("qpad_execute"),     "Run the full query buffer",                                   { "query" }),
    act("[query]    Save query",             k("qpad_save"),        "Save current buffer as a named query",                        { "query" }),
    act("[query]    AI SQL generation",      k("qpad_ai"),          "Generate SQL from a plain-English description",               { "query" }),
    act("[query]    Jump to grid",           k("goto_grid"),        "Focus the grid window",                                       { "query" }),
    act("[query]    Format SQL",             k("qpad_format"),      "Reformat SQL (external tool cascade -> Lua fallback)",         { "query" }),

    -- ── AI (grid / sidebar) ────────────────────────────────────────────────
    act("[ai]       AI SQL generation",      k("ai"),               "Generate SQL from a plain-English description",               { "grid", "sidebar" }),

    -- ── Grid: editing ─────────────────────────────────────────────────────
    act("[grid]     Edit cell",              k("grid_edit"),        "Open inline cell editor",                                     { "grid" }),
    act("[grid]     Set cell NULL",          k("grid_null"),        "Set the cell under cursor to NULL",                           { "grid" }),
    act("[grid]     Insert new row",         k("grid_insert"),      "Add a blank row (staged INSERT)",                             { "grid" }),
    act("[grid]     Clone row",              k("grid_clone"),       "Copy row with PKs cleared (staged INSERT)",                   { "grid" }),
    act("[grid]     Toggle delete row",      k("grid_delete"),      "Stage row for deletion (again to unstage)",                   { "grid" }),
    act("[grid]     Apply all changes",      k("grid_apply"),       "Execute all staged INSERTs, UPDATEs, DELETEs",                { "grid" }),
    act("[grid]     Undo last edit",         k("grid_undo"),        "Undo last staged change (multi-level)",                       { "grid" }),
    act("[grid]     Undo all changes",       k("grid_undo_all"),    "Reset all staged changes to original state",                  { "grid" }),
    act("[grid]     Redo",                   k("grid_redo"),        "Redo the last undone change",                                 { "grid" }),
    act("[grid]     Preview staged SQL",     k("grid_preview_sql"), "Show the SQL that would be executed on apply",                { "grid" }),

    -- ── Grid: display ─────────────────────────────────────────────────────
    act("[grid]     Row view",               k("grid_row_view"),    "Show current row as vertical key-value list",                 { "grid" }),
    act("[grid]     Toggle type row",        k("grid_type_row"),    "Show/hide column type annotations row",                       { "grid" }),
    act("[grid]     Cycle column width",     k("grid_col_width"),   "Compact -> expanded -> reset for column under cursor",        { "grid" }),
    act("[grid]     Hide column",            k("grid_hide_col"),    "Hide the column under cursor",                                { "grid" }),
    act("[grid]     Restore all columns",    k("grid_restore_cols"),"Restore all hidden columns",                                  { "grid" }),
    act("[grid]     Column visibility",      k("grid_col_vis"),     "Pick which columns to show or hide",                         { "grid" }),
    act("[grid]     Toggle live SQL",        k("grid_live_sql"),    "Show/hide floating live SQL preview",                         { "grid" }),
    act("[grid]     Refresh",                k("grid_refresh"),     "Re-run the query and refresh results",                        { "grid" }),

    -- ── Sort / filter ──────────────────────────────────────────────────────
    act("[filter]   Sort column",            k("grid_sort"),        "Toggle sort ASC -> DESC -> off on this column",               { "grid" }),
    act("[filter]   Add stacked sort",       k("grid_sort_stack"),  "Add/toggle secondary sort (up to 3 levels)",                  { "grid" }),
    act("[filter]   Filter by cell value",   k("grid_filter_cell"), "Quick-filter rows matching the current cell value",           { "grid" }),
    act("[filter]   Filter: IS NULL",        k("grid_filter_null"), "Show only rows where this column is NULL",                    { "grid" }),
    act("[filter]   Filter builder",         k("grid_filter_build"),"Build a WHERE clause filter interactively",                   { "grid" }),
    act("[filter]   Freeform WHERE clause",  k("grid_filter_where"),"Enter a raw SQL WHERE expression",                            { "grid" }),
    act("[filter]   Load filter preset",     k("grid_preset_load"), "Apply a saved filter preset",                                 { "grid" }),
    act("[filter]   Save filter preset",     k("grid_preset_save"), "Save current filters as a named preset",                      { "grid" }),
    act("[filter]   Clear all filters",      k("grid_filter_clear"),"Remove all active column filters",                            { "grid" }),
    act("[filter]   Reset view",             k("grid_reset_view"),  "Clear sort, filter, and return to page 1",                    { "grid" }),

    -- ── Pagination ─────────────────────────────────────────────────────────
    act("[page]     Next page",              k("grid_next_page"),   "Load next page of results",                                   { "grid" }),
    act("[page]     Previous page",          k("grid_prev_page"),   "Load previous page of results",                               { "grid" }),
    act("[page]     First page",             k("grid_first_page"),  "Jump to the first page",                                      { "grid" }),
    act("[page]     Last page",              k("grid_last_page"),   "Jump to the last page",                                       { "grid" }),

    -- ── Analysis ──────────────────────────────────────────────────────────
    act("[analysis] Aggregate column",       k("grid_aggregate"),   "Count, sum, avg, min, max for this column",                   { "grid" }),
    act("[analysis] Column statistics",      k("grid_col_stats"),   "Distinct values, null%, top values popup",                    { "grid" }),
    act("[analysis] Table profile",          k("grid_profile"),     "Sparkline distributions for all columns",                     { "grid" }),
    act("[analysis] Explain query plan",     k("grid_explain"),     "Show EXPLAIN output for the current query",                   { "grid" }),
    act("[analysis] Diff against table",     k("grid_diff"),        "Compare this table against another by primary key",           { "grid" }),
    act("[analysis] Show CREATE TABLE DDL",  k("grid_show_ddl"),    "Show the CREATE TABLE statement in a float",                  { "grid" }),
    act("[analysis] Table info",             k("grid_table_info"),  "Columns, types, and primary keys popup",                      { "grid" }),
    act("[analysis] Table properties",       k("grid_table_props"), "Full table detail float (indexes, FK, etc.)",                 { "grid" }),
    act("[analysis] Rename column header",   k("grid_rename_col"),  "Rename the display header for this column",                   { "grid" }),

    -- ── Export ────────────────────────────────────────────────────────────
    act("[export]   Export to clipboard",    k("grid_export_clip"), "Copy as CSV, TSV, JSON, SQL, Markdown, or Grip Table",        { "grid" }),
    act("[export]   Export to file",         k("grid_export_file"), "Save results to a CSV, JSON, or SQL file",                    { "grid" }),
    act("[export]   Yank cell",              k("grid_yank_cell"),   "Copy cell value to clipboard",                                { "grid" }),
    act("[export]   Yank row as CSV",        k("grid_yank_row"),    "Copy the current row as a CSV line",                          { "grid" }),
    act("[export]   Yank table as CSV",      k("grid_yank_table"),  "Copy the entire result set as CSV",                           { "grid" }),
    act("[export]   Yank as Markdown",       k("grid_yank_md"),     "Copy the table as a Markdown pipe table",                     { "grid" }),

    -- ── FK navigation ─────────────────────────────────────────────────────
    act("[fk]       Follow foreign key",     k("grid_fk_follow"),   "Open the referenced table filtered to the related row",       { "grid" }),
    act("[fk]       FK back navigation",     k("grid_fk_back"),     "Return from FK drill-down to the previous table",             { "grid" }),

    -- ── DDL / workflow ────────────────────────────────────────────────────
    act("[ddl]      Watch mode (toggle)",    k("grid_watch"),       "Auto-refresh on timer (default 5s)",                          { "grid" }),
    act("[ddl]      Open as editable",       k("grid_open_edit"),   "Reload read-only query result as a full editable table",      { "grid" }),
  }

  -- Filter out nil entries (actions the user disabled with key = false).
  local actions = {}
  for _, a in ipairs(raw) do
    if a then table.insert(actions, a) end
  end

  -- Merge externally registered actions.
  for _, a in ipairs(_extra) do
    table.insert(actions, a)
  end

  return actions
end

-- ── context filter ─────────────────────────────────────────────────────────

local function filter_for_context(context, actions)
  local out = {}
  for _, a in ipairs(actions) do
    for _, c in ipairs(a.contexts) do
      if c == "all" or c == context then
        table.insert(out, a)
        break
      end
    end
  end
  return out
end

-- ── public API ─────────────────────────────────────────────────────────────

--- Open the command palette for the given surface context.
--- @param context string 'grid' | 'query' | 'sidebar'
function M.open(context)
  context = context or "grid"
  local src_win = vim.api.nvim_get_current_win()   -- capture invoking window NOW
  local all     = _build_actions()
  local actions = filter_for_context(context, all)
  if #actions == 0 then return end

  require("dadbod-grip.grip_picker").pick({
    title   = "Commands  (/)filter  (<CR>)run  (q)close",
    items   = actions,
    display = function(a) return a.label end,
    preview = function(a)
      local lines = { "" }
      if a.key and a.key ~= "" then
        table.insert(lines, "  Key:  " .. a.key)
        table.insert(lines, "")
      end
      if a.desc and a.desc ~= "" then
        local words = {}
        local line  = "  "
        for word in (a.desc .. " "):gmatch("(%S+)%s") do
          if #line + #word + 1 > 42 then
            table.insert(words, line)
            line = "  " .. word
          else
            line = line == "  " and ("  " .. word) or (line .. " " .. word)
          end
        end
        if line ~= "  " then table.insert(words, line) end
        for _, l in ipairs(words) do table.insert(lines, l) end
      end
      return lines
    end,
    on_select = function(a)
      -- Restore focus to the invoking surface before the action fires.
      -- on_select already runs in vim.schedule (grip_picker's <CR> handler);
      -- via_key adds a second vim.schedule for feedkeys. Setting the window
      -- here (synchronously within on_select's scheduled callback) ensures
      -- feedkeys lands in the correct buffer regardless of where Neovim
      -- returned focus after closing the picker float.
      if vim.api.nvim_win_is_valid(src_win) then
        vim.api.nvim_set_current_win(src_win)
      end
      a.fn()
    end,
  })
end

return M
