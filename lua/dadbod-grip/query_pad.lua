-- query_pad.lua — SQL scratch buffer that pipes results into grip grids.
-- ft=sql enables vim-dadbod-completion if installed.
-- b:db = connection URL for completion context.

local M = {}

local _pad_bufnr = nil

--- Get or create the query pad buffer.
local function ensure_buf(url)
  if _pad_bufnr and vim.api.nvim_buf_is_valid(_pad_bufnr) then
    -- Update connection if changed
    vim.b[_pad_bufnr].db = url
    return _pad_bufnr
  end

  _pad_bufnr = vim.api.nvim_create_buf(true, false)
  vim.bo[_pad_bufnr].buftype = "acwrite"
  vim.bo[_pad_bufnr].swapfile = false
  vim.bo[_pad_bufnr].filetype = "sql"
  vim.api.nvim_buf_set_name(_pad_bufnr, "grip://query")
  vim.b[_pad_bufnr].db = url

  -- Pre-fill with hint comment
  vim.api.nvim_buf_set_lines(_pad_bufnr, 0, -1, false, {
    "-- C-CR:run  C-s:save  gA:ai  go:tables  gh:hist  gq:saved  gw:grid  gb:schema  gC:connect",
    "",
  })
  -- Mark buffer as not modified after creation
  vim.bo[_pad_bufnr].modified = false

  -- BufWriteCmd: save query with :GripSave
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = _pad_bufnr,
    callback = function()
      local saved = require("dadbod-grip.saved")
      saved.save_prompt(_pad_bufnr)
    end,
  })

  return _pad_bufnr
end

