-- query_pad.lua: SQL scratch buffer that pipes results into grip grids.
-- ft=sql enables vim-dadbod-completion if installed.
-- b:db = connection URL for completion context.

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripQueryPad", { clear = true })
local _pad_bufnr = nil

--- Return true when `lines` contains real SQL content.
--- Strips the hint comment (-- C-CR:...) and AI separator (-- AI generated:)
--- before deciding. Blank/whitespace-only remaining lines = no real content.
--- This is the single canonical check used by sync_query, M.open, and append_sql.
local function _has_real_content(lines)
  local real = {}
  for _, line in ipairs(lines) do
    if not line:match("^%-%- C%-CR:") and not line:match("^%-%- AI generated:") then
      table.insert(real, line)
    end
  end
  return table.concat(real, "\n"):match("^%s*(.-)%s*$") ~= ""
end
M._has_real_content = _has_real_content  -- exported for unit tests

--- Register completion keymaps for the query pad buffer.
--- Called once at buffer creation and re-called on BufEnter (via vim.schedule) to
--- override buffer-local keymaps that completion plugins (blink.cmp etc.) register
--- on every BufEnter. Last registration wins; ours must be last.
local function setup_completion_keymaps(bufnr)
  local function fk(s)
    return vim.api.nvim_replace_termcodes(s, true, true, true)
  end

  -- C-Space: alias for <C-x><C-o>. Vim passes the actual typed word as base,
  -- so context parsing (table/column/keyword) works correctly.
  vim.keymap.set("i", "<C-Space>", function()
    vim.api.nvim_feedkeys(fk("<C-x><C-o>"), "n", false)
  end, { buffer = bufnr, silent = true, desc = "Grip: trigger SQL completion" })

  -- Tab: navigate cmp popup → navigate native popup → trigger omnifunc → literal tab.
  vim.keymap.set("i", "<Tab>", function()
    local ok, cmp = pcall(require, "cmp")
    if ok and cmp.visible() then
      cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
    elseif vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(fk("<C-n>"), "n", false)
    else
      local line = vim.api.nvim_get_current_line()
      local col  = vim.api.nvim_win_get_cursor(0)[2]
      if line:sub(1, col):match("[%a%d_%.%*]$") then
        vim.api.nvim_feedkeys(fk("<C-x><C-o>"), "n", false)
      else
        vim.api.nvim_feedkeys(fk("<Tab>"), "n", false)
      end
    end
  end, { buffer = bufnr, silent = true, desc = "Grip: trigger or navigate completion" })

  -- Down/Up/S-Tab: navigate popup (cmp or native), fall through otherwise.
  local function nav(next_key, prev_key, is_next)
    return function()
      local ok, cmp = pcall(require, "cmp")
      if ok and cmp.visible() then
        if is_next then
          cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
        else
          cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
        end
      elseif vim.fn.pumvisible() == 1 then
        vim.api.nvim_feedkeys(fk(is_next and "<C-n>" or "<C-p>"), "n", false)
      else
        vim.api.nvim_feedkeys(fk(is_next and next_key or prev_key), "n", false)
      end
    end
  end
  vim.keymap.set("i", "<Down>",  nav("<Down>",  "<Up>",   true),  { buffer = bufnr, silent = true, desc = "Grip: next completion or down" })
  vim.keymap.set("i", "<Up>",    nav("<Down>",  "<Up>",   false), { buffer = bufnr, silent = true, desc = "Grip: prev completion or up" })
  vim.keymap.set("i", "<S-Tab>", nav("<S-Tab>", "<S-Tab>",false), { buffer = bufnr, silent = true, desc = "Grip: prev completion or shift-tab" })

  -- CR: confirm selected item; otherwise normal newline.
  vim.keymap.set("i", "<CR>", function()
    local ok, cmp = pcall(require, "cmp")
    if ok and cmp.visible() and cmp.get_selected_entry() then
      cmp.confirm({ select = false })
    elseif vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(fk("<C-y>"), "n", false)
    else
      vim.api.nvim_feedkeys(fk("<CR>"), "n", false)
    end
  end, { buffer = bufnr, silent = true, desc = "Grip: confirm completion or newline" })
