-- schema.lua: sidebar schema tree browser.
-- Tables/views with expandable columns showing types + PK/FK markers.
-- Lazy column fetching on expand.

local db      = require("dadbod-grip.db")
local VERSION = require("dadbod-grip.version")

local M = {}

-- Active schema state (one per connection URL)
local _states = {}
local _sidebar_bufnr = nil
local _sidebar_winid = nil
local _sidebar_saved_width = nil  -- persists across open/close cycles

local SIDEBAR_WIDTH_RATIO = 0.25
local SIDEBAR_MAX_WIDTH = 36
local SIDEBAR_MIN_WIDTH = 24

--- Abbreviate data types for compact display.
local function abbrev_type(dtype)
  if not dtype or dtype == "" then return "" end
  local lower = dtype:lower()
  -- Exact matches
  if lower == "integer" or lower == "int" or lower == "int4" then return "int" end
  if lower == "bigint" or lower == "int8" then return "big" end
  if lower == "smallint" or lower == "int2" then return "small" end
  if lower == "boolean" or lower == "tinyint(1)" or lower == "bool" then return "bool" end
  if lower == "text" then return "text" end
  if lower == "date" then return "date" end
  if lower == "time" then return "time" end
  if lower == "json" or lower == "jsonb" then return "json" end
  if lower == "real" or lower == "float" then return "float" end
  if lower == "double precision" or lower == "double" then return "dbl" end
  if lower == "blob" or lower == "bytea" then return "bin" end
  if lower == "uuid" or lower == "char(36)" then return "uuid" end
  if lower == "interval" then return "intv" end
  -- Timestamp variants
  if lower:match("^timestamp") then return "ts" end
  -- Varchar with length
  local vc_len = lower:match("^character varying%((%d+)%)$") or lower:match("^varchar%((%d+)%)$")
  if vc_len then return "vc(" .. vc_len .. ")" end
  if lower:match("^varchar") or lower:match("^character varying") then return "vc" end
  -- Decimal/numeric with precision
  local dec_m, dec_n = lower:match("^decimal%((%d+),(%d+)%)$")
  if not dec_m then dec_m, dec_n = lower:match("^numeric%((%d+),(%d+)%)$") end
  if dec_m then return "dec(" .. dec_m .. "," .. dec_n .. ")" end
  if lower:match("^decimal") or lower:match("^numeric") then return "dec" end
  -- INT AUTO_INCREMENT → int
  if lower:match("^int") then return "int" end
  -- Enum
  if lower:match("^enum") or lower:match("^user%-defined") then return "enum" end
  -- Array types
  if lower:match("%[%]$") then return abbrev_type(lower:gsub("%[%]$", "")) .. "[]" end
  -- Fallback: truncate
  if #dtype > 8 then return dtype:sub(1, 7) .. "…" end
  return dtype
end

-- File extensions that DuckDB can query directly (mirrors init.lua).
local FILE_EXTENSIONS = { ".parquet", ".csv", ".tsv", ".json", ".ndjson", ".jsonl", ".xlsx", ".orc", ".arrow", ".ipc" }

