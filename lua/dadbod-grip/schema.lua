-- schema.lua — sidebar schema tree browser.
-- Tables/views with expandable columns showing types + PK/FK markers.
-- Lazy column fetching on expand.

local db = require("dadbod-grip.db")

local M = {}

-- Active schema state (one per connection URL)
local _states = {}
local _sidebar_bufnr = nil
local _sidebar_winid = nil

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

--- Get or create state for a URL.
local function get_state(url)
  if not _states[url] then
    _states[url] = {
      url = url,
      items = nil,       -- { {name, type}, ... } — nil = not fetched
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

--- Fetch table list for a state.
local function fetch_tables(state)
  local tables, err = db.list_tables(state.url)
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  state.items = tables
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
  if not state.items then return nodes end

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

  -- Tables section
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

  -- Views section
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

  state.nodes = nodes
  return nodes
end

--- Render nodes into buffer lines + highlights.
local function render(state)
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then return end

  local nodes = build_nodes(state)
  local lines = {}
  local highlights = {}

  -- Connection name in title
  local connections = require("dadbod-grip.connections")
  local current = connections.current()
  local title = current and current.name or state.url:match("^%w+://[^/]*/?([^?]*)") or state.url
  table.insert(lines, " " .. title)
  table.insert(highlights, { line = 0, col = 0, end_col = #lines[1], hl = "GripBorder" })
  table.insert(lines, "")

  if state.filter then
    table.insert(lines, " / " .. state.filter)
    table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "Search" })
    table.insert(lines, "")
  end

  for _, node in ipairs(nodes) do
    if node.kind == "header" then
      table.insert(lines, " " .. node.text)
      table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "GripHeader" })
    elseif node.kind == "table" then
      local arrow = node.expanded and " ▼ " or " ▶ "
      table.insert(lines, arrow .. node.name)
      -- No special hl for table names — keep it clean
    elseif node.kind == "column" then
      local prefix
      if node.pk and node.fk then prefix = "   🔑🔗"
      elseif node.pk then prefix = "   🔑 "
      elseif node.fk then prefix = "   🔗 "
      else prefix = "      " end
      local pad = string.rep(" ", math.max(1, 16 - #node.name))
      local line = prefix .. " " .. node.name .. pad .. node.dtype
      table.insert(lines, line)
      -- Highlight type dim
      local type_start = #prefix + 1 + #node.name + #pad
      table.insert(highlights, { line = #lines - 1, col = type_start, end_col = #lines[#lines], hl = "GripReadonly" })
      if node.pk then
        table.insert(highlights, { line = #lines - 1, col = 3, end_col = 3 + #"🔑", hl = "GripBoolTrue" })
      end
      if node.fk then
        local fk_start = node.pk and 3 + #"🔑" or 3
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
  -- Account for title line + blank line + optional filter lines
  local offset = 2
  if state.filter then offset = offset + 2 end
  local node_idx = line - offset
  if node_idx >= 1 and node_idx <= #state.nodes then
    return state.nodes[node_idx]
  end
  return nil
end

--- Open a table in a grip grid in the adjacent window.
local function open_table(table_name, url)
  local grip = require("dadbod-grip")
  -- Find a non-sidebar window to open in
  local target_win = nil
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if bufnr ~= _sidebar_bufnr then
      target_win = winid
      break
    end
  end
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  end
  grip.open(table_name, url)
end

--- Set up buffer-local keymaps.
local function setup_keymaps(url)
  local buf = _sidebar_bufnr
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true })
  end

  local state = get_state(url)

  -- Open table / expand column
  map("<CR>", function()
    local node = node_at_cursor(state)
    if not node then return end
    if node.kind == "table" then
      open_table(node.name, url)
    elseif node.kind == "column" and node.table_name then
      open_table(node.table_name, url)
    end
  end)

  -- Expand
  map("l", function()
    local node = node_at_cursor(state)
    if node and node.kind == "table" and not node.expanded then
      state.expanded[node.name] = true
      render(state)
    end
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
    if node and node.kind == "table" and node.expanded then
      state.expanded[node.name] = false
      render(state)
    elseif node and node.kind == "column" and node.table_name then
      state.expanded[node.table_name] = false
      render(state)
    end
  end)
  map("zc", function()
    local node = node_at_cursor(state)
    if node and node.kind == "table" then
      state.expanded[node.name] = false
      render(state)
    end
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

  -- Filter/search
  map("/", function()
    vim.ui.input({ prompt = "Filter: ", default = state.filter or "" }, function(input)
      if input == nil then return end
      state.filter = (input ~= "") and input or nil
      render(state)
    end)
  end)

  -- Refresh
  map("r", function()
    state.items = nil
    state.col_cache = {}
    state.pk_cache = {}
    state.fk_cache = {}
    fetch_tables(state)
    render(state)
  end)

  -- Table picker
  map("gT", function()
    local picker = require("dadbod-grip.picker")
    picker.pick_table(url, function(name) open_table(name, url) end)
  end)

  -- Query pad
  map("gQ", function()
    local query_pad = require("dadbod-grip.query_pad")
    query_pad.open(url)
  end)

  -- Close
  map("q", function() M.close() end)
  map("<Esc>", function() M.close() end)

  -- Help
  map("?", function()
    local help = {
      " Schema Browser",
      " ──────────────",
      " <CR>     Open table in grid",
      " l / zo   Expand table columns",
      " h / zc   Collapse table",
      " L        Expand all",
      " H        Collapse all",
      " /        Filter by name",
      " r        Refresh schema",
      " gT       Table picker",
      " gQ       Query pad",
      " q / Esc  Close",
    }
    vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
  end)
end

--- Compute sidebar width.
local function sidebar_width()
  local w = math.floor(vim.o.columns * SIDEBAR_WIDTH_RATIO)
  return math.max(SIDEBAR_MIN_WIDTH, math.min(SIDEBAR_MAX_WIDTH, w))
end

--- Open or toggle the schema sidebar.
function M.toggle(url)
  -- If sidebar is visible, close it
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    M.close()
    return
  end

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Set vim.g.db or use :GripConnect.", vim.log.levels.ERROR)
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

  -- Open left split
  local width = sidebar_width()
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

  -- Fetch tables if not cached
  if not state.items then
    fetch_tables(state)
  end

  render(state)
end

--- Close the schema sidebar.
function M.close()
  if _sidebar_winid and vim.api.nvim_win_is_valid(_sidebar_winid) then
    vim.api.nvim_win_close(_sidebar_winid, true)
  end
  _sidebar_winid = nil
end

--- Refresh sidebar if visible (e.g., after connection switch).
function M.refresh(url)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  if not url then return end
  local state = get_state(url)
  state.items = nil
  state.col_cache = {}
  state.pk_cache = {}
  state.fk_cache = {}
  fetch_tables(state)
  -- Re-setup keymaps for new URL
  if _sidebar_bufnr and vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    setup_keymaps(url)
  end
  render(state)
end

return M
