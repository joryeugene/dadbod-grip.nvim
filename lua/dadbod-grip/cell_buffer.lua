-- cell_buffer.lua: open a cell value in a full split buffer (issue #18).
--
-- gB on a grid cell opens the value in a real window split instead of the
-- small float editor: JSON opens as stored with ft=json (syntax, folding),
-- prose columns get ft=markdown. :w stages the buffer content back
-- into the grid session via data.add_change — it never writes to the DB.
-- Read-only grids open the buffer in view mode (q closes).
--
-- M.render_value(value, col_name) -> lines, ft   pure, testable
-- M.open(grid_bufnr)              -> cell bufnr | nil

local data = require("dadbod-grip.data")

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripCellBuffer", { clear = true })

-- Columns whose name suggests prose: open with ft=markdown.
local PROSE_COLUMNS = {
  body = true, description = true, notes = true,
  content = true, text = true, bio = true,
}

-- ── JSON pretty-printer ──────────────────────────────────────────────────
-- Deterministic 2-space indent, object keys sorted. Scalars go through
-- vim.json.encode so string escaping stays valid JSON.

local function is_dict(t)
  if next(t) == nil then
    -- vim.json.decode("{}") carries the empty-dict metatable; "[]" does not
    return getmetatable(t) ~= nil
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return true end
    n = n + 1
  end
  return n ~= #t
end

--- Pretty-print a decoded JSON value as buffer lines.
--- First line is unindented (the caller prefixes it), continuation lines carry
--- absolute indentation for the given depth.
--- @param v any        decoded value (table, scalar, or vim.NIL)
--- @param depth number  indentation depth of this value (0 for the root)
--- @param max_depth? number  containers deeper than this collapse to "..."
--- @return string[] lines
local function pretty_lines(v, depth, max_depth)
  if type(v) ~= "table" then
    return { vim.json.encode(v) }  -- handles strings, numbers, bools, vim.NIL
  end
  if max_depth and depth >= max_depth then return { "..." } end
  local inner_pad = string.rep("  ", depth + 1)
  local close_pad = string.rep("  ", depth)
  if is_dict(v) then
    if next(v) == nil then return { "{}" } end
    local keys = {}
    for k in pairs(v) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    local lines = { "{" }
    for i, k in ipairs(keys) do
      local child = pretty_lines(v[k], depth + 1, max_depth)
      child[1] = inner_pad .. vim.json.encode(k) .. ": " .. child[1]
      if i < #keys then child[#child] = child[#child] .. "," end
      vim.list_extend(lines, child)
    end
    table.insert(lines, close_pad .. "}")
    return lines
  end
  if #v == 0 then return { "[]" } end
  local lines = { "[" }
  for i = 1, #v do
    local child = pretty_lines(v[i], depth + 1, max_depth)
    child[1] = inner_pad .. child[1]
    if i < #v then child[#child] = child[#child] .. "," end
    vim.list_extend(lines, child)
  end
  table.insert(lines, close_pad .. "]")
  return lines
end

-- Shared with view.lua's display floats (with a depth cap).
-- Editable buffers keep the stored text instead.
M.pretty_lines = pretty_lines

-- ── value rendering ──────────────────────────────────────────────────────

--- Decode value as JSON if it looks like an object/array; nil otherwise.
local function try_json(value)
  if type(value) ~= "string" then return nil end
  local trimmed = value:match("^%s*(.-)%s*$")
  local first = trimmed:sub(1, 1)
  if first ~= "{" and first ~= "[" then return nil end
  local ok, decoded = pcall(vim.json.decode, trimmed)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

--- Render a cell value into buffer lines plus a filetype.
--- Preserve the stored text: decoding/re-encoding JSON for an editable buffer
--- can round numbers and change keys or whitespace. JSON objects/arrays get
--- ft=json; prose-named columns get ft=markdown; everything else stays plain.
--- @param value string|nil  cell value (nil = NULL)
--- @param col_name string|nil
--- @return table lines, string|nil ft
function M.render_value(value, col_name)
  if value == nil then return { "" }, nil end
  local ft
  if try_json(value) then
    ft = "json"
  elseif col_name and PROSE_COLUMNS[col_name:lower()] then
    ft = "markdown"
  end
  return vim.split(value, "\n", { plain = true }), ft
end

-- ── open ─────────────────────────────────────────────────────────────────

--- Open the grid cell under cursor in a split buffer.
--- @param grid_bufnr integer  grip grid buffer
--- @return integer|nil  cell buffer number
function M.open(grid_bufnr)
  local view = require("dadbod-grip.view")
  local session = view._sessions[grid_bufnr]
  if not session then return nil end
  local cell = view.get_cell(grid_bufnr)
  if not cell then
    vim.notify("Move cursor to a data cell", vim.log.levels.INFO)
    return nil
  end

  local editable = view._is_editable(session) and cell.storage_type ~= "blob" and cell.storage_type ~= 'raw_unknown'
  local tbl = session.state.table_name or "result"
  local lines, ft
  if cell.storage_type == 'raw_unknown' then
    lines,ft={require('dadbod-grip.provenance').raw_display(cell.value)},nil
  elseif cell.storage_type == "blob" then
    lines, ft = { "<binary: " .. require("dadbod-grip.transport").hex(cell.value or "") .. ">" }, nil
  else
    lines,ft=M.render_value(cell.value,cell.col_name)
  end

  -- Split: horizontal ~40% height (default) or vertical ~40% width
  local split_style = require("dadbod-grip").get_opts().cell_split
  if split_style == "vertical" then
    vim.cmd("belowright vsplit")
    vim.api.nvim_win_set_width(0, math.max(20, math.floor(vim.o.columns * 0.4)))
  else
    vim.cmd("belowright split")
    vim.api.nvim_win_set_height(0, math.max(5, math.floor(vim.o.lines * 0.4)))
  end
  local win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  local name = ("grip://cell/%s/%s/%s"):format(tbl, cell.row_idx, cell.col_name)
  if vim.fn.bufnr(name) ~= -1 then name = name .. "#" .. buf end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  if ft then vim.api.nvim_set_option_value("filetype", ft, { buf = buf }) end
  vim.api.nvim_win_set_buf(win, buf)

  if not editable then
    -- View mode: reading a large JSON is valuable on its own
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("readonly", true, { buf = buf })
    vim.keymap.set("n", "q", function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, silent = true, nowait = true, desc = "Close cell view" })
    return buf
  end

  -- Editable: acwrite so :w fires BufWriteCmd (stage, don't write a file).
  -- q is intentionally NOT mapped here so macros still work; close with :q.
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
  vim.api.nvim_set_option_value("modified", false, { buf = buf })

  -- Baseline text: what the buffer opened with. :w with content identical to
  -- the baseline stages nothing. Updated after each successful stage so
  -- repeated :w stays quiet.
  local baseline = table.concat(lines, "\n")
  local is_current = require("dadbod-grip.write").capture_owner(grid_bufnr, session)
  local function stage(value)
    local s = view._sessions[grid_bufnr]
    if not s or not is_current() then
      vim.notify("Grid changed: nothing staged", vim.log.levels.WARN)
      return false
    end
    view.apply_edit(grid_bufnr, data.add_change(s.state, cell.row_idx, cell.col_name, value))
    is_current = require("dadbod-grip.write").capture_owner(grid_bufnr, s)
    return true
  end
  vim.api.nvim_buf_create_user_command(buf, "GripCellNull", function()
    if stage(nil) then vim.api.nvim_set_option_value("modified", false, { buf = buf }) end
  end, {})
  vim.api.nvim_buf_create_user_command(buf, "GripCellEmpty", function()
    if stage("") then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
      baseline = ""
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
    end
  end, {})

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = _ag,
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text == baseline then
        vim.api.nvim_set_option_value("modified", false, { buf = buf })
        vim.notify("No changes", vim.log.levels.INFO)
        return
      end
      local s = view._sessions[grid_bufnr]
      if not s or not vim.api.nvim_buf_is_valid(grid_bufnr) then
        vim.notify("Grid is gone: nothing staged", vim.log.levels.WARN)
        return
      end
      if not stage(text) then return end
      baseline = text
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
      vim.notify("Staged " .. tbl .. "." .. cell.col_name, vim.log.levels.INFO)
    end,
  })

  return buf
end

return M