end

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
  -- SQL completion: three paths that cooperate.
  -- 1. omnifunc  → <C-x><C-o> (Vim-standard) and nvim-cmp { name = 'omni' } source
  -- 2. auto-trigger → TextChangedI fires vim.fn.complete() for non-cmp users
  -- 3. nvim-cmp source → register_cmp_source() so cmp users get first-class integration
  vim.bo[_pad_bufnr].omnifunc = "v:lua.require'dadbod-grip.completion'.omnifunc"
  local completion = require("dadbod-grip.completion")
  completion.setup_auto_complete(_pad_bufnr, function()
    return vim.b[_pad_bufnr].db or vim.g.db
  end)
  -- Register as nvim-cmp source (no-op when nvim-cmp is not installed).
  completion.register_cmp_source()
  -- Pre-warm schema cache so the first keystroke doesn't block on DB I/O.
  vim.schedule(function()
    local u = (vim.b[_pad_bufnr] and vim.b[_pad_bufnr].db) or vim.g.db
    if u and u ~= "" then pcall(completion.get_schema, u) end
  end)

  -- Pre-fill with hint comment
  vim.api.nvim_buf_set_lines(_pad_bufnr, 0, -1, false, {
    "-- C-CR:run  C-s:save  gA:ai  go:tables  gh:hist  gq:saved  gw:grid  gb:schema  gC:connect",
    "",
  })
  -- Mark buffer as not modified after creation
  vim.bo[_pad_bufnr].modified = false

  -- BufWriteCmd: save query with :GripSave
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group  = _ag,
    buffer = _pad_bufnr,
    callback = function()
      local saved = require("dadbod-grip.saved")
      saved.save_prompt(_pad_bufnr)
    end,
  })

  -- BufEnter: re-register completion keymaps after completion plugins (blink.cmp etc.)
  -- have had their BufEnter handlers run. vim.schedule defers us to after all BufEnter
  -- autocmds, so our buffer-local keymaps are always registered last and win.
  local bufnr_ref = _pad_bufnr
  vim.api.nvim_create_autocmd("BufEnter", {
    group  = _ag,
    buffer = _pad_bufnr,
    callback = function()
      vim.schedule(function() setup_completion_keymaps(bufnr_ref) end)
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
  local run_opts = reuse_win and { reuse_win = reuse_win } or {}
  run_opts.from_pad = true
  grip.open(sql, url, run_opts)
end

--- Set up buffer-local keymaps.
local function setup_keymaps(bufnr, url)
  -- Always read the live connection from the buffer variable so keymaps stay
  -- correct after gC / gq / any other path that switches the connection.
  local function cur_url() return vim.b[bufnr].db or vim.g.db or url end

  -- C-CR: run full buffer (use get_content to strip hint/AI-separator comment lines)
  vim.keymap.set("n", "<C-CR>", function()
    local sql = M.get_content()
    if sql then run_sql(cur_url(), sql) end
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  -- C-CR in insert mode too
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    local sql = M.get_content()
    if sql then run_sql(cur_url(), sql) end
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  setup_completion_keymaps(bufnr)

  -- Visual C-CR: run selection (line-wise: runs all selected lines)
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

  -- q: go to welcome screen (home)
  vim.keymap.set("n", "q", function()
    require("dadbod-grip").open_welcome()
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Grip: welcome screen" })

  -- gA: AI SQL generation (keep g-prefix in query pad to preserve A=append-at-EOL)
  vim.keymap.set("n", "gA", function()
    local ai = require("dadbod-grip.ai")
    ai.ask(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: AI SQL generation" })

  -- gb: schema browser sidebar
  vim.keymap.set("n", "gb", function()
    require("dadbod-grip.schema").toggle(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: schema browser" })

  -- gG: ER diagram float
  vim.keymap.set("n", "gG", function()
    require("dadbod-grip.er_diagram").toggle(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: ER diagram" })

  -- gw: jump to main content window: grid > welcome (silent no-op if neither exists)
  vim.keymap.set("n", "gw", function()
    local win = require("dadbod-grip.view").find_content_win()
    if win then vim.api.nvim_set_current_win(win) end
  end, { buffer = bufnr, silent = true, nowait = true, desc = "Grip: jump to grid" })

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

  -- Q: go to welcome screen (home)
  vim.keymap.set("n", "Q", function()
    require("dadbod-grip").open_welcome()
  end, { buffer = bufnr, silent = true, desc = "Grip: welcome screen" })

  -- ?: help popup (same full grid help: useful for keymap reference while writing SQL)
  vim.keymap.set("n", "?", function()
    require("dadbod-grip.view").show_help()
  end, { buffer = bufnr, silent = true, desc = "Grip: help" })

  -- gC / <C-g>: switch database connection
  local function _pick_conn()
    require("dadbod-grip.connections").pick()
  end
  vim.keymap.set("n", "gC", _pick_conn, { buffer = bufnr, silent = true, desc = "Grip: switch connection" })
  vim.keymap.set("n", "<C-g>", _pick_conn, { buffer = bufnr, silent = true, desc = "Grip: switch connection" })

  -- ── tab view keymaps (1-9) ───────────────────────────────────────────────
  -- 1-3: surface navigation  4=ER diagram float  5-9: table-depth views
  local VIEW_MAP = { [4]="er_diagram", [5]="stats", [6]="columns",
                     [7]="fk", [8]="indexes", [9]="constraints" }

  -- 1: schema sidebar (primary, not in sidebar right now)
  vim.keymap.set("n", "1", function()
    require("dadbod-grip.view").close_all_floats(nil)
    require("dadbod-grip.schema").toggle(cur_url())
  end, { buffer = bufnr, silent = true, desc = "Grip: schema sidebar" })

  -- 2: query history (secondary, already in query pad)
  vim.keymap.set("n", "2", function()
    require("dadbod-grip.view").close_all_floats(nil)
    require("dadbod-grip.history").pick(function(sql_content)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(sql_content, "\n"))
      vim.bo[bufnr].modified = false
    end)
  end, { buffer = bufnr, silent = true, desc = "Grip: query history" })

  -- 3: jump to grid (primary), or table picker if no grid is open
  vim.keymap.set("n", "3", function()
    local view_mod = require("dadbod-grip.view")
    view_mod.close_all_floats(nil)
    local win = view_mod.find_content_win()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      local u = cur_url()
      require("dadbod-grip.picker").pick_table(u, function(name)
        require("dadbod-grip").open(name, u)
      end)
    end
  end, { buffer = bufnr, silent = true, desc = "Grip: jump to grid" })

  -- 4: ER diagram float; 5-9: jump to grid + switch to that view
  for n = 4, 9 do
    local view_name = VIEW_MAP[n]
    vim.keymap.set("n", tostring(n), function()
      local view_mod = require("dadbod-grip.view")
      view_mod.close_all_floats(nil)
      if view_name == "er_diagram" then
        require("dadbod-grip.er_diagram").toggle(cur_url())
        return
      end
      local win = view_mod.find_content_win()
      if win then
        local gbuf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_set_current_win(win)
        view_mod.switch_view(gbuf, view_name)
      else
        local u = cur_url()
        require("dadbod-grip.picker").pick_table(u, function(name)
          require("dadbod-grip").open(name, u)
        end)
      end
    end, { buffer = bufnr, silent = true, desc = "Grip: view " .. view_name })
  end
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
        -- If the target has a grip grid or welcome screen, split above it instead of replacing
        local target_buf = vim.api.nvim_win_get_buf(target_win)
        local target_name = vim.api.nvim_buf_get_name(target_buf)
        local view_mod = require("dadbod-grip.view")
        if view_mod._sessions[target_buf] or target_name == "grip://welcome" then
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
      -- Find a grip grid or welcome window and open above it
      local view_mod = require("dadbod-grip.view")
      local grid_win = nil
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local wbuf = vim.api.nvim_win_get_buf(winid)
        local wname = vim.api.nvim_buf_get_name(wbuf)
        if view_mod._sessions[wbuf] or wname == "grip://welcome" then
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

  -- Pre-fill if requested and buffer has no real SQL content
  if opts.initial_sql then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if not _has_real_content(lines) then
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

  local sql_lines = vim.split(sql_text, "\n")
  vim.bo[_pad_bufnr].modifiable = true
  if not _has_real_content(lines) or opts.replace then
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

--- Silently sync the query pad with the SQL from the just-opened grid.
--- Called automatically when a table or query opens from outside the pad (sidebar,
--- table picker, FK navigation). No-op if the pad buffer doesn't exist yet.
--- Behaviour: populate an empty/hint-only pad; append below existing content
--- so user queries are never clobbered.
function M.sync_query(sql_text)
  if not _pad_bufnr or not vim.api.nvim_buf_is_valid(_pad_bufnr) then return end
  if not sql_text or sql_text:match("^%s*$") then return end
  local lines = vim.api.nvim_buf_get_lines(_pad_bufnr, 0, -1, false)
  local sql_lines = vim.split(sql_text, "\n")
  vim.bo[_pad_bufnr].modifiable = true
  if not _has_real_content(lines) then
    vim.api.nvim_buf_set_lines(_pad_bufnr, 0, -1, false, sql_lines)
  else
    local append = { "" }
    vim.list_extend(append, sql_lines)
    vim.api.nvim_buf_set_lines(_pad_bufnr, -1, -1, false, append)
    local total = vim.api.nvim_buf_line_count(_pad_bufnr)
    local win = vim.fn.bufwinid(_pad_bufnr)
    if win ~= -1 then pcall(vim.api.nvim_win_set_cursor, win, { total, 0 }) end
  end
  vim.bo[_pad_bufnr].modified = false
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

--- Testing hook: override the internal pad buffer reference.
--- NOT for production use.
function M._set_pad_bufnr(bufnr)
  _pad_bufnr = bufnr
end

return M
