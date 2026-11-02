-- schema.lua: sidebar schema tree browser.
-- Tables/views with expandable columns showing types + PK/FK markers.
-- Lazy column fetching on expand.

local db      = require("dadbod-grip.db")
local ui      = require("dadbod-grip.ui")
local esc     = require("dadbod-grip.sql").escape_literal

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripSchema", { clear = true })

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

local filetypes = require("dadbod-grip.filetypes")

--- Returns true when the URL is a file path or remote file (not a DB connection).
local function is_file_url(url)
  if not url then return false end
  local is_remote = url:match("^https?://") or url:match("^s3://")
  local is_path = url:match("^/") or url:match("^~/") or url:match("^%.%.?/")
  return not not ((is_remote or is_path) and filetypes.has_supported_extension(url))
end

--- Get or create state for a URL.
local function get_state(url)
  if not _states[url] then
    _states[url] = {
      url = url,
      items = nil,       -- { {name, type}, ... }: nil = not fetched
      routines = nil,    -- { {name, display, type}, ... }: nil = not fetched
      file_cols = nil,   -- for file-as-table: { {column_name, data_type}, ... }
      expanded = {},      -- column folds, independent from schema/partition folds
      groups_expanded = {},
      col_cache = {},        -- table_name → column_info[]
      pk_cache = {},         -- table_name → set
      fk_cache = {},         -- table_name → fk_info[]
      _schema_generation = 0,
      nodes = {},         -- flat rendered node list
      filter = nil,       -- search filter string
    }
  end
  return _states[url]
end

local function current_fetch(state, generation)
  return _states[state.url] == state and state._schema_generation == generation
end

--- Fetch table list for a persistent DB state.
local function fetch_tables(state)
  local generation = state._schema_generation
  local tables, err = db.list_tables(state.url)
  if not current_fetch(state, generation) then return end
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  local routines = db.list_routines(state.url)
  if not current_fetch(state, generation) then return end
  state.items = tables
  state.routines = routines or {}
  -- DuckDB's adapter deliberately omits .schema for its known main-schema rows.
  -- Other missing metadata conveys no ownership, including bare PostgreSQL names.
  state.default_schema = require("dadbod-grip.adapters").kind(db.resolved_url(state.url)) == "duckdb" and "main" or nil
  require("dadbod-grip.schema_tree").prune(state)
end