--- Returns true when the URL is a file path or remote file (not a DB connection).
local function is_file_url(url)
  if not url then return false end
  if url:match("^https?://") then
    local path = url:gsub("[?#].*$", ""):lower()
    for _, ext in ipairs(FILE_EXTENSIONS) do
      if path:sub(-#ext) == ext then return true end
    end
  end
  if url:match("^/") or url:match("^~/") or url:match("^%.%.?/") then
    local lower = url:lower()
    for _, ext in ipairs(FILE_EXTENSIONS) do
      if lower:sub(-#ext) == ext then return true end
    end
  end
  return false
end

--- Get or create state for a URL.
local function get_state(url)
  if not _states[url] then
    _states[url] = {
      url = url,
      items = nil,       -- { {name, type}, ... }: nil = not fetched
      file_cols = nil,   -- for file-as-table: { {column_name, data_type}, ... }
      expanded = {},      -- set of expanded table names
      col_cache = {},     -- table_name → column_info[]
      pk_cache = {},      -- table_name → set
      fk_cache = {},      -- table_name → fk_info[]
      nodes = {},         -- flat rendered node list
      filter = nil,       -- search filter string
    }
  end
  return _states[url]
end

--- Fetch table list for a persistent DB state.
local function fetch_tables(state)
  local tables, err = db.list_tables(state.url)
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  state.items = tables
end

--- Fetch column schema for a file-as-table URL (Parquet, CSV, remote file).
--- Uses DuckDB's DESCRIBE to get column names and types without needing a DB.
local function fetch_file_schema(state)
  local file_url = state.url
  local safe_url = file_url:gsub("'", "''")
  local sql = string.format("DESCRIBE SELECT * FROM '%s' LIMIT 0", safe_url)
  local result, err = db.query(sql, "duckdb::memory:")
  if not result then
    vim.notify("Grip: could not read file schema: " .. (err or "unknown"), vim.log.levels.WARN)
    state.file_cols = {}
    state.items = {}
    return
  end
  local cols = {}
  for _, row in ipairs(result.rows or {}) do
    local col_name  = type(row) == "table" and (row.column_name  or row[1]) or row
    local col_type  = type(row) == "table" and (row.column_type  or row[2]) or ""
    if col_name and col_name ~= "" then
      table.insert(cols, { column_name = col_name, data_type = col_type })
    end
  end
  state.file_cols = cols
  state.items = {}  -- Mark as fetched (empty = no DB tables, which is correct)
end

--- Fetch column info for a table (lazy, cached).
local function ensure_columns(state, table_name)
  if state.col_cache[table_name] then return end

  local cols = db.get_column_info(table_name, state.url)
  state.col_cache[table_name] = cols or {}

  local pks = db.get_primary_keys(table_name, state.url)
  local pk_set = {}
  for _, pk in ipairs(pks or {}) do pk_set[pk] = true end
  state.pk_cache[table_name] = pk_set

  local fks = db.get_foreign_keys(table_name, state.url)
  local fk_map = {}
  for _, fk in ipairs(fks or {}) do fk_map[fk.column] = fk.ref_table end
  state.fk_cache[table_name] = fk_map
end

--- Build flat node list from state.
local function build_nodes(state)
  local nodes = {}

  -- File-as-table mode: show columns of the file directly, no DB schema needed
  if state.file_cols then
    local fname = state.url:match("[^/\\]+$") or state.url
    local expanded = state.expanded["__file__"] ~= false  -- default expanded
    table.insert(nodes, { kind = "header", text = "File" })
    table.insert(nodes, {
      kind = "table", name = fname, expanded = expanded,
      is_file = true, file_key = "__file__",
    })
    if expanded then
      for _, col in ipairs(state.file_cols) do
        table.insert(nodes, {
          kind = "column",
          name = col.column_name,
          dtype = abbrev_type(col.data_type),
          pk = false, fk = false,
          table_name = "__file__",
          is_file = true,
        })
      end
    end
    state.nodes = nodes
    return nodes
  end

  if not state.items then return nodes end

  -- Check if any items have schema grouping (cross-database federation)
  local has_schemas = false
  for _, item in ipairs(state.items) do
    if item.schema then has_schemas = true; break end
  end

  if has_schemas then
    -- Group by schema, then tables/views within each schema
    local schema_order = {}
    local by_schema = {}
    for _, item in ipairs(state.items) do
      if state.filter then
        local base = item.name:match("%.(.+)$") or item.name
        if not base:lower():find(state.filter:lower(), 1, true) then
          goto continue_schema
        end
      end
      local s = item.schema or "main"
      if not by_schema[s] then
        by_schema[s] = {}
        table.insert(schema_order, s)
      end
      table.insert(by_schema[s], item)
      ::continue_schema::
    end

    for si, schema_name in ipairs(schema_order) do
      local items = by_schema[schema_name]
      if si > 1 then table.insert(nodes, { kind = "sep" }) end
      table.insert(nodes, { kind = "header", text = schema_name .. " (" .. #items .. ")" })

      for _, item in ipairs(items) do
        local display = item.name:match("%.(.+)$") or item.name
        local expanded = state.expanded[item.name] or false
        table.insert(nodes, { kind = "table", name = item.name, display = display, type = item.type, expanded = expanded })

        if expanded then
          ensure_columns(state, item.name)
          local cols = state.col_cache[item.name] or {}
          local pk_set = state.pk_cache[item.name] or {}
          local fk_map = state.fk_cache[item.name] or {}

          for _, col in ipairs(cols) do
            local is_pk = pk_set[col.column_name] or false
            local is_fk = fk_map[col.column_name] ~= nil
            table.insert(nodes, {
              kind = "column",
              name = col.column_name,
              dtype = abbrev_type(col.data_type),
              pk = is_pk,
              fk = is_fk,
              fk_ref = fk_map[col.column_name],
              table_name = item.name,
            })
          end
        end
      end
    end
  else
    -- Original flat layout: Tables section, then Views section
    local tables = {}
    local views = {}
    for _, item in ipairs(state.items) do
      if state.filter then
        if not item.name:lower():find(state.filter:lower(), 1, true) then
          goto continue
        end
      end
      if item.type == "view" then
        table.insert(views, item)
      else
        table.insert(tables, item)
      end
      ::continue::
    end

    if #tables > 0 then
      table.insert(nodes, { kind = "header", text = "Tables (" .. #tables .. ")" })
      for _, item in ipairs(tables) do
        local expanded = state.expanded[item.name] or false
        table.insert(nodes, { kind = "table", name = item.name, type = item.type, expanded = expanded })

        if expanded then
          ensure_columns(state, item.name)
          local cols = state.col_cache[item.name] or {}
          local pk_set = state.pk_cache[item.name] or {}
          local fk_map = state.fk_cache[item.name] or {}

          for _, col in ipairs(cols) do
            local is_pk = pk_set[col.column_name] or false
            local is_fk = fk_map[col.column_name] ~= nil
            table.insert(nodes, {
              kind = "column",
              name = col.column_name,
              dtype = abbrev_type(col.data_type),
              pk = is_pk,
              fk = is_fk,
              fk_ref = fk_map[col.column_name],
              table_name = item.name,
            })
          end
        end
      end
    end

    if #views > 0 then
      if #tables > 0 then
        table.insert(nodes, { kind = "sep" })
      end
      table.insert(nodes, { kind = "header", text = "Views (" .. #views .. ")" })
      for _, item in ipairs(views) do
        local expanded = state.expanded[item.name] or false
        table.insert(nodes, { kind = "table", name = item.name, type = item.type, expanded = expanded })

        if expanded then
          ensure_columns(state, item.name)
          local cols = state.col_cache[item.name] or {}
          for _, col in ipairs(cols) do
            table.insert(nodes, {
              kind = "column",
              name = col.column_name,
              dtype = abbrev_type(col.data_type),
              pk = false,
              fk = false,
              table_name = item.name,
            })
          end
        end
      end
    end
  end

  state.nodes = nodes
  return nodes
end

--- Render nodes into buffer lines + highlights.
local function render(state)
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then return end

  local nodes = build_nodes(state)
  local lines = {}
  local highlights = {}

  -- Title: file name for file-as-table, connection name for DB connections
  local title
  if state.file_cols ~= nil then
    title = state.url:match("[^/\\]+$") or state.url
    if #title > 34 then title = "…" .. title:sub(-33) end
  else
    local connections = require("dadbod-grip.connections")
    local current = connections.current()
    title = current and current.name or state.url:match("^%w+://[^/]*/?([^?]*)") or state.url
  end
  table.insert(lines, " " .. title)
  table.insert(highlights, { line = 0, col = 0, end_col = #lines[1], hl = "GripBorder" })

  table.insert(lines, "")

  if state.filter then
    table.insert(lines, " / " .. state.filter)
    table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "Search" })
    table.insert(lines, "")
  end

  -- Pre-compute per-table max column name display width for type alignment.
  local tbl_max_col_w = {}
  local _cur_tbl = nil
  for _, node in ipairs(nodes) do
    if node.kind == "table" then
      _cur_tbl = node.name
      tbl_max_col_w[node.name] = tbl_max_col_w[node.name] or 0
    elseif node.kind == "column" and _cur_tbl then
      local w = vim.fn.strdisplaywidth(node.name)
      if w > tbl_max_col_w[_cur_tbl] then tbl_max_col_w[_cur_tbl] = w end
    end
  end

  local cur_tbl = nil
  for _, node in ipairs(nodes) do
    if node.kind == "sep" then
      table.insert(lines, "")
    elseif node.kind == "header" then
      table.insert(lines, " " .. node.text)
      table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "GripHeader" })
    elseif node.kind == "table" then
      cur_tbl = node.name
      local arrow = node.expanded and " ▼ " or " ▶ "
      local max_name = SIDEBAR_MAX_WIDTH - 3  -- subtract arrow chars
      local label = node.display or node.name
      local display_name = #label > max_name
          and ("…" .. label:sub(-(max_name - 1))) or label
      table.insert(lines, arrow .. display_name)
      -- No special hl for table names: keep it clean
    elseif node.kind == "column" then
      -- All prefixes are 6 display cols wide.
      local prefix
      if node.pk and node.fk then prefix = "  🔑🔗"   -- 2 + 2 + 2 = 6
      elseif node.pk           then prefix = "   🔑 "  -- 3 + 2 + 1 = 6
      elseif node.fk           then prefix = "   🔗 "  -- 3 + 2 + 1 = 6
      else                          prefix = "      "  -- 6 spaces
      end
      local max_w   = tbl_max_col_w[cur_tbl] or 16
      local name_dw = vim.fn.strdisplaywidth(node.name)
      local pad     = string.rep(" ", math.max(1, max_w - name_dw + 2))
      local line    = prefix .. " " .. node.name .. pad .. node.dtype
      table.insert(lines, line)
      -- Highlight type dim (byte offsets)
      local type_start = #prefix + 1 + #node.name + #pad
      table.insert(highlights, { line = #lines - 1, col = type_start, end_col = #lines[#lines], hl = "GripReadonly" })
      if node.pk then
        table.insert(highlights, { line = #lines - 1, col = 2, end_col = 2 + #"🔑", hl = "GripBoolTrue" })
      end
      if node.fk then
        local fk_start = node.pk and 2 + #"🔑" or 3
        table.insert(highlights, { line = #lines - 1, col = fk_start, end_col = fk_start + #"🔗", hl = "GripUrl" })
      end
    elseif node.kind == "sep" then
      table.insert(lines, "")
    end
  end

  if #nodes == 0 and state.items then
    table.insert(lines, "")
    table.insert(lines, " (no tables found)")
    table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "GripReadonly" })
  end

  -- Hint line at bottom
  table.insert(lines, "")
  table.insert(lines, " 1:conn 2:pad 3:grid  CR go gb q gq gw gc / F ?")
  table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "GripReadonly" })

  vim.bo[_sidebar_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_sidebar_bufnr, 0, -1, false, lines)
  vim.bo[_sidebar_bufnr].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("grip_schema")
  vim.api.nvim_buf_clear_namespace(_sidebar_bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, _sidebar_bufnr, ns, hl.hl, hl.line, hl.col, hl.end_col)
  end
end

--- Get the node at the current cursor line.
local function node_at_cursor(state)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(_sidebar_winid)
  local line = cursor[1]
  -- title(1) + blank(1) = base offset 2
  local offset = 2
  if state.filter then offset = offset + 2 end
  local node_idx = line - offset
  if node_idx >= 1 and node_idx <= #state.nodes then
    return state.nodes[node_idx]
  end
  return nil
end

--- Find the best non-sidebar window to reuse for a new grid.
--- Prefers an existing grip grid window over the query pad.
local function find_right_win()
  return require("dadbod-grip.view").find_content_win()
end

--- Open a table in a grip grid, reusing the adjacent window.
local function open_table(table_name, url)
  local grip = require("dadbod-grip")
  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  grip.open(table_name, url, { reuse_win = target_win })
end

--- Open a table in a new split (explicit second grid).
local function open_table_split(table_name, url)
  local grip = require("dadbod-grip")
  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  grip.open(table_name, url, { force_split = true })
end

--- Line number offset for node list (title + blank [+ filter + blank]).
local function node_offset(state)
  return state.filter and 4 or 2
end

--- Move sidebar cursor to first table node.
local function jump_to_first_table(state)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset = node_offset(state)
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" then
      pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { offset + i, 0 })
      return
    end
  end
end

--- Navigate to next (+1) or prev (-1) table node, wrapping at ends.
local function jump_to_next_table(state, direction)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset = node_offset(state)
  local cur_line = vim.api.nvim_win_get_cursor(_sidebar_winid)[1]
  local tlines = {}
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" then table.insert(tlines, offset + i) end
  end
  if #tlines == 0 then return end
  if direction > 0 then
    for _, ln in ipairs(tlines) do
      if ln > cur_line then pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { ln, 0 }); return end
    end
    pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[1], 0 })
  else
    for i = #tlines, 1, -1 do
      if tlines[i] < cur_line then pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[i], 0 }); return end
    end
    pcall(vim.api.nvim_win_set_cursor, _sidebar_winid, { tlines[#tlines], 0 })
  end
end

--- Set up buffer-local keymaps.
local function setup_keymaps(url)
  local buf = _sidebar_bufnr
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true })
  end

  local state = get_state(url)

  -- Open table / expand column (reuses existing grid window)
  map("<CR>", function()
    local node = node_at_cursor(state)
    if not node then return end
    if node.is_file then
      if node.kind == "table" then
        -- File table node: focus grid if open, otherwise open the file
        local view_mod = require("dadbod-grip.view")
        local content_win = view_mod.find_content_win()
        local content_buf = content_win and vim.api.nvim_win_get_buf(content_win)
        if content_win and view_mod._sessions[content_buf] then
          vim.api.nvim_set_current_win(content_win)
        else
          require("dadbod-grip").open(url, nil, {})
        end
      else
        -- File column node: collapse/expand parent
        state.expanded["__file__"] = not state.expanded["__file__"]
        render(state)
      end
    elseif node.kind == "table" then
      open_table(node.name, url)
    elseif node.kind == "column" and node.table_name then
      open_table(node.table_name, url)
    end
  end)

  -- Open table in new split (explicit second grid)
  map("<S-CR>", function()
    local node = node_at_cursor(state)
    if not node then return end
    if node.is_file then return end  -- file nodes have no separate split action
    if node.kind == "table" then
      open_table_split(node.name, url)
    elseif node.kind == "column" and node.table_name then
      open_table_split(node.table_name, url)
    end
  end)

  -- Expand
  map("l", function()
    local node = node_at_cursor(state)
    if not node or node.kind ~= "table" or node.expanded then return end
    local key = node.file_key or node.name
    state.expanded[key] = true
    render(state)
  end)
  map("zo", function()
    local node = node_at_cursor(state)
    if node and node.kind == "table" then
      state.expanded[node.name] = true
      render(state)
    end
  end)

  -- Collapse
  map("h", function()
    local node = node_at_cursor(state)
    if not node then return end
    if node.kind == "table" and node.expanded then
      local key = node.file_key or node.name
      state.expanded[key] = false
      render(state)
    elseif node.kind == "column" and node.table_name then
      local key = node.file_key and "__file__" or node.table_name
      state.expanded[key] = false
      render(state)
    end
  end)
  map("zc", function()
    local node = node_at_cursor(state)
    if not node or node.kind ~= "table" then return end
    local key = node.file_key or node.name
    state.expanded[key] = false
    render(state)
  end)

  -- Expand all
  map("L", function()
    if not state.items then return end
    for _, item in ipairs(state.items) do
      state.expanded[item.name] = true
    end
    render(state)
  end)

  -- Collapse all
  map("H", function()
    for k in pairs(state.expanded) do
      state.expanded[k] = false
    end
    render(state)
  end)

  -- Filter/search: vim.fn.input() avoids dressing/noice float interception
  map("/", function()
    local CANCEL = "\0"
    local ok, input = pcall(vim.fn.input, { prompt = "Filter: ", default = state.filter or "", cancelreturn = CANCEL })
    if not ok or input == CANCEL then return end
    state.filter = (input ~= "") and input or nil
    render(state)
    if state.filter then
      vim.schedule(function() jump_to_first_table(state) end)
    end
  end)

  -- F: clear filter and jump to first table
  map("F", function()
    state.filter = nil
    render(state)
    vim.schedule(function() jump_to_first_table(state) end)
  end)

  -- n/N: navigate between table nodes (wraps)
  map("n", function() jump_to_next_table(state, 1) end)
  map("N", function() jump_to_next_table(state, -1) end)

  -- Refresh (r and R)
  local function do_refresh()
    state.items = nil
    state.col_cache = {}
    state.pk_cache = {}
    state.fk_cache = {}
    fetch_tables(state)
    render(state)
    vim.notify("Grip: schema refreshed", vim.log.levels.INFO)
  end
  map("r", do_refresh)
  map("R", do_refresh)

  -- Yank table/column name to clipboard
  map("y", function()
    local node = node_at_cursor(state)
    if not node then return end
    local name = (node.kind == "table" and node.name)
              or (node.kind == "column" and node.name)
              or nil
    if name then
      vim.fn.setreg("+", name)
      vim.fn.setreg('"', name)
      vim.notify("Copied: " .. name, vim.log.levels.INFO)
    end
  end)

  -- gT / gt: table picker
  local function _pick_table()
    require("dadbod-grip.picker").pick_table(url, function(name) open_table(name, url) end)
  end
  map("gT", _pick_table)
  map("gt", _pick_table)

  -- go: open table under cursor with smart ORDER BY (latest rows first)
  map("go", function()
    local node = node_at_cursor(state)
    if not node then return end

    -- File nodes: focus grid if open, otherwise open the file
    if node.is_file then
      local view_mod = require("dadbod-grip.view")
      local content_win = view_mod.find_content_win()
      local content_buf = content_win and vim.api.nvim_win_get_buf(content_win)
      if content_win and view_mod._sessions[content_buf] then
        vim.api.nvim_set_current_win(content_win)
      else
        require("dadbod-grip").open(url, nil, {})
      end
      return
    end

    local tbl = (node.kind == "table" and node.name)
             or (node.kind == "column" and node.table_name)
    if not tbl then return end

    ensure_columns(state, tbl)
    local cols   = state.col_cache[tbl] or {}
    local pk_set = state.pk_cache[tbl]  or {}

    -- Build lowercase name → original-case map for O(1) lookup
    local col_map = {}
    for _, col in ipairs(cols) do col_map[col.column_name:lower()] = col.column_name end

    -- Prefer timestamp columns so the grid opens showing the latest rows first
    local order_col
    for _, ts in ipairs({ "created_at", "inserted_at", "date_created", "created_on",
                          "updated_at", "modified_at", "date_updated", "updated_on",
                          "timestamp", "ts" }) do
      if col_map[ts] then order_col = col_map[ts]; break end
    end

    -- Fall back to any PK column
    if not order_col then
      for _, col in ipairs(cols) do
        if pk_set[col.column_name] then order_col = col.column_name; break end
      end
    end

    local grip = require("dadbod-grip")
    local target_win = find_right_win()
    if target_win then vim.api.nvim_set_current_win(target_win) end
    local arg = order_col
      and ("SELECT * FROM " .. tbl .. " ORDER BY " .. order_col .. " DESC")
      or tbl
    grip.open(arg, url, { reuse_win = target_win })
  end)

  -- gb: close sidebar (from inside; gb elsewhere opens/focuses it)
  map("gb", function() M.close() end)

  -- Q: go to welcome screen (home)
  map("Q", function() require("dadbod-grip").open_welcome() end)

  -- Query pad
  map("q", function()
    local query_pad = require("dadbod-grip.query_pad")
    query_pad.open(url)
  end)

  -- Load saved query into query pad
  map("gq", function()
    local saved = require("dadbod-grip.saved")
    saved.pick(function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
  end)

  -- Query history → load into query pad
  map("gh", function()
    require("dadbod-grip.history").pick(function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
  end)

  -- Jump to main content window: grid > welcome (silent no-op if neither exists)
  vim.keymap.set("n", "gw", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then vim.api.nvim_set_current_win(win) end
  end, { buffer = buf, silent = true, nowait = true })

  -- Switch connection (gC, gc, and C-g)
  -- on_cancel is a no-op: cancelling the picker keeps the sidebar visible.
  local function _pick_conn()
    require("dadbod-grip.connections").pick({ on_cancel = function() end })
  end
  map("gC", _pick_conn)
  map("gc", _pick_conn)
  map("<C-g>", _pick_conn)

  -- DDL: drop table
  map("D", function()
    local node = node_at_cursor(state)
    if not node or node.kind ~= "table" then
      vim.notify("Move cursor to a table", vim.log.levels.INFO)
      return
    end
    local ddl = require("dadbod-grip.ddl")
    ddl.drop_table(node.name, url, function()
      state.items = nil
      state.col_cache = {}
      fetch_tables(state)
      render(state)
    end)
  end)

  -- DDL: create table
  map("+", function()
    local ddl = require("dadbod-grip.ddl")
    ddl.create_table(url, function()
      state.items = nil
      state.col_cache = {}
      fetch_tables(state)
      render(state)
    end)
  end)

  -- 1: connections picker (already in sidebar = secondary action)
  map("1", _pick_conn)

  -- 2: open query pad
  map("2", function()
    require("dadbod-grip.query_pad").open(url)
  end)

  -- 3: jump to existing grid; if none, open table under cursor; if no node, table picker
  map("3", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then
      vim.api.nvim_set_current_win(win)
      return
    end
    local node = node_at_cursor(state)
    local tbl = node and ((node.kind == "table" and node.name)
                       or (node.kind == "column" and node.table_name))
    if tbl then
      open_table(tbl, url)
    else
      _pick_table()
    end
  end)

  -- Tab views: 4=ER diagram float, 5-9 open a table in a specific view facet
  local TAB_VIEWS = { [4]="er_diagram", [5]="stats", [6]="columns",
                      [7]="fk", [8]="indexes", [9]="constraints" }
  for n = 4, 9 do
    local view_name = TAB_VIEWS[n]
    map(tostring(n), function()
      if view_name == "er_diagram" then
        require("dadbod-grip.er_diagram").toggle(url)
        return
      end
      local node = node_at_cursor(state)
      if not node then return end
      local tbl = (node.kind == "table" and node.name)
               or (node.kind == "column" and node.table_name)
      if not tbl then return end
      local grip = require("dadbod-grip")
      local target_win = find_right_win()
      if target_win then vim.api.nvim_set_current_win(target_win) end
      grip.open(tbl, url, { reuse_win = target_win, view = view_name })
    end)
  end

  -- ga: attach external DB (DuckDB federation)
  map("ga", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Attach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripAttach")
  end)

  -- gd: detach external DB
  map("gd", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Detach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripDetach")
  end)

  -- gG: ER diagram float (scroll to table under cursor if on a table node)
  map("gG", function()
    local node = node_at_cursor(state)
    local tbl  = node and node.kind == "table" and node.name
    require("dadbod-grip.er_diagram").toggle(url, tbl)
  end)

  -- Close
  map("<Esc>", function() M.close() end)

  -- Help
  map("?", function()
    local lines = {
      "",
      "  Schema Browser",
      " ─────────────────────────────────────────",
      "",
      "  Navigation",
      "  j/k       Move between items",
      "  <CR>      Open table in grid (reuse win)",
      "  S-CR      Open table in new split",
      "  l / zo    Expand table columns",
      "  h / zc    Collapse table",
      "  L         Expand all",
      "  H         Collapse all",
      "  /         Filter by name",
      "  F         Clear filter",
      "",
      "  Tab Views",
      "  1         Table picker",
      "  2         Records (default)",
      "  3         Columns",
      "  4         Foreign Keys",
      "  5         Indexes",
      "  6         Constraints",
      "  7         Column Stats",
      "  8         History",
      "  9         Explain",
      "",
      "  Actions",
      "  r         Refresh schema",
      "  y         Yank table/column name",
      "  go        Open table, ORDER BY latest (created_at / PK)",
      "  gT / gt   Table picker (fuzzy finder)",
      "  gb        Close browser (gb outside: open/focus)",
      "  gw        Jump to grid",
      "  gC / gc   Switch connection",
      "  gh        Query history",
      "  gq        Saved queries",
      "  q         Query pad",
      "  ga        Attach external DB (DuckDB federation)",
      "  gd        Detach attached database",
      "  gG        ER diagram (all tables + FK relationships)",
      "  D         Drop table (confirm)",
      "  +         Create table",
      "  Esc       Close sidebar",
      "  ?         Toggle this help",
      "",
      " ─────────────────────────────────────────",
      "",
      "  ╔═╦═╦═╗",
      "  ║d║b║g║  dadbod-grip v" .. VERSION,
      "  ╚═╩═╩═╝",
      "",
    }
    local grip_win = vim.api.nvim_get_current_win()
    local max_w = 0
    for _, line in ipairs(lines) do max_w = math.max(max_w, #line) end
    max_w = math.max(max_w + 2, 44)
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
    -- Full schema help highlights
    local ns_sh = vim.api.nvim_create_namespace("grip_schema_help_hl")
    local function sadd(ln, group, s, e)
      vim.api.nvim_buf_add_highlight(popup_buf, ns_sh, group, ln, s or 0, e or -1)
    end
    for i, line in ipairs(lines) do
      local ln = i - 1
      if    line:match("^    %a") then                                           sadd(ln, "Special")
      elseif line:find("╔═╦") or line:find("║d║") or line:find("╚═╩") then     sadd(ln, "Special")
      elseif line:match("^%s+[─═]") then sadd(ln, "Comment")
      elseif line:find("\xe2\x86\xb3") then sadd(ln, "Comment")   -- ↳ continuation
      elseif line:match("^  %S") and not line:find("%s%s", 3) then sadd(ln, "Title")
      elseif line:match("^  %S") then
        local key_end = line:find("%s%s", 3)
        if key_end then sadd(ln, "Identifier", 2, key_end - 1) end
      end
    end
    local win = vim.api.nvim_open_win(popup_buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - #lines) / 2),
      col = math.floor((vim.o.columns - max_w) / 2),
      width = max_w,
      height = #lines,
      style = "minimal",
      border = "rounded",
      title = " Schema Help ",
      title_pos = "center",
      zindex = 50,
    })
    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = popup_buf,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    for _, key in ipairs({ "q", "?", "<Esc>" }) do
      vim.keymap.set("n", key, function()
        close()
        if vim.api.nvim_win_is_valid(grip_win) then
          vim.api.nvim_set_current_win(grip_win)
        end
      end, { buffer = popup_buf })
    end
  end)
end

--- Compute sidebar width.
local function sidebar_width()
  local w = math.floor(vim.o.columns * SIDEBAR_WIDTH_RATIO)
  return math.max(SIDEBAR_MIN_WIDTH, math.min(SIDEBAR_MAX_WIDTH, w))
end

--- Open or toggle the schema sidebar.
-- From outside the sidebar: focus it (open if needed).
-- From inside the sidebar: close it.
function M.toggle(url)
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    if vim.api.nvim_get_current_win() == _sidebar_winid then
      -- Already in sidebar → close (toggle off)
      M.close()
    else
      -- Not in sidebar → just focus it
      vim.api.nvim_set_current_win(_sidebar_winid)
    end
    return
  end

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
  end

  local state = get_state(url)

  -- Create buffer if needed
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    _sidebar_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_sidebar_bufnr].buftype = "nofile"
    vim.bo[_sidebar_bufnr].bufhidden = "hide"
    vim.bo[_sidebar_bufnr].swapfile = false
    vim.bo[_sidebar_bufnr].filetype = "grip_schema"
    vim.api.nvim_buf_set_name(_sidebar_bufnr, "grip://schema")
    setup_keymaps(url)
  end

  -- Open left split, restoring previous width if available
  local width = _sidebar_saved_width or sidebar_width()
  vim.cmd("topleft vertical " .. width .. "split")
  _sidebar_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(_sidebar_winid, _sidebar_bufnr)

  -- Window options
  vim.wo[_sidebar_winid].number = false
  vim.wo[_sidebar_winid].relativenumber = false
  vim.wo[_sidebar_winid].signcolumn = "no"
  vim.wo[_sidebar_winid].cursorline = true
  vim.wo[_sidebar_winid].winfixwidth = true
  vim.wo[_sidebar_winid].wrap = false

  -- Fetch schema if not cached
  if not state.items then
    if is_file_url(url) then
      fetch_file_schema(state)
    else
      fetch_tables(state)
    end
  end

  render(state)
end

--- Close the schema sidebar.
function M.close()
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    _sidebar_saved_width = vim.api.nvim_win_get_width(_sidebar_winid)
    vim.api.nvim_win_close(_sidebar_winid, true)
  end
  _sidebar_winid = nil
end

function M.is_open()
  return _sidebar_winid ~= nil and vim.api.nvim_win_is_valid(_sidebar_winid)
end

function M.get_winid()
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    return _sidebar_winid
  end
  return nil
end

--- Get first non-sidebar window (the right content area).
function M.get_right_win()
  if not M.is_open() then return nil end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if bufnr ~= _sidebar_bufnr then
      return winid
    end
  end
  return nil
end

--- Expose per-URL state for use by er_diagram.lua (read-only; do not mutate).
M.get_state = get_state

--- Refresh sidebar if visible (e.g., after connection switch).
function M.refresh(url)
  if not url then return end
  local state = get_state(url)
  -- Always invalidate cached tables so fresh data is fetched on next open
  state.items = nil
  state.col_cache = {}
  state.pk_cache = {}
  state.fk_cache = {}
  -- Only re-render if sidebar is currently visible
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  fetch_tables(state)
  if _sidebar_bufnr and vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    setup_keymaps(url)
  end
  render(state)
end

return M