--- Run SQL from the query pad and open results in a grip grid.
--- Reuses an existing grip grid window if one exists; closes extras.
local function run_sql(url, sql)
  if not sql or sql:match("^%s*$") then
    vim.notify("Grip: empty query", vim.log.levels.WARN)
    return
  end
  -- Find ALL existing grip grid windows (close extras, reuse the first)
  local reuse_win = nil
  local view = require("dadbod-grip.view")
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wbuf = vim.api.nvim_win_get_buf(winid)
    local is_grid = false
    -- Check session registry (definitive)
    if view._sessions[wbuf] then
      is_grid = true
    else
      -- Fallback: check buffer name pattern (grip://result, grip://tablename, etc.)
      local bname = vim.api.nvim_buf_get_name(wbuf)
      if bname:match("^grip://") and not bname:match("grip://query") and not bname:match("grip://schema") then
        is_grid = true
      end
    end
    if is_grid then
      if not reuse_win then
        reuse_win = winid
      else
        -- Close duplicate grid windows
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end
  local grip = require("dadbod-grip")
  grip.open(sql, url, reuse_win and { reuse_win = reuse_win } or nil)
end

--- Set up buffer-local keymaps.
local function setup_keymaps(bufnr, url)
  -- Always read the live connection from the buffer variable so keymaps stay
  -- correct after gC / gq / any other path that switches the connection.
  local function cur_url() return vim.b[bufnr].db or vim.g.db or url end

  -- C-CR: run full buffer
  vim.keymap.set("n", "<C-CR>", function()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    run_sql(cur_url(), table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  -- C-CR in insert mode too
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    run_sql(cur_url(), table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  -- Visual C-CR: run selection (line-wise — runs all selected lines)
  vim.keymap.set("v", "<C-CR>", function()
    -- feedkeys Esc to exit visual mode and set '< '> marks, then run
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "nx", false)
    local start_line = vim.fn.line("'<")
    local end_line = vim.fn.line("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #lines == 0 then return end
    run_sql(cur_url(), table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run selection" })

  -- C-s: save query
  vim.keymap.set("n", "<C-s>", function()
    local saved = require("dadbod-grip.saved")
    saved.save_prompt(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Grip: save query" })

  -- gA: AI SQL generation (keep g-prefix in query pad to preserve A=append-at-EOL)
  vim.keymap.set("n", "gA", function()
    local ai = require("dadbod-grip.ai")
    ai.ask(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: AI SQL generation" })

  -- gb: schema browser sidebar
  vim.keymap.set("n", "gb", function()
    require("dadbod-grip.schema").toggle(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: schema browser" })

  -- gw: jump to grid window (if one exists)
  vim.keymap.set("n", "gw", function()
    local view = require("dadbod-grip.view")
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local wbuf = vim.api.nvim_win_get_buf(winid)
      if view._sessions[wbuf] then
        vim.api.nvim_set_current_win(winid)
        return
      end
    end
    vim.notify("No grid window open", vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true, desc = "Grip: jump to grid" })

  -- go / gT / gt: table picker
  local function _pick_table()
    local picker = require("dadbod-grip.picker")
    local u = cur_url()
    picker.pick_table(u, function(name)
      require("dadbod-grip").open(name, u)
    end)
  end
  vim.keymap.set("n", "go", _pick_table, { buffer = bufnr, silent = true, desc = "Grip: pick table" })
  vim.keymap.set("n", "gT", _pick_table, { buffer = bufnr, silent = true, desc = "Grip: pick table" })
  vim.keymap.set("n", "gt", _pick_table, { buffer = bufnr, silent = true, desc = "Grip: pick table" })

  -- gh: query history
  vim.keymap.set("n", "gh", function()
    local hist = require("dadbod-grip.history")
    hist.pick(function(sql_content)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { buffer = bufnr, silent = true, desc = "Grip: query history" })

  -- gq: load saved query into buffer (cur_url() re-reads after any connection auto-switch)
  vim.keymap.set("n", "gq", function()
    local saved = require("dadbod-grip.saved")
    saved.pick(function(sql_content)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { buffer = bufnr, silent = true, desc = "Grip: load saved query" })

  -- ?: help popup (same full grid help — useful for keymap reference while writing SQL)
  vim.keymap.set("n", "?", function()
    require("dadbod-grip.view").show_help()
  end, { buffer = bufnr, silent = true, desc = "Grip: help" })

  -- gC / <C-g>: switch database connection
  local function _pick_conn()
    require("dadbod-grip.connections").pick()
  end
  vim.keymap.set("n", "gC", _pick_conn, { buffer = bufnr, silent = true, desc = "Grip: switch connection" })
  vim.keymap.set("n", "<C-g>", _pick_conn, { buffer = bufnr, silent = true, desc = "Grip: switch connection" })
end

--- Open the query pad.
--- @param url string connection URL
--- @param opts? { initial_sql?: string }
function M.open(url, opts)
  opts = opts or {}

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Use :GripConnect or set vim.g.db.", vim.log.levels.WARN)
      return
    end
  end

  local bufnr = ensure_buf(url)
  setup_keymaps(bufnr, url)

  -- Find or create a window for the pad
  local pad_win = nil
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      pad_win = winid
      break
    end
  end

  if not pad_win then
    -- When schema sidebar is open, open in the right-side area (not full-width bottom)
    local schema = require("dadbod-grip.schema")
    if schema.is_open() then
      -- Find the first non-sidebar window
      local target_win = nil
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(winid)
        local ft = vim.bo[wbuf].filetype
        if ft ~= "grip_schema" then
          target_win = winid
          break
        end
      end
      if target_win then
        vim.api.nvim_set_current_win(target_win)
        -- If the target has a grip grid, split above it instead of replacing
        local target_buf = vim.api.nvim_win_get_buf(target_win)
        local view_mod = require("dadbod-grip.view")
        if view_mod._sessions[target_buf] then
          vim.cmd("aboveleft split")
          pad_win = vim.api.nvim_get_current_win()
          vim.api.nvim_win_set_buf(pad_win, bufnr)
          vim.api.nvim_win_set_height(pad_win, math.max(6, math.min(12, math.floor(vim.o.lines * 0.2))))
        else
          vim.api.nvim_win_set_buf(target_win, bufnr)
          pad_win = target_win
        end
      else
        vim.cmd("botright split")
        pad_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(pad_win, bufnr)
        vim.api.nvim_win_set_height(pad_win, math.max(6, math.min(12, math.floor(vim.o.lines * 0.2))))
      end
    else
      -- Find a grip grid window and open above it
      local view_mod = require("dadbod-grip.view")
      local grid_win = nil
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(winid)
        if view_mod._sessions[wbuf] then
          grid_win = winid
          break
        end
      end
      if grid_win then
        vim.api.nvim_set_current_win(grid_win)
        vim.cmd("aboveleft split")
      else
        vim.cmd("botright split")
      end
      pad_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(pad_win, bufnr)
      vim.api.nvim_win_set_height(pad_win, math.max(6, math.min(12, math.floor(vim.o.lines * 0.2))))
    end
  end

  vim.api.nvim_set_current_win(pad_win)

  -- Pre-fill if requested and buffer has only the hint or is empty
  if opts.initial_sql then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")
    local is_hint = #lines >= 1 and lines[1]:match("^%-%- C%-CR:")
    if is_empty or is_hint then
      local sql_lines = vim.split(opts.initial_sql, "\n")
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sql_lines)
      vim.bo[bufnr].modified = false
    end
  end
end

--- Append or replace SQL text in the query pad buffer.
--- Replaces hint/empty content; appends with separator when content exists.
--- opts.replace = true: replace entire buffer (used when AI modifies existing query).
function M.append_sql(sql_text, opts)
  opts = opts or {}
  if not _pad_bufnr or not vim.api.nvim_buf_is_valid(_pad_bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(_pad_bufnr, 0, -1, false)
  local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")
  local is_hint = #lines >= 1 and lines[1]:match("^%-%- C%-CR:")

  local sql_lines = vim.split(sql_text, "\n")
  vim.bo[_pad_bufnr].modifiable = true
  if is_empty or is_hint or opts.replace then
    vim.api.nvim_buf_set_lines(_pad_bufnr, 0, -1, false, sql_lines)
  else
    local append = { "", "-- AI generated:" }
    vim.list_extend(append, sql_lines)
    vim.api.nvim_buf_set_lines(_pad_bufnr, -1, -1, false, append)
  end
  vim.bo[_pad_bufnr].modified = false
  -- Move cursor to the new SQL
  local total = vim.api.nvim_buf_line_count(_pad_bufnr)
  local win = vim.fn.bufwinid(_pad_bufnr)
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { total, 0 })
  end
end

--- Get the current query pad content (nil if empty or hint-only).
function M.get_content()
  if not _pad_bufnr or not vim.api.nvim_buf_is_valid(_pad_bufnr) then return nil end
  local lines = vim.api.nvim_buf_get_lines(_pad_bufnr, 0, -1, false)
  if #lines == 0 then return nil end
  -- Filter out hint comment and AI separator lines, keep real SQL
  local real = {}
  for _, line in ipairs(lines) do
    if not line:match("^%-%- C%-CR:") and not line:match("^%-%- AI generated:") then
      table.insert(real, line)
    end
  end
  local content = table.concat(real, "\n"):match("^%s*(.-)%s*$")
  if content == "" then return nil end
  return content
end

return M