--- Fetch column schema for a file-as-table URL (Parquet, CSV, remote file).
--- Uses DuckDB's DESCRIBE to get column names and types without needing a DB.
local function fetch_file_schema(state)
  local generation = state._schema_generation
  local file_url = state.url
  local safe_url = esc(file_url)
  local sql = string.format("DESCRIBE SELECT * FROM '%s' LIMIT 0", safe_url)
  local result, err = db.query(sql, "duckdb::memory:")
  if not current_fetch(state, generation) then return end
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
  local generation = state._schema_generation

  local cols = db.get_column_info(table_name, state.url)
  if not current_fetch(state, generation) then return end

  local pks = db.get_primary_keys(table_name, state.url)
  if not current_fetch(state, generation) then return end
  local pk_set = {}
  for _, pk in ipairs(pks or {}) do pk_set[pk] = true end
  local fks = db.get_foreign_keys(table_name, state.url)
  if not current_fetch(state, generation) then return end
  local fk_map = {}
  for _, fk in ipairs(fks or {}) do fk_map[fk.column] = fk.ref_table end
  state.col_cache[table_name], state.pk_cache[table_name], state.fk_cache[table_name] = cols or {}, pk_set, fk_map
  return true
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
      kind = "table", id = "file", name = fname, expanded = expanded,
      is_file = true, file_key = "__file__",
    })
    if expanded then
      for _, col in ipairs(state.file_cols) do
        table.insert(nodes, {
          kind = "column", id = "file\0column\0" .. col.column_name, parent = "file",
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
  local tree = require("dadbod-grip.schema_tree")
  local generation = state._schema_generation
  nodes = tree.build(state)
  local loaded = false
  for _, node in ipairs(nodes) do
    if node.kind == "table" and node.columns_expanded and not state.col_cache[node.name] then
      loaded = ensure_columns(state, node.name) or loaded
      if not current_fetch(state, generation) then return state.nodes end
    end
  end
  if loaded then nodes = tree.build(state) end
  for _, node in ipairs(nodes) do
    if node.kind == "column" then node.dtype = abbrev_type(node.data_type) end
  end
  state.nodes = nodes
  return nodes
end

--- Snapshot stable identity and native window view before changing the projection.
local function selection(state)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return nil end
  local view = vim.api.nvim_win_call(_sidebar_winid, vim.fn.winsaveview)
  local node = state.nodes[view.lnum - (state.rendered_filter and 4 or 2)]
  local ids, by_id = {}, {}
  for _, candidate in ipairs(state.nodes) do if candidate.id then by_id[candidate.id] = candidate end end
  while node and node.id do
    ids[#ids + 1] = node.id
    node = by_id[node.parent]
  end
  return {ids = ids, view = view}
end

local function restore_selection(state, anchor)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset, target, same = state.filter and 4 or 2, nil, false
  for n, id in ipairs(anchor and anchor.ids or {}) do
    for i, node in ipairs(state.nodes) do
      if node.id == id then target, same = i, n == 1; break end
    end
    if target then break end
  end
  if not target then
    for i, node in ipairs(state.nodes) do
      if node.kind ~= "header" and node.kind ~= "sep" then target = i; break end
    end
  end
  local view = same and vim.deepcopy(anchor.view) or {col = 0, leftcol = 0, curswant = 0, coladd = 0}
  view.lnum = (target or 1) + offset
  if same then
    -- Keep the selected object in the same viewport position when rows above change.
    view.topline = math.max(1, (view.topline or 1) + view.lnum - anchor.view.lnum)
  end
  vim.api.nvim_win_call(_sidebar_winid, function() vim.fn.winrestview(view) end)
end

--- Render complete buffer labels; the window viewport handles horizontal clipping.
local function render(state, anchor)
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then return end
  local bufnr, winid, generation = _sidebar_bufnr, _sidebar_winid, state._schema_generation
  if not winid or not vim.api.nvim_win_is_valid(winid) or vim.b[bufnr].db ~= state.url then return end
  anchor = anchor or selection(state)
  local nodes = build_nodes(state)
  -- Expanding columns performs synchronous adapter calls that pump the event
  -- loop. A connection switch may have already reused and painted this buffer.
  if not current_fetch(state, generation) or _sidebar_bufnr ~= bufnr or _sidebar_winid ~= winid
      or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid)
      or vim.b[bufnr].db ~= state.url then return end
  local lines, highlights = {}, {}
  local function line(text, hl)
    lines[#lines + 1] = text
    if hl then highlights[#highlights + 1] = {line = #lines - 1, col = 0, end_col = #text, hl = hl} end
  end
  local title
  if state.file_cols ~= nil then
    title = state.url:match("[^/\\]+$") or state.url
  else
    local current = require("dadbod-grip.connections").current()
    title = current and current.name or state.url:match("^%w+://[^/]*/?([^?]*)") or state.url
  end
  line(" " .. title, "GripConnAccentBold")
  line("")
  if state.filter then line(" / " .. state.filter, "Search"); line("") end
  local widths = {}
  for _, node in ipairs(nodes) do
    if node.kind == "column" then
      widths[node.table_name] = math.max(widths[node.table_name] or 0, vim.fn.strdisplaywidth(node.name))
    end
  end
  for _, node in ipairs(nodes) do
    local indent = string.rep("  ", node.depth or 0)
    if node.kind == "header" then
      line(indent .. " " .. node.text, "GripHeader")
    elseif node.kind == "schema" or node.kind == "partitions" then
      local label = node.kind == "schema" and node.name or ("Partitions (" .. node.count .. ")")
      line(indent .. (node.expanded and " ▼ " or " ▶ ") .. label, "GripHeader")
    elseif node.kind == "table" then
      line(indent .. (node.expanded and " ▼ " or " ▶ ") .. (node.display or node.name))
    elseif node.kind == "column" then
      local marker = node.pk and (node.fk and "🔑🔗" or "🔑 ") or (node.fk and " 🔗" or "   ")
      local prefix = indent .. "  " .. marker .. " "
      local pad = string.rep(" ", math.max(1, (widths[node.table_name] or 0) - vim.fn.strdisplaywidth(node.name) + 2))
      line(prefix .. node.name .. pad .. node.dtype)
      highlights[#highlights + 1] = {line = #lines - 1, col = #prefix + #node.name + #pad,
        end_col = #lines[#lines], hl = "GripReadonly"}
    elseif node.kind == "routine" then
      line(indent .. (node.type == "procedure" and " ◇ " or " ƒ ") .. (node.display or node.name))
    elseif node.kind == "sep" then
      line("")
    end
  end
  if #nodes == 0 and state.items then
    line(state.filter and " (no matches)" or " (no objects found)", "GripReadonly")
  end
  if require("dadbod-grip").get_opts().show_hints then
    local km = require("dadbod-grip.keymaps")
    local function hints(items, native)
      local parts = {}
      for _, item in ipairs(items) do
        local key = km.get(item[1])
        if key then parts[#parts + 1] = key .. (item[2] or "") end
      end
      if native then parts[#parts + 1] = native end
      if #parts > 0 then line(" " .. table.concat(parts, " "), "GripReadonly") end
    end
    line("")
    hints({{"tab_1", ":conn"}, {"tab_2", ":pad"}, {"tab_3", ":grid"}})
    hints({{"sidebar_open"}, {"sidebar_filter"}, {"sidebar_filter_c"}, {"help"}}, "zh/zl")
  end
  vim.bo[_sidebar_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_sidebar_bufnr, 0, -1, false, lines)
  vim.bo[_sidebar_bufnr].modifiable = false
  local ns = vim.api.nvim_create_namespace("grip_schema")
  vim.api.nvim_buf_clear_namespace(_sidebar_bufnr, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(_sidebar_bufnr, ns, hl.line, hl.col, {end_col = hl.end_col, hl_group = hl.hl})
  end
  state.rendered_filter = state.filter
  restore_selection(state, anchor)
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

--- Open a routine definition in a read-only SQL buffer.
local function open_routine_source(routine_name, url)
  local source, err = db.get_routine_source(routine_name, url)
  if not source then
    vim.notify("Grip: " .. (err or "Failed to load routine source"), vim.log.levels.ERROR)
    return
  end

  local target_win = find_right_win()
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("rightbelow vsplit")
    target_win = vim.api.nvim_get_current_win()
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "grip://routine/" .. routine_name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "sql"
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(source, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.api.nvim_win_set_buf(target_win, bufnr)
end

--- Line number offset for node list (title + blank [+ filter + blank]).
local function node_offset(state)
  return state.filter and 4 or 2
end

--- Navigate to next (+1) or prev (-1) table node, wrapping at ends.
local function jump_to_next_table(state, direction)
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local offset = node_offset(state)
  local cur_line = vim.api.nvim_win_get_cursor(_sidebar_winid)[1]
  local tlines = {}
  for i, node in ipairs(state.nodes) do
    if node.kind == "table" or node.kind == "routine" then table.insert(tlines, offset + i) end
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
  local km = require("dadbod-grip.keymaps")
  local function kmap(action, fn, opts)
    km.bind("sidebar", buf, action, "n", fn, opts)
  end

  local state = get_state(url)

  local function groups() return state.filter and state.search_groups or state.groups_expanded end
  local function columns() return state.filter and state.search_columns or state.expanded end
  local function is_group(node) return node.kind == "schema" or node.kind == "partitions" end
  local function clear_filter()
    local anchor = state.search_restore or selection(state)
    state.filter, state.search_groups, state.search_columns, state.search_restore = nil, nil, nil, nil
    render(state, anchor)
  end

  -- Open table / expand column (reuses existing grid window)
  kmap("sidebar_open", function()
    local node = node_at_cursor(state)
    if not node then return end
    if is_group(node) then
      groups()[node.id] = not node.expanded
      render(state)
    elseif node.is_file then
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
    elseif node.kind == "routine" then
      open_routine_source(node.source_id or node.name, url)
    end
  end)

  -- Open table in new split (explicit second grid)
  kmap("sidebar_open_spl", function()
    local node = node_at_cursor(state)
    if not node then return end
    if node.is_file then return end  -- file nodes have no separate split action
    if node.kind == "table" then
      open_table_split(node.name, url)
    elseif node.kind == "column" and node.table_name then
      open_table_split(node.table_name, url)
    elseif node.kind == "routine" then
      open_routine_source(node.source_id or node.name, url)
    end
  end)

  local function expand()
    local node = node_at_cursor(state)
    if not node then return end
    if is_group(node) then groups()[node.id] = true
    elseif node.kind == "table" then columns()[node.file_key or node.name] = true
    else return end
    render(state)
  end
  local function collapse()
    local node = node_at_cursor(state)
    if not node then return end
    local anchor = selection(state)
    if is_group(node) and node.expanded then
      groups()[node.id] = false
    elseif node.kind == "table" and node.expanded then
      columns()[node.file_key or node.name] = false
      if node.partition_id then groups()[node.partition_id] = false end
    elseif node.kind == "column" then
      columns()[node.is_file and "__file__" or node.table_name] = false
    else
      -- A root has no ancestor; collapsing it must not jump to another object.
      if not anchor.ids[2] then return end
      table.remove(anchor.ids, 1)
      anchor.view.col, anchor.view.leftcol, anchor.view.curswant, anchor.view.coladd = 0, 0, 0, 0
    end
    render(state, anchor)
  end
  kmap("sidebar_expand", expand)
  kmap("sidebar_expand_z", expand)
  kmap("sidebar_collapse", collapse)
  kmap("sidebar_collap_z", collapse)

  kmap("sidebar_expand_all", function()
    if state.file_cols then columns()["__file__"] = true
    else
      for _, id in ipairs(require("dadbod-grip.schema_tree").containers(state)) do groups()[id] = true end
    end
    render(state)
  end)
  kmap("sidebar_collap_all", function()
    for key in pairs(columns()) do columns()[key] = false end
    if state.file_cols then columns()["__file__"] = false
    else
      for _, id in ipairs(require("dadbod-grip.schema_tree").containers(state)) do groups()[id] = false end
    end
    render(state)
  end)

  kmap("sidebar_filter", function()
    local anchor = selection(state)
    local input = ui.input({prompt = "Filter: ", default = state.filter or "", allow_empty = true})
    -- input() leaves its prompt echoed on the command line after completion.
    vim.api.nvim_echo({}, false, {})
    if input == nil then return end
    if input == "" then clear_filter(); return end
    if not state.filter then state.search_restore = anchor end
    state.filter, state.search_groups, state.search_columns = input, {}, {}
    render(state)
    for i, node in ipairs(state.nodes) do
      if node.matched then
        vim.api.nvim_win_set_cursor(_sidebar_winid, {node_offset(state) + i, 0})
        vim.api.nvim_win_call(_sidebar_winid, function() vim.fn.winrestview({leftcol = 0}) end)
        break
      end
    end
  end)
  kmap("sidebar_filter_c", clear_filter)

  -- next/prev table node (wraps)
  kmap("sidebar_next", function() jump_to_next_table(state, 1) end)
  kmap("sidebar_prev", function() jump_to_next_table(state, -1) end)

  -- Refresh (r and R)
  local function do_refresh()
    ui.blocking("Grip: refreshing schema...", function()
      M.refresh(url)
    end)
    vim.notify("Grip: schema refreshed", vim.log.levels.INFO)
  end
  kmap("sidebar_refresh",  do_refresh)
  kmap("sidebar_refresh2", do_refresh)

  -- Yank table/column name to clipboard
  kmap("sidebar_yank", function()
    local node = node_at_cursor(state)
    if not node then return end
    local name = (node.kind == "table" and node.name)
              or (node.kind == "column" and node.name)
              or (node.kind == "routine" and node.name)
              or nil
    if name then
      vim.fn.setreg("+", name)
      vim.fn.setreg('"', name)
      vim.notify("Copied: " .. name, vim.log.levels.INFO)
    end
  end)

  -- table_picker / table_picker_alt: table picker
  local function _pick_table()
    require("dadbod-grip.picker").pick_table(url, function(name) open_table(name, url) end)
  end
  kmap("table_picker",     _pick_table)
  kmap("table_picker_alt", _pick_table)

  -- sidebar_open_s: open table under cursor with smart ORDER BY (latest rows first)
  kmap("sidebar_open_s", function()
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

  -- schema_browser: close sidebar (from inside; gb elsewhere opens/focuses it)
  kmap("schema_browser", function() M.close() end)

  kmap("zoom", function() require("dadbod-grip.zoom").toggle() end)

  -- welcome: go to welcome screen (home)
  kmap("welcome", function() require("dadbod-grip").open_welcome() end)

  -- query_pad: open query pad
  kmap("query_pad", function()
    local query_pad = require("dadbod-grip.query_pad")
    query_pad.open(url)
  end)

  -- load_saved: load saved query into query pad
  kmap("load_saved", function()
    local saved = require("dadbod-grip.saved")
    saved.pick(function(sql_content, _, bound_url)
      require("dadbod-grip.query_pad").open(bound_url or url, { initial_sql = sql_content })
    end)
  end)

  -- query_history: load query history into query pad
  kmap("query_history", function()
    require("dadbod-grip.history").pick(function(sql_content)
      require("dadbod-grip.query_pad").open(url, { initial_sql = sql_content })
    end)
  end)

  -- open_notebook: open a .md or .sql notebook file in the query pad
  kmap("open_notebook", function()
    require("dadbod-grip.query_pad").pick_notebook()
  end)

  -- goto_grid: jump to main content window
  kmap("goto_grid", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then vim.api.nvim_set_current_win(win) end
  end, { nowait = true })

  -- Switch connection (connections, sidebar_conns, connections_alt)
  -- on_cancel is a no-op: cancelling the picker keeps the sidebar visible.
  local function _pick_conn()
    require("dadbod-grip.connections").pick({ on_cancel = function() end })
  end
  kmap("connections",     _pick_conn)
  kmap("sidebar_conns",   _pick_conn)
  kmap("connections_alt", _pick_conn)

  -- sidebar_drop: drop table
  kmap("sidebar_drop", function()
    local node = node_at_cursor(state)
    if not node or node.kind ~= "table" then
      vim.notify("Move cursor to a table", vim.log.levels.INFO)
      return
    end
    if require("dadbod-grip.connections").deny_if_readonly("Drop table", url) then return end
    local ddl = require("dadbod-grip.ddl")
    ddl.drop_table(node.name, url, function()
      M.refresh(url)
    end)
  end)

  -- sidebar_create: create table
  kmap("sidebar_create", function()
    if require("dadbod-grip.connections").deny_if_readonly("Create table", url) then return end
    local ddl = require("dadbod-grip.ddl")
    ddl.create_table(url, function()
      M.refresh(url)
    end)
  end)

  -- tab_1: connections picker (already in sidebar = secondary action)
  kmap("tab_1", _pick_conn)

  -- tab_2: open query pad
  kmap("tab_2", function()
    require("dadbod-grip.query_pad").open(url)
  end)

  -- tab_3: jump to existing grid; if none, open table under cursor; if no node, table picker
  kmap("tab_3", function()
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

  -- tab_4-9: ER diagram float or open table in a specific view facet
  for n = 4, 9 do
    local view_name = km.TAB_VIEWS[n]
    kmap("tab_" .. n, function()
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

  -- sidebar_attach: attach external DB (DuckDB federation)
  kmap("sidebar_attach", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Attach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripAttach")
  end)

  -- sidebar_detach: detach external DB
  kmap("sidebar_detach", function()
    if not url or not url:find("^duckdb:") then
      vim.notify("Detach requires a DuckDB connection.", vim.log.levels.WARN)
      return
    end
    vim.cmd("GripDetach")
  end)

  -- er_diagram: ER diagram float (scroll to table under cursor if on a table node)
  kmap("er_diagram", function()
    local node = node_at_cursor(state)
    local tbl = node and ((node.kind == "table" and node.name) or (node.kind == "column" and node.table_name))
    if tbl then require("dadbod-grip.er_diagram").toggle(url, tbl, { focus = true }) end
  end)

  kmap("sidebar_close", function() M.close() end)

  -- palette: command palette
  kmap("palette", function()
    require("dadbod-grip.palette").open("sidebar")
  end)

  -- help: schema help popup
  kmap("help", function()
    require("dadbod-grip.view").show_help({ surface = "sidebar" })
  end)
end

--- Compute the automatic sidebar width for an editor width.
local function sidebar_width_for(columns)
  local w = math.floor(columns * SIDEBAR_WIDTH_RATIO)
  return math.max(SIDEBAR_MIN_WIDTH, math.min(SIDEBAR_MAX_WIDTH, w))
end

local function sidebar_width()
  return sidebar_width_for(vim.o.columns)
end

--- Shrink a sidebar that no longer fits the editor, but never grow one the
--- user deliberately made narrower than the automatic target.
local function clamp_sidebar_width(current, columns)
  return math.min(current, sidebar_width_for(columns))
end

vim.api.nvim_create_autocmd("VimResized", {
  group = _ag,
  callback = function()
    if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
    local current = vim.api.nvim_win_get_width(_sidebar_winid)
    local clamped = clamp_sidebar_width(current, vim.o.columns)
    if clamped < current then pcall(vim.api.nvim_win_set_width, _sidebar_winid, clamped) end
  end,
})

--- Fetch the schema for `url` into state, touching no window.
---
--- Split out of toggle() so a caller assembling the workspace can pay for the
--- DB round-trip while the preloader is still up and the old screen is still
--- whole, instead of behind a sidebar that is already visible and empty.
--- Cached: a second call for the same URL costs nothing.
--- @param url string
--- @return table state
function M.prefetch(url)
  local state = get_state(url)
  if not state.items then
    if is_file_url(url) then
      fetch_file_schema(state)
    else
      fetch_tables(state)
    end
  end
  return state
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

  -- Fetch first, window second. list_tables()/list_routines() block on a DB
  -- round-trip that pumps the event loop, so a sidebar opened ahead of them
  -- sat on screen empty for the whole query -- and, next to an equally empty
  -- content area, made the workspace look like it was assembling itself in
  -- front of the user. Nothing between here and render() below blocks, so the
  -- split now appears already filled.
  local state = M.prefetch(url)

  -- Create buffer if needed
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    _sidebar_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[_sidebar_bufnr].buftype = "nofile"
    vim.bo[_sidebar_bufnr].bufhidden = "hide"
    vim.bo[_sidebar_bufnr].swapfile = false
    vim.bo[_sidebar_bufnr].filetype = "grip_schema"
    vim.api.nvim_buf_set_name(_sidebar_bufnr, "grip://schema")
  end
  -- The buffer is reused across connections; callbacks must bind the current URL.
  vim.b[_sidebar_bufnr].db = url
  setup_keymaps(url)

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
  vim.wo[_sidebar_winid].sidescrolloff = 0
  vim.wo[_sidebar_winid].list = true
  vim.wo[_sidebar_winid].listchars = "extends:…,precedes:…"

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

--- Repaint cached sidebar content without fetching or changing selection.
function M.redraw()
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  local url = vim.b[_sidebar_bufnr].db
  if url and _states[url] then render(_states[url]) end
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

--- Exposed for testing only.
--- Test hook: forget every cached schema so a spec can watch a fresh fetch.
function M._reset_state()
  _states = {}
end

M._clamp_sidebar_width = clamp_sidebar_width
M._sidebar_width_for = sidebar_width_for

M._build_nodes = build_nodes

--- Clear cached metadata without doing database or UI work.
function M.invalidate(url)
  if not url then return end
  local state = get_state(url)
  state._schema_generation = state._schema_generation + 1
  -- Invalidate all caches so fresh data is fetched
  state.items = nil
  state.routines = nil
  state.file_cols = nil
  state.col_cache = {}
  state.pk_cache = {}
  state.fk_cache = {}
  state.row_count_cache = {}
  state._tree_index = nil
end

--- Refresh only this URL's visible sidebar. Connection switching is explicit:
--- { switch = true } rebinds the reused sidebar buffer to the new URL.
function M.refresh(url, opts)
  if not url then return end
  db.invalidate_schema(url)
  local state = get_state(url)
  local generation = state._schema_generation
  -- Only re-render if sidebar is currently visible
  if not _sidebar_winid or not vim.api.nvim_win_is_valid(_sidebar_winid) then return end
  if not _sidebar_bufnr or not vim.api.nvim_buf_is_valid(_sidebar_bufnr) then return end
  if not (opts and opts.switch) and vim.b[_sidebar_bufnr].db ~= url then return end
  if opts and opts.switch then vim.b[_sidebar_bufnr].db = url end
  local bufnr, winid = _sidebar_bufnr, _sidebar_winid
  if is_file_url(url) then
    fetch_file_schema(state)
  else
    fetch_tables(state)
  end
  if not current_fetch(state, generation) or _sidebar_bufnr ~= bufnr or _sidebar_winid ~= winid
      or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid)
      or vim.b[bufnr].db ~= url then return end
  if _sidebar_bufnr and vim.api.nvim_buf_is_valid(_sidebar_bufnr) then
    setup_keymaps(url)
  end
  render(state)
end

return M
