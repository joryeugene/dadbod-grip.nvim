--- er_diagram.lua: ER diagram float for dadbod-grip
--- Entry: M.show(url), M.toggle(url)
--- Registered as gG in grid (view.lua) and schema sidebar (schema.lua)

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
  -- Explicitly delete buffer: bufhidden=wipe is async and unreliable for
  -- immediate cleanup. The buffer holds the "grip://er_diagram" name, and
  -- a stale reference blocks M.show() from reusing that name on next open.
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- ── box rendering ─────────────────────────────────────────────────────────────

--- Compute inner width (content area between the │ borders) for a table box.
local function box_inner_width(tbl_name, cols, pk_set, fk_map)
  local MIN = 18
  local w = dw(tbl_name) + 2   -- "  tbl_name" with leading indent
  for _, col in ipairs(cols) do
    local cname = col.column_name or col.name or "?"
    local ref   = fk_map[cname]
    -- Indicator prefix is always 2 display cols ("● ", "⬡ ", "○ ")
    local line_w = 2 + dw(cname)
    if ref then line_w = line_w + 4 + dw(ref) end  -- " → ref_table"
    w = math.max(w, line_w)
  end
  return math.max(w, MIN)
end

--- Render one table box. Returns lines[], meta[].
--- meta[i].kind = "border" | "header" | "col_pk" | "col_fk" | "col_reg"
local function render_box(tbl_name, cols, pk_set, fk_map, inner_w)
  local lines = {}
  local meta  = {}
  local function push(s, kind) table.insert(lines, s); table.insert(meta, kind) end

  push("┌" .. string.rep("─", inner_w + 2) .. "┐", "border")

  local hdr_content = "  " .. tbl_name
  local hdr_pad = math.max(0, inner_w + 2 - dw(hdr_content))
  push("│" .. hdr_content .. string.rep(" ", hdr_pad) .. "│", "header")

  push("├" .. string.rep("─", inner_w + 2) .. "┤", "border")

  for _, col in ipairs(cols) do
    local cname = col.column_name or col.name or "?"
    local is_pk = pk_set[cname]
    local ref   = fk_map[cname]
    local ind   = is_pk and "●" or (ref and "⬡" or "○")
    local content
    if ref then
      content = ind .. " " .. cname .. " → " .. ref
    else
      content = ind .. " " .. cname
    end
    local pad = math.max(0, inner_w - dw(content))
    push("│ " .. content .. string.rep(" ", pad) .. " │",
         is_pk and "col_pk" or (ref and "col_fk" or "col_reg"))
  end

  push("└" .. string.rep("─", inner_w + 2) .. "┘", "border")

  return lines, meta
end

-- ── DAG depth ────────────────────────────────────────────────────────────────

--- Compute depth for each table. depth[t] = 0 if t has no outgoing FKs.
--- Tables that reference depth-d tables are at depth d+1 (rendered to the right).
local function compute_depths(tables, fk_cache)
  local tbl_set = {}
  for _, t in ipairs(tables) do tbl_set[t] = true end

  -- fk_out[t] = list of distinct tables that t references via FK
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

-- ── content builder ───────────────────────────────────────────────────────────

