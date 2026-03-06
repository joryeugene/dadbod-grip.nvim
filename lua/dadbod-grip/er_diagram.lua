--- er_diagram.lua: ER diagram float for dadbod-grip (tree-spine layout)
--- Entry: M.show(url), M.toggle(url)
--- Registered as gG in grid (view.lua) and schema sidebar (schema.lua)
---
--- Antifragile design: every table is on exactly one unique line.
--- Navigation uses line_to_node[row] — pure row lookup, zero column math.
--- Adding tables or columns never breaks layout; tree just grows vertically.

local M = {}

local _bufnr = nil
local _winid  = nil
local _ns     = vim.api.nvim_create_namespace("grip_er")

local dw = vim.fn.strdisplaywidth

-- ── helpers ───────────────────────────────────────────────────────────────────

local function is_open()
  return _winid and vim.api.nvim_win_is_valid(_winid)
end

local function close_er()
  local win, buf = _winid, _bufnr
  _winid = nil   -- nil first: prevents re-entrant WinLeave from recursing
  _bufnr = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  -- Explicitly delete buffer so "grip://er_diagram" name is freed immediately.
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- ── DAG depth ────────────────────────────────────────────────────────────────

--- Compute depth for each table. depth[t] = 0 if t has no outgoing FKs.
--- Tables that reference depth-d tables are at depth d+1.
local function compute_depths(tables, fk_cache)
  local tbl_set = {}
  for _, t in ipairs(tables) do tbl_set[t] = true end

  local fk_out = {}
  for _, t in ipairs(tables) do
    fk_out[t] = {}
    local col_map = fk_cache[t] or {}
    local seen = {}
    for _, ref in pairs(col_map) do
      if tbl_set[ref] and not seen[ref] and ref ~= t then
        table.insert(fk_out[t], ref)
        seen[ref] = true
      end
    end
  end

  local depth = {}
  local in_progress = {}

  local function get_depth(t)
    if depth[t] then return depth[t] end
    if in_progress[t] then depth[t] = 0; return 0 end  -- cycle guard
    in_progress[t] = true
    local refs = fk_out[t] or {}
    if #refs == 0 then
      depth[t] = 0
    else
      local max_d = 0
      for _, ref in ipairs(refs) do
        max_d = math.max(max_d, get_depth(ref) + 1)
      end
      depth[t] = max_d
    end
    in_progress[t] = nil
    return depth[t]
  end

  for _, t in ipairs(tables) do get_depth(t) end
  return depth, fk_out
end

-- ── column summary ────────────────────────────────────────────────────────────

local MAX_COL_NAME = 12  -- max display chars per column name before truncation
local MAX_ITEMS    = 4   -- max columns shown per table in the summary

--- Truncate a column name to MAX_COL_NAME display chars, appending "…" if cut.
--- Column names are virtually always ASCII so trimming one byte at a time is safe.
local function truncate_col(name)
  if dw(name) <= MAX_COL_NAME then return name end
  local t = name
  while dw(t) > MAX_COL_NAME - 1 do t = t:sub(1, -2) end
  return t .. "…"
end

--- Collect ordered column items for a table (PKs → FKs → regular), capped at MAX_ITEMS.
--- Returns: items = {{icon, name}, ...}, remaining = count not shown
local function get_col_items(tbl, state)
  local pk_set = state.pk_cache[tbl] or {}
  local fk_map = state.fk_cache[tbl] or {}
  local cols   = state.col_cache[tbl] or {}

  local items = {}
  local function add(icon, cname)
    if #items >= MAX_ITEMS then return end
    table.insert(items, { icon = icon, name = truncate_col(cname) })
  end

  for _, col in ipairs(cols) do
    local cn = col.column_name or col.name or "?"
    if pk_set[cn] then add("●", cn) end
  end
  for _, col in ipairs(cols) do
    local cn = col.column_name or col.name or "?"
    if not pk_set[cn] and fk_map[cn] then add("⬡", cn) end
  end
  for _, col in ipairs(cols) do
    local cn = col.column_name or col.name or "?"
    if not pk_set[cn] and not fk_map[cn] then add("○", cn) end
  end

  return items, #cols - #items
end

