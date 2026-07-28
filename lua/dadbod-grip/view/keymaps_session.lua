-- view/keymaps_session.lua: Keymaps that repoint or re-mode the session.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local ui     = require("dadbod-grip.ui")

local M = {}

--- Change what this grid is bound to or how it reads and writes it: table
--- picker, connection switcher, watch mode, write mode, open-as-editable and
--- the query history.
function M.setup(bufnr, ctx)
  local update_winbar = ctx.update_winbar
  local start_watch = ctx.start_watch
  local stop_watch = ctx.stop_watch
  local map, kmap = ctx.map, ctx.kmap

  -- go / gT / gt: table picker
  local function _pick_table()
    local picker = require("dadbod-grip.picker")
    local session = ctx.session()
    local s_url = session and session.url
    picker.pick_table(s_url, function(name)
      local grip = require("dadbod-grip")
      grip.open(name, s_url)
    end)
  end
  map("go", _pick_table, "Pick table")
  kmap("table_picker",     _pick_table, "Pick table")
  kmap("table_picker_alt", _pick_table, "Pick table")

  -- gC / <C-g>: switch database connection
  local function _pick_connection()
    require("dadbod-grip.connections").pick()
  end
  kmap("connections",     _pick_connection, "Switch connection")
  kmap("connections_alt", _pick_connection, "Switch connection")

  -- gW: toggle watch mode (auto-refresh on timer)
  kmap("grid_watch", function()
    local session = ctx.session()
    if not session then return end
    if session.watch_ms then
      stop_watch(bufnr)
      vim.notify("Watch mode off", vim.log.levels.INFO)
    else
      local ms = (session.opts and session.opts.watch_ms) or 5000
      start_watch(bufnr, ms)
      local secs = ms / 1000
      local label = secs == math.floor(secs) and tostring(math.floor(secs)) .. "s" or tostring(secs) .. "s"
      vim.notify("Watch mode on (" .. label .. ")", vim.log.levels.INFO)
    end
  end, "Toggle watch mode (auto-refresh)")

  -- g!: toggle write mode (file write-back on apply)
  kmap("grid_write_mode", function()
    local session = ctx.session()
    if not session then return end

    local file_path = session.file_path
    if not file_path then
      vim.notify("Write mode only applies to local file connections", vim.log.levels.INFO)
      return
    end
    if file_path:match("^https?://") then
      vim.notify("Remote files are read-only", vim.log.levels.INFO)
      return
    end

    if session.write_mode then
      -- Turning OFF: warn if staged changes exist
      local staged = session.state and (
        next(session.state.changes or {}) or
        next(session.state.deleted or {}) or
        next(session.state.inserted or {})
      )
      if staged then
        vim.notify("Staged changes exist. Apply (a) or undo (u) before disabling write mode.", vim.log.levels.WARN)
        return
      end
      session.write_mode = false
      update_winbar(bufnr)
      vim.notify("Write mode off", vim.log.levels.INFO)
    else
      -- Turning ON: destructive-action confirm
      local short = vim.fn.fnamemodify(file_path, ":t")
      if not ui.confirm("Enable write mode for " .. short
        .. "? Applying edits will overwrite the file. (y/N): ") then
        return
      end
      session.write_mode = true
      update_winbar(bufnr)
      vim.notify("Write mode on: edits will overwrite " .. short, vim.log.levels.INFO)
    end
  end, "Toggle write mode (overwrite file on apply)")

  -- gO: swap read-only query result to editable table
  kmap("grid_open_edit", function()
    local session = ctx.session()
    if not session then return end
    if not session.state.readonly then
      vim.notify("Already editable: i=edit  o=insert  d=delete", vim.log.levels.INFO)
      return
    end
    local grip = require("dadbod-grip")
    local s_url = session.url
    local current_win = vim.api.nvim_get_current_win()

    -- Try to auto-detect table name (check all sources)
    local detected = session.state.table_name
      or (session.query_spec and session.query_spec.table_name)
    local ambiguous = false

    -- Helper: extract table name from SQL (handles quoted and unquoted identifiers)
    local function extract_table_from_sql(sql_text)
      local flat = sql_text:gsub("\n", " ")
      -- Try quoted: FROM "table" or FROM `table`
      local quoted = flat:match('[Ff][Rr][Oo][Mm]%s+"([^"]+)"')
        or flat:match("[Ff][Rr][Oo][Mm]%s+`([^`]+)`")
      if quoted then return quoted end
      -- Unquoted: FROM table_name
      return flat:match("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)")
    end

    local function has_joins(sql_text)
      return sql_text:upper():match("JOIN%s") ~= nil
    end

    -- Fallback: parse base_sql from query spec (original unwrapped SQL)
    if not detected and session.query_spec and session.query_spec.base_sql then
      detected = extract_table_from_sql(session.query_spec.base_sql)
      ambiguous = has_joins(session.query_spec.base_sql)
    end

    -- Last resort: parse the wrapped query_sql (extract inner from _grip wrapper)
    if not detected then
      local sql_str = (session.query_sql or ""):gsub("\n", " ")
      local inner_sql = sql_str:match("%(%s*(.-)%s*%)%s+AS%s+_grip")
      local parse_target = inner_sql or sql_str
      detected = extract_table_from_sql(parse_target)
      ambiguous = ambiguous or has_joins(parse_target)
    end

    if detected and not ambiguous then
      vim.notify("Opening " .. detected .. " as editable table", vim.log.levels.INFO)
      grip.open(detected, s_url, { reuse_win = current_win })
    else
      -- Detection failed: show diagnostics so we can fix the root cause
      vim.notify(string.format(
        "gO: could not detect table\n table_name=%s | has_spec=%s | spec.table=%s\n spec.base_sql=%s\n query_sql=%s",
        tostring(session.state.table_name),
        tostring(session.query_spec ~= nil),
        tostring(session.query_spec and session.query_spec.table_name),
        tostring(session.query_spec and session.query_spec.base_sql and session.query_spec.base_sql:sub(1, 60)),
        tostring((session.query_sql or ""):sub(1, 60))
      ), vim.log.levels.WARN)
      -- Still offer picker as fallback
      local picker = require("dadbod-grip.picker")
      picker.pick_table(s_url, function(name)
        grip.open(name, s_url, { reuse_win = current_win })
      end)
    end
  end, "Open as editable table")

  -- gh: query history browser
  kmap("query_history", function()
    local hist = require("dadbod-grip.history")
    local session_h = ctx.session()
    local s_url = session_h and session_h.url
    hist.pick(function(sql_content)
      local query_pad = require("dadbod-grip.query_pad")
      query_pad.open(s_url, { initial_sql = sql_content })
    end)
  end, "Query history")
end

return M