--- Build lines, meta, and table_header_lines lookup for the ER diagram.
--- table_header_lines[line_1idx] = table_name  (for <CR> navigation)
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
      return { "  Error: " .. (err or "cannot list tables") }, {}, {}
    end
    for _, item in ipairs(list) do
      if item.type == "table" then table.insert(tables, item.name) end
    end
  end

  if #tables == 0 then
    return { "  (no tables found)" }, {}, {}
  end

  -- Ensure caches are populated for every table
  for _, tbl in ipairs(tables) do
    if not state.col_cache[tbl] then
      local cols = db.get_column_info(tbl, url)
      state.col_cache[tbl] = cols or {}

      local pks  = db.get_primary_keys(tbl, url)
      local pk_set = {}
      for _, pk in ipairs(pks or {}) do pk_set[pk] = true end
      state.pk_cache[tbl] = pk_set

      local fks  = db.get_foreign_keys(tbl, url)
      local fk_map = {}
      for _, fk in ipairs(fks or {}) do fk_map[fk.column or fk.column_name] = fk.ref_table or fk.foreign_table_name end
      state.fk_cache[tbl] = fk_map
    end
  end

  -- Pre-render every table box
  local box_data = {}   -- t → { lines, meta, box_line_w }
  for _, t in ipairs(tables) do
    local cols   = state.col_cache[t] or {}
    local pk_set = state.pk_cache[t]  or {}
    local fk_map = state.fk_cache[t]  or {}
    local iw     = box_inner_width(t, cols, pk_set, fk_map)
    local lines, meta = render_box(t, cols, pk_set, fk_map, iw)
    local max_line_w = 0
    for _, l in ipairs(lines) do max_line_w = math.max(max_line_w, dw(l)) end
    box_data[t] = { lines = lines, meta = meta, line_w = max_line_w }
  end

  -- Compute DAG depths
  local depth, fk_out = compute_depths(tables, state.fk_cache)

  -- Group tables by depth, sort within each group
  local by_depth = {}
  local max_depth = 0
  for _, t in ipairs(tables) do
    local d = depth[t] or 0
    if not by_depth[d] then by_depth[d] = {} end
    table.insert(by_depth[d], t)
    max_depth = math.max(max_depth, d)
  end
  for d = 0, max_depth do
    if by_depth[d] then table.sort(by_depth[d]) end
  end

  -- Find isolated tables (neither referenced nor referencing others)
  local has_any_fk = {}  -- tables involved in any FK edge
  for from_t, refs in pairs(fk_out) do
    if #refs > 0 then
      has_any_fk[from_t] = true
      for _, ref in ipairs(refs) do has_any_fk[ref] = true end
    end
  end
  local isolated    = {}
  local non_isolated = {}
  for _, t in ipairs(tables) do
    if has_any_fk[t] then table.insert(non_isolated, t)
    else                   table.insert(isolated, t)
    end
  end
  table.sort(isolated)

  -- Build per-depth column renders (boxes stacked vertically)
  local col_lines = {}   -- d → list of strings
  local col_width = {}   -- d → max display width across all lines in this column
  for d = 0, max_depth do
    local tbls = by_depth[d] or {}
    local c_lines = {}
    local max_w   = 0
    for i, t in ipairs(tbls) do
      if i > 1 then table.insert(c_lines, "") end
      for _, l in ipairs(box_data[t].lines) do
        table.insert(c_lines, l)
        max_w = math.max(max_w, dw(l))
      end
    end
    col_lines[d] = c_lines
    col_width[d] = max_w
  end

  -- Merge depth columns side by side
  local DEPTH_GAP = 4
  local total_rows = 0
  for d = 0, max_depth do
    total_rows = math.max(total_rows, #(col_lines[d] or {}))
  end

  local out_lines = {}   -- final buffer lines
  local out_meta  = {}   -- parallel meta info per line
  local tbl_header_lines = {}  -- line_1idx → table_name (for <CR>)

  -- Title
  local short_url = url:match("[^/\\]+$") or url
  table.insert(out_lines, "  ER Diagram  ·  " .. short_url)
  table.insert(out_meta,  { kind = "title" })
  table.insert(out_lines, "")
  table.insert(out_meta,  { kind = "blank" })

  -- Track which absolute output line corresponds to each table header
  -- A table's header line is the 2nd line of its box (1-indexed within the box)
  -- We reconstruct this by replaying the column/row merge logic
  local function record_header_lines(base_out_line)
    for d = 0, max_depth do
      local tbls = by_depth[d] or {}
      local row_in_col = 1  -- 1-indexed position within col_lines[d]
      for ti, t in ipairs(tbls) do
        if ti > 1 then row_in_col = row_in_col + 1 end  -- blank separator
        -- Box header is 2nd line (row_in_col + 1 = after top border)
        local header_row_in_col = row_in_col + 1
        -- The merged output row index for this col row
        local out_row = base_out_line + header_row_in_col - 1
        tbl_header_lines[out_row] = t
        row_in_col = row_in_col + #box_data[t].lines
      end
    end
  end

  local main_content_base = #out_lines + 1
  record_header_lines(main_content_base)

  for row = 1, total_rows do
    local line = ""
    for d = 0, max_depth do
      local cl = (col_lines[d] or {})[row] or ""
      local cw = col_width[d] or 0
      local pad = math.max(0, cw - dw(cl))
      line = line .. cl .. string.rep(" ", pad)
      if d < max_depth then line = line .. string.rep(" ", DEPTH_GAP) end
    end
    table.insert(out_lines, line)
    table.insert(out_meta,  { kind = "content" })
  end

  -- Isolated tables section
  if #isolated > 0 then
    table.insert(out_lines, "")
    table.insert(out_meta,  { kind = "blank" })
    table.insert(out_lines, "  ── no FK relationships ──────────────────────────")
    table.insert(out_meta,  { kind = "section" })
    table.insert(out_lines, "")
    table.insert(out_meta,  { kind = "blank" })

    local COLS = 3
    local i = 1
    while i <= #isolated do
      local row_tbls = {}
      for j = i, math.min(i + COLS - 1, #isolated) do
        table.insert(row_tbls, isolated[j])
      end
      local max_h = 0
      for _, t in ipairs(row_tbls) do max_h = math.max(max_h, #box_data[t].lines) end

      -- Record header lines for isolated tables too
      local iso_base = #out_lines + 2  -- +1 for 1-indexed, +1 for top border
      for ji, t in ipairs(row_tbls) do
        tbl_header_lines[iso_base] = t
        -- iso_base is the same row for all (they start at the same output line)
        -- different columns are merged horizontally, so header line is the same row
        _ = ji  -- silence linter
      end

      for h = 1, max_h do
        local line = "  "
        for ji, t in ipairs(row_tbls) do
          local bl  = box_data[t].lines[h] or string.rep(" ", box_data[t].line_w)
          local bw  = box_data[t].line_w
          local pad = math.max(0, bw - dw(bl))
          line = line .. bl .. string.rep(" ", pad)
          if ji < #row_tbls then line = line .. "  " end
        end
        table.insert(out_lines, line)
        table.insert(out_meta,  { kind = "content" })
      end
      table.insert(out_lines, "")
      table.insert(out_meta,  { kind = "blank" })
      i = i + COLS
    end
  end

  return out_lines, out_meta, tbl_header_lines
end

-- ── highlight application ─────────────────────────────────────────────────────

local function apply_highlights(bufnr, lines, meta)
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)

  for i, line in ipairs(lines) do
    local m    = meta[i] or {}
    local kind = m.kind or ""
    local row  = i - 1  -- 0-indexed

    if kind == "title" or kind == "section" then
      vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripHeader", row, 0, -1)

    elseif kind == "content" then
      -- Scan the merged line for box-drawing and column indicators
      -- GripBorder on border chars; GripHeader on table name lines;
      -- GripBoolTrue on PK indicators (●); GripUrl on FK indicators (⬡)
      local s = line

      -- Table header lines: "│  TableName  │" (no ●/⬡/○ indicator)
      if s:match("^│  %S") and not s:match("[●⬡○]") then
        vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripHeader", row, 0, -1)
      end

      -- Highlight ├─ separator lines
      if s:match("^├─") or s:match("^│  %S[^●⬡○]") then
        -- already handled or border
      end

      -- Highlight border lines (top/separator/bottom)
      if s:match("^[┌├└]") then
        vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripBorder", row, 0, -1)
      end

      -- Highlight FK indicator and ref-table name
      local fk_byte = s:find("⬡")
      if fk_byte then
        -- Highlight from ⬡ to end of line
        vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripUrl", row, fk_byte - 1, -1)
      end

      -- Highlight PK indicator
      local pk_byte = s:find("●")
      if pk_byte then
        vim.api.nvim_buf_add_highlight(bufnr, _ns, "GripBoolTrue", row, pk_byte - 1, pk_byte + 2)
      end
    end
  end
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Show the ER diagram float for the given database URL.
function M.show(url)
  if not url or url == "" then
    vim.notify("ER Diagram: no database connection", vim.log.levels.WARN)
    return
  end

  -- Close any existing ER window
  if is_open() then close_er() end

  vim.notify("Building ER diagram...", vim.log.levels.INFO)
  local lines, meta, tbl_header_lines = build_content(url)

  -- Create buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "grip://er_diagram")
  vim.bo[bufnr].modifiable  = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable  = false
  vim.bo[bufnr].filetype    = "grip_er"
  vim.bo[bufnr].bufhidden   = "wipe"
  vim.bo[bufnr].buftype     = "nofile"

  apply_highlights(bufnr, lines, meta)

  -- Compute float dimensions
  local content_w = 0
  for _, l in ipairs(lines) do content_w = math.max(content_w, dw(l)) end
  local content_h = #lines

  local max_w = math.floor(vim.o.columns * 0.90)
  local max_h = math.floor(vim.o.lines   * 0.85)
  local width  = math.min(content_w + 2, max_w)
  local height = math.min(content_h, max_h)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height, row = row, col = col,
  })
  vim.wo[winid].wrap        = false
  vim.wo[winid].cursorline  = true

  _bufnr = bufnr
  _winid = winid

  -- Keymaps
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = bufnr, silent = true, nowait = true })
  end

  map("q",     close_er)
  map("<Esc>", close_er)
  map("gG",    close_er)

  -- <CR>: open table under cursor in grid
  map("<CR>", function()
    local row_1idx = vim.api.nvim_win_get_cursor(0)[1]
    local tbl_name = tbl_header_lines[row_1idx]
    -- Also scan the current line for a table name pattern
    if not tbl_name then
      local line = vim.api.nvim_buf_get_lines(bufnr, row_1idx - 1, row_1idx, false)[1] or ""
      tbl_name = line:match("^│  (%S[^│]*%S)%s*│")
        or line:match("^  │  (%S[^│]*%S)%s*│")
    end
    if not tbl_name then
      vim.notify("Move cursor to a table name line", vim.log.levels.INFO)
      return
    end
    tbl_name = vim.trim(tbl_name)
    close_er()
    require("dadbod-grip").open(tbl_name, url)
  end)

  -- WinLeave: close when focus leaves
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr, once = true,
    callback = function() close_er() end,
  })
end

--- Toggle the ER diagram float (close if open, show if closed).
function M.toggle(url)
  if is_open() then
    close_er()
  else
    M.show(url)
  end
end

return M