--- Format column items into a summary string using per-slot widths.
--- slot_w[i] = display width to pad the column name at position i.
--- Produces: "● pk  ⬡ fk_col  ○ other  +N"
local function format_col_summary(items, slot_w, remaining)
  if #items == 0 then return "" end
  local parts = {}
  for i, item in ipairs(items) do
    local w    = (slot_w and slot_w[i]) or 0
    local name = item.name
    local pad  = w - dw(name)
    if pad > 0 then name = name .. string.rep(" ", pad) end
    table.insert(parts, item.icon .. " " .. name)
  end
  local result = table.concat(parts, "  ")
  if remaining > 0 then result = result .. "  +" .. remaining end
  return result
end

-- ── tree collector (pass 1) ───────────────────────────────────────────────────

--- Collect {name, name_prefix, col_sum} records for a subtree (DFS).
--- Does NOT build lines — caller does alignment pass after.
--- col_sums: pre-computed {tbl → summary string} with per-slot widths applied.
local function collect_subtree(t, line_prefix, is_root, is_last,
                                children_of, entries, visited, col_sums)
  if visited[t] then return end
  visited[t] = true

  local connector   = is_root and "" or (is_last and "└── " or "├── ")
  local name_prefix = line_prefix .. connector

  table.insert(entries, {
    name        = t,
    name_prefix = name_prefix,
    col_sum     = col_sums[t] or "",
  })

  local child_prefix
  if is_root then
    child_prefix = ""
  elseif is_last then
    child_prefix = line_prefix .. "    "
  else
    child_prefix = line_prefix .. "│   "
  end

  local kids = children_of[t] or {}
  for i, kid in ipairs(kids) do
    collect_subtree(kid, child_prefix, false, i == #kids,
                    children_of, entries, visited, col_sums)
  end
end

-- ── content builder ───────────────────────────────────────────────────────────

--- Build all buffer content for the ER diagram (tree-spine layout).
---
--- Returns: lines, {}, line_to_node, table_lines
---   line_to_node[1idx]  = {name, kind, prefix_len?}
---   table_lines         = sorted 1-indexed line numbers of table nodes
---
--- Column summaries are aligned: all column annotations start at the same
--- display column, regardless of tree prefix depth or table name length.
local function build_content(url)
  local schema_mod = require("dadbod-grip.schema")
  local db         = require("dadbod-grip.db")
  local state      = schema_mod.get_state(url)

  -- Collect table list
  local tables = {}
  if state.items then
    for _, item in ipairs(state.items) do
      if item.type == "table" then table.insert(tables, item.name) end
    end
  else
    local list, err = db.list_tables(url)
    if not list then
      return { "  Error: " .. (err or "cannot list tables") }, {}, {}, {}
    end
    for _, item in ipairs(list) do
      if item.type == "table" then table.insert(tables, item.name) end
    end
  end

  if #tables == 0 then
    return { "  (no tables found)" }, {}, {}, {}
  end

  -- Ensure caches are populated for every table
  for _, tbl in ipairs(tables) do
    if not state.col_cache[tbl] then
      local cols = db.get_column_info(tbl, url)
      state.col_cache[tbl] = cols or {}

      local pks = db.get_primary_keys(tbl, url)
      local pk_set = {}
      for _, pk in ipairs(pks or {}) do pk_set[pk] = true end
      state.pk_cache[tbl] = pk_set

      local fks = db.get_foreign_keys(tbl, url)
      local fk_map = {}
      for _, fk in ipairs(fks or {}) do
        fk_map[fk.column or fk.column_name] = fk.ref_table or fk.foreign_table_name
      end
      state.fk_cache[tbl] = fk_map
    end
  end

  -- Compute depths and FK out-edges
  local depth, fk_out = compute_depths(tables, state.fk_cache)

  -- Build children_of[ref_table] = [tables that FK to ref_table] (tree children)
  local children_of = {}
  for _, t in ipairs(tables) do children_of[t] = children_of[t] or {} end
  for t, refs in pairs(fk_out) do
    for _, ref in ipairs(refs) do
      children_of[ref] = children_of[ref] or {}
      table.insert(children_of[ref], t)
    end
  end
  for _, kids in pairs(children_of) do table.sort(kids) end

  -- Classify: which tables are involved in any FK relationship
  local has_any_fk = {}
  for from_t, refs in pairs(fk_out) do
    if #refs > 0 then
      has_any_fk[from_t] = true
      for _, ref in ipairs(refs) do has_any_fk[ref] = true end
    end
  end

  -- Isolated = no FK in or out
  local isolated = {}
  for _, t in ipairs(tables) do
    if not has_any_fk[t] then table.insert(isolated, t) end
  end
  table.sort(isolated)

  -- Tree roots = depth-0 tables involved in any FK chain (referenced by others)
  local roots = {}
  for _, t in ipairs(tables) do
    if (depth[t] or 0) == 0 and has_any_fk[t] then
      table.insert(roots, t)
    end
  end
  table.sort(roots)

  -- ── Pre-pass: per-slot max column name widths ─────────────────────────────

  local slot_w = {}
  for i = 1, MAX_ITEMS do slot_w[i] = 0 end

  local items_cache = {}  -- tbl → {items, remaining}
  for _, tbl in ipairs(tables) do
    local items, remaining = get_col_items(tbl, state)
    items_cache[tbl] = { items = items, remaining = remaining }
    for i, item in ipairs(items) do
      local w = dw(item.name)
      if w > slot_w[i] then slot_w[i] = w end
    end
  end

  -- Build pre-formatted column summaries (consistent slot widths across all tables)
  local col_sums = {}
  for _, tbl in ipairs(tables) do
    local c = items_cache[tbl]
    col_sums[tbl] = format_col_summary(c.items, slot_w, c.remaining)
  end

  -- ── Pass 1: collect entries per section ──────────────────────────────────

  local visited      = {}
  local root_entries = {}  -- list of entry-lists, one per root

  for ri, root in ipairs(roots) do
    local entries = {}
    collect_subtree(root, "", true, ri == #roots,
                    children_of, entries, visited, col_sums)
    table.insert(root_entries, entries)
  end

  local iso_entries = {}
  for _, t in ipairs(isolated) do
    table.insert(iso_entries, {
      name        = t,
      name_prefix = "  ",
      col_sum     = col_sums[t] or "",
    })
  end

  -- ── Pass 2: compute global alignment column ───────────────────────────────

  local align_col = 0
  local function measure(entries)
    for _, e in ipairs(entries) do
      local w = dw(e.name_prefix .. e.name)
      if w > align_col then align_col = w end
    end
  end
  for _, entry_list in ipairs(root_entries) do measure(entry_list) end
  measure(iso_entries)
  align_col = align_col + 2  -- minimum 2-space gap before column summary

  -- ── Pass 3: emit buffer lines ─────────────────────────────────────────────

  local out_lines    = {}
  local line_to_node = {}
  local table_lines  = {}

  local function emit_entries(entries)
    for _, e in ipairs(entries) do
      local name_part = e.name_prefix .. e.name
      local pad       = string.rep(" ", align_col - dw(name_part))
      local line      = e.col_sum ~= "" and (name_part .. pad .. e.col_sum)
                                        or  name_part
      table.insert(out_lines, line)
      line_to_node[#out_lines] = {
        name       = e.name,
        kind       = "table",
        prefix_len = #e.name_prefix,  -- byte offset where table name starts
      }
      table.insert(table_lines, #out_lines)
    end
  end

  -- Line 1: title
  local short_url = url:match("[^/\\]+$") or url
  table.insert(out_lines, "  gG · ER Diagram · " .. short_url)
  line_to_node[#out_lines] = { kind = "title" }

  -- Line 2: breadcrumb placeholder (updated dynamically by 'f' / 'h')
  table.insert(out_lines, "")
  line_to_node[#out_lines] = { kind = "breadcrumb" }

  -- Line 3: separator
  table.insert(out_lines, "  " .. string.rep("─", 56))
  line_to_node[#out_lines] = { kind = "sep" }

  -- FK tree section
  for ri, entry_list in ipairs(root_entries) do
    if ri > 1 then
      table.insert(out_lines, "")
      line_to_node[#out_lines] = { kind = "blank" }
    end
    emit_entries(entry_list)
  end

  -- Isolated tables section
  if #iso_entries > 0 then
    table.insert(out_lines, "")
    line_to_node[#out_lines] = { kind = "blank" }
    table.insert(out_lines, "  ── no relationships " .. string.rep("─", 35))
    line_to_node[#out_lines] = { kind = "sep" }
    emit_entries(iso_entries)
  end

  -- Hint line
  table.insert(out_lines, "")
  line_to_node[#out_lines] = { kind = "blank" }
  table.insert(out_lines, "  ● pk  ⬡ fk  ○ col   j/k  Enter:open  f:follow  H:back  Tab:next  q:close")
  line_to_node[#out_lines] = { kind = "hint" }

  return out_lines, {}, line_to_node, table_lines
end

-- ── highlight application ─────────────────────────────────────────────────────

local function apply_highlights(bufnr, lines, line_to_node)
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)

  for i, line in ipairs(lines) do
    local node = line_to_node[i] or {}
    local kind = node.kind or ""
    local row  = i - 1  -- 0-indexed for nvim API

    if kind == "title" then
      vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripHeader", row, 0, -1)

    elseif kind == "sep" then
      vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripBorder", row, 0, -1)

    elseif kind == "hint" then
      vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripReadonly", row, 0, -1)

    elseif kind == "table" then
      -- Dim the tree prefix (├──, └──, │ and spaces before the table name)
      local prefix_len = node.prefix_len or 0
      if prefix_len > 0 then
        vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripReadonly", row, 0, prefix_len)
      end

      -- Highlight column indicators (each UTF-8 symbol is 3 bytes)
      local function hl_char(ch, hl_group)
        local pos = 1
        while true do
          local s = line:find(ch, pos, true)
          if not s then break end
          vim.api.nvim_buf_add_highlight(bufnr, _ns, hl_group, row, s - 1, s + 2)
          pos = s + 3
        end
      end

      hl_char("●", "GripBoolTrue")  -- PK
      hl_char("⬡", "GripUrl")       -- FK
      hl_char("○", "GripReadonly")  -- regular column
    end
  end
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Show the ER diagram float for the given database URL.
--- @param url      string
--- @param scroll_to? string  optional table name to place cursor on after open
function M.show(url, scroll_to)
  if not url or url == "" then
    vim.notify("ER Diagram: no database connection", vim.log.levels.WARN)
    return
  end

  if is_open() then close_er() end

  vim.notify("Building ER diagram...", vim.log.levels.INFO)
  local lines, _, line_to_node, table_lines = build_content(url)

  -- Compute content width, then right-align +N to that edge
  local content_w = 0
  for _, l in ipairs(lines) do content_w = math.max(content_w, dw(l)) end
  for i, line in ipairs(lines) do
    local prefix, plus_str = line:match("^(.+)  (%+%d+)$")
    if prefix then
      local gap = content_w - dw(prefix) - dw(plus_str)
      lines[i] = prefix .. string.rep(" ", math.max(2, gap)) .. plus_str
    end
  end

  -- Create buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "grip://er_diagram")
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype   = "grip_er"
  vim.bo[bufnr].bufhidden  = "wipe"
  vim.bo[bufnr].buftype    = "nofile"

  apply_highlights(bufnr, lines, line_to_node)

  -- Float dimensions (content_w already computed above)
  local content_h = #lines

  local max_w = math.floor(vim.o.columns * 0.85)
  local max_h = math.floor(vim.o.lines   * 0.85)
  local width  = math.min(content_w + 2, max_w)
  local height = math.min(content_h, max_h)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height, row = row, col = col,
  })
  vim.wo[winid].wrap       = false
  vim.wo[winid].cursorline = true

  _bufnr = bufnr
  _winid = winid

  -- Navigation history (local to this show() call; reset when ER diagram closes)
  local history = {}

  -- Update the breadcrumb line (line 2) from history stack
  local function update_breadcrumb()
    local parts = {}
    for _, h in ipairs(history) do table.insert(parts, h.name) end
    local bc = #parts > 0 and ("  " .. table.concat(parts, " ▸ ")) or ""
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { bc })
    vim.bo[bufnr].modifiable = false
    if bc ~= "" then
      vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripReadonly", 1, 0, -1)
    end
  end

  -- Scroll to requested table (antifragile: row-only lookup, no column math)
  if scroll_to then
    for ln, node in pairs(line_to_node) do
      if node.name == scroll_to then
        vim.api.nvim_win_set_cursor(winid, { ln, 0 })
        break
      end
    end
  end

  -- Keymaps
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = bufnr, silent = true, nowait = true })
  end

  map("q",     close_er)
  map("<Esc>", close_er)
  map("gG",    close_er)

  -- <Tab>: jump to next table node (skips sep/blank/title lines)
  map("<Tab>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for _, ln in ipairs(table_lines) do
      if ln > cur then vim.api.nvim_win_set_cursor(0, { ln, 0 }); return end
    end
    -- Wrap to first table
    if #table_lines > 0 then
      vim.api.nvim_win_set_cursor(0, { table_lines[1], 0 })
    end
  end)

  -- <S-Tab>: jump to previous table node
  map("<S-Tab>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for i = #table_lines, 1, -1 do
      if table_lines[i] < cur then
        vim.api.nvim_win_set_cursor(0, { table_lines[i], 0 }); return
      end
    end
    -- Wrap to last table
    if #table_lines > 0 then
      vim.api.nvim_win_set_cursor(0, { table_lines[#table_lines], 0 })
    end
  end)

  -- <CR>: open table under cursor in grid (pure row lookup — no column math)
  map("<CR>", function()
    local cur_row = vim.api.nvim_win_get_cursor(0)[1]
    local node    = line_to_node[cur_row]
    if not node or node.kind ~= "table" then
      vim.notify("Move cursor to a table name line", vim.log.levels.INFO)
      return
    end
    close_er()
    require("dadbod-grip").open(node.name, url)
  end)

  -- f: follow FK — jump to the referenced table in the tree, push history
  local CANCEL = "\0"
  map("f", function()
    local cur_row = vim.api.nvim_win_get_cursor(0)[1]
    local node    = line_to_node[cur_row]
    if not node or node.kind ~= "table" then return end

    local st      = require("dadbod-grip.schema").get_state(url)
    local fks     = st.fk_cache[node.name] or {}
    local targets = {}
    for col, ref in pairs(fks) do
      table.insert(targets, { col = col, ref = ref })
    end
    table.sort(targets, function(a, b) return a.col < b.col end)

    if #targets == 0 then
      vim.notify(node.name .. " has no FK relationships", vim.log.levels.INFO)
      return
    end

    -- Resolve target table name
    local target
    if #targets == 1 then
      target = targets[1].ref
    else
      -- Multiple FKs: show numbered prompt
      local opts = {}
      for i, t in ipairs(targets) do
        opts[i] = i .. ": " .. t.col .. " → " .. t.ref
      end
      local ok_r, choice = pcall(vim.fn.input, {
        prompt      = table.concat(opts, "   ") .. "\nFollow FK [#]: ",
        cancelreturn = CANCEL,
      })
      if not ok_r or choice == CANCEL or choice == "" then return end
      local idx = tonumber(choice)
      if idx and targets[idx] then target = targets[idx].ref end
    end
    if not target then return end

    -- Push current position to history and update breadcrumb
    table.insert(history, { line = cur_row, name = node.name })
    update_breadcrumb()

    -- Jump to target in the tree
    local found = false
    for ln, n in pairs(line_to_node) do
      if n.name == target then
        vim.api.nvim_win_set_cursor(0, { ln, 0 })
        found = true; break
      end
    end
    if not found then
      vim.notify("Table not in diagram: " .. target, vim.log.levels.INFO)
      table.remove(history)
      update_breadcrumb()
    end
  end)

  -- H / <BS>: go back in navigation history
  local function go_back()
    local prev = table.remove(history)
    if not prev then
      vim.notify("No navigation history", vim.log.levels.INFO); return
    end
    update_breadcrumb()
    vim.api.nvim_win_set_cursor(0, { prev.line, 0 })
  end
  map("H",    go_back)
  map("<BS>", go_back)

  -- WinLeave: close when focus leaves
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr, once = true,
    callback = function() close_er() end,
  })
end

--- Toggle the ER diagram float (close if open, show if closed).
--- @param url      string
--- @param scroll_to? string  optional table name to place cursor on
function M.toggle(url, scroll_to)
  if is_open() then
    close_er()
  else
    M.show(url, scroll_to)
  end
end

M._build_content = build_content   -- exposed for unit tests only

return M
