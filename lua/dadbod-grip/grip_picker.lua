-- grip_picker.lua: self-contained floating list picker. Zero external deps.
--
-- M.open(opts):
--   title    : string                       float title
--   items    : table                        list of any type (required)
--   display  : fn(item) -> string           optional; defaults to tostring
--   on_select: fn(item)                     called when Enter pressed
--   on_delete: fn(item, refresh_fn)         optional; enables D key.
--                                           caller deletes, then calls
--                                           refresh_fn(new_items) to re-render.
--   preview  : fn(item) -> string[]         optional; enables side preview pane.
--                                           return lines to show in the pane.
--
-- Keymaps (buffer-local, normal mode):
--   j / <Down>   Move down (wraps)
--   k / <Up>     Move up (wraps)
--   Enter        Select hovered item, close picker
--   D            Delete hovered item (only when on_delete is provided)
--   / or gp      Open filter input (cmdline); empty = clear filter
--   F            Clear current filter
--   n / N        Cycle next / prev match
--   q / <Esc>    Close without selection
--
-- Visual (with preview):
--   ╭─── Saved Queries (5) ─────╮  ╭── Preview ─────────────────────────────╮
--   │  ▶ employees-by-dept      │  │  SELECT e.name, d.name                 │
--   │    revenue-monthly        │  │  FROM employees e                      │
--   │    users-inactive         │  │  JOIN departments d ON d.id = e.dept   │
--   │                           │  │  WHERE e.active = true                 │
--   │  Enter:select  /:filter  q│  ╰────────────────────────────────────────╯
--   ╰───────────────────────────╯

local M = {}

local _ag = vim.api.nvim_create_augroup("DadbodGripPicker", { clear = true })

-- ── helpers ──────────────────────────────────────────────────────────────────

local function clamp(n, lo, hi)
  if hi < lo then return lo end
  return math.max(lo, math.min(hi, n))
end

-- ── open ─────────────────────────────────────────────────────────────────────

function M.open(opts)
  assert(opts, "grip_picker.open: opts required")
  local display   = opts.display or tostring
  local on_select = opts.on_select
  local on_cancel = opts.on_cancel  -- fn() called when closed without selection
  local on_delete = opts.on_delete
  local preview_fn = opts.preview   -- fn(item) -> string[] | nil
  local actions   = opts.actions or {}  -- list of {key, label, fn(item)}
  local title     = opts.title or "Grip Picker"

  -- Mutable state
  local items    = opts.items or {}
  local filter   = ""
  local cursor   = 1
  local _selected = false  -- true once a real selection or action fires

  -- ── filter ──

  local function filtered_items()
    if filter == "" then return items end
    local out = {}
    for _, item in ipairs(items) do
      if tostring(display(item)):lower():find(filter:lower(), 1, true) then
        table.insert(out, item)
      end
    end
    return out
  end

  -- ── buffers ──

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = popup_buf })
  vim.b[popup_buf].grip_owned_float = true

  local preview_buf, preview_win
  if preview_fn then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = preview_buf })
    vim.bo[preview_buf].filetype = "sql"
    vim.b[preview_buf].grip_owned_float = true
  end

  -- ── dimension helpers ──

  local PREVIEW_W   = 54   -- max preview pane width
  local PREVIEW_GAP = 2    -- columns between picker and preview

  local function calc_width(flist)
    local min_w = math.max(#title + 6, 30)
    local max_w = math.min(vim.o.columns - 6, 70)
    local content_w = min_w
    for _, item in ipairs(flist) do
      content_w = math.max(content_w, vim.fn.strdisplaywidth(tostring(display(item))) + 6)
    end
    return clamp(content_w, min_w, max_w)
  end

  local function calc_height(flist)
    local item_count = math.max(1, #flist)
    local overhead = 2  -- separator + footer
    return math.min(item_count + overhead, math.floor(vim.o.lines * 0.6))
  end

  -- Available width for the preview pane given picker_w.
  local function get_pv_w(picker_w)
    if not preview_fn then return 0 end
    local avail = vim.o.columns - picker_w - PREVIEW_GAP - 4
    local w = math.min(PREVIEW_W, avail)
    return (w >= 20) and w or 0
  end

  -- Left edge column for the picker, accounting for the preview pane.
  local function get_picker_col(picker_w)
    local pvw = get_pv_w(picker_w)
    local total = picker_w + (pvw > 0 and (PREVIEW_GAP + pvw) or 0)
    return math.floor((vim.o.columns - total) / 2)
  end

  -- ── window management ──

  local win

  local function open_wins(w, h)
    local col = get_picker_col(w)
    local row = math.floor((vim.o.lines - h) / 2)
    local new_win = vim.api.nvim_open_win(popup_buf, true, {
      relative    = "editor",
      row         = row,
      col         = col,
      width       = w,
      height      = h,
      style       = "minimal",
      border      = "rounded",
      title       = " " .. title .. " ",
      title_pos   = "center",
      zindex      = 55,
    })
    if preview_fn then
      local pvw = get_pv_w(w)
      if pvw >= 20 then
        local _ei = vim.o.eventignore
        vim.o.eventignore = "all"
        preview_win = vim.api.nvim_open_win(preview_buf, false, {
          relative   = "editor",
          row        = row,
          col        = col + w + PREVIEW_GAP,
          width      = pvw,
          height     = h,
          style      = "minimal",
          border     = "rounded",
          title      = " Preview ",
          title_pos  = "center",
          focusable  = false,
          zindex     = 54,
        })
        vim.o.eventignore = _ei
        vim.wo[preview_win].wrap = true
      end
    end
    return new_win
  end

  -- Update preview buffer content for the current cursor item.
  local function update_preview()
    if not preview_fn or not preview_buf
        or not vim.api.nvim_buf_is_valid(preview_buf) then return end
    local flist = filtered_items()
    local item  = flist[cursor]
    local lines = (item and preview_fn(item)) or { "" }
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
  end

  -- ── render ──

  local function render()
    if not vim.api.nvim_buf_is_valid(popup_buf) then return end

    local flist = filtered_items()
    cursor = clamp(cursor, 1, math.max(1, #flist))

    local lines = {}

    -- Filter indicator
    if filter ~= "" then
      table.insert(lines, "  / " .. filter)
    end

    -- Items
    if #flist == 0 then
      table.insert(lines, "  (no items)")
    else
      local w = vim.api.nvim_win_is_valid(win or 0)
          and vim.api.nvim_win_get_width(win)
          or calc_width(flist)
      local max_name = w - 6
      for i, item in ipairs(flist) do
        local label = tostring(display(item))
        if #label > max_name then
          label = label:sub(1, max_name - 1) .. "…"
        end
        local prefix = (i == cursor) and "  ▶ " or "    "
        table.insert(lines, prefix .. label)
      end
    end

    -- Separator + footer
    table.insert(lines, "")
    local footer_parts = { "Enter:select" }
    if on_delete then table.insert(footer_parts, "D:delete") end
    -- Contextual actions: show label only when applicable for current item
    local flist_for_footer = filtered_items()
    local cur_item = flist_for_footer[cursor]
    for _, action in ipairs(actions) do
      local show = true
      if action.when and cur_item then
        show = action.when(cur_item)
      end
      if show then
        table.insert(footer_parts, action.label)
      end
    end
    table.insert(footer_parts, "/:filter")
    table.insert(footer_parts, "q:close")
    table.insert(lines, "  " .. table.concat(footer_parts, "  "))

    -- Resize picker float
    local new_w = calc_width(flist)
    local new_h = calc_height(flist) + (filter ~= "" and 1 or 0)

    vim.bo[popup_buf].modifiable = true
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
    vim.bo[popup_buf].modifiable = false

    if vim.api.nvim_win_is_valid(win or 0) then
      local col = get_picker_col(new_w)
      local row = math.floor((vim.o.lines - new_h) / 2)
      pcall(vim.api.nvim_win_set_config, win, {
        relative = "editor", row = row, col = col, width = new_w, height = new_h,
      })
      -- Move cursor to item row (skip filter line if present)
      local item_offset = (filter ~= "" and 1 or 0)
      pcall(vim.api.nvim_win_set_cursor, win, { cursor + item_offset, 0 })
    end

    -- Sync preview window size + position + content
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      local col    = get_picker_col(new_w)
      local pvw    = get_pv_w(new_w)
      local row    = math.floor((vim.o.lines - new_h) / 2)
      pcall(vim.api.nvim_win_set_config, preview_win, {
        relative = "editor",
        row      = row,
        col      = col + new_w + PREVIEW_GAP,
        width    = pvw,
        height   = new_h,
      })
    end
    update_preview()
  end

  -- ── open initial windows ──

  local initial_flist = filtered_items()
  local init_w = calc_width(initial_flist)
  local init_h = calc_height(initial_flist)
  win = open_wins(init_w, init_h)

  -- ── keymaps ──

  local function map(keys, fn)
    for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set("n", k, fn, { buffer = popup_buf, nowait = true, silent = true })
    end
  end

  -- Close (both picker and preview)
  local function close()
    local was_open = vim.api.nvim_win_is_valid(win)
    if was_open then
      vim.api.nvim_win_close(win, true)
    end
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    if was_open and not _selected and on_cancel then
      vim.schedule(on_cancel)
    end
  end

  -- Close when focus leaves the picker (navigating away with <C-w>, :e, etc.)
  -- Registered after close() is defined so the closure captures a non-nil upvalue.
  vim.api.nvim_create_autocmd("WinLeave", {
    group  = _ag,
    buffer = popup_buf,
    callback = function() vim.schedule(close) end,
  })

  map({ "q", "<Esc>" }, close)

  -- 1-9: close picker and replay the key on the underlying buffer so surface
  -- navigation works even when a picker float has focus.
  for _, k in ipairs({ "1","2","3","4","5","6","7","8","9" }) do
    local key = k
    map(key, function()
      close()
      vim.schedule(function()
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
      end)
    end)
  end

  -- Navigation
  map({ "j", "<Down>" }, function()
    local flist = filtered_items()
    if #flist == 0 then return end
    cursor = cursor >= #flist and 1 or cursor + 1
    render()
  end)

  map({ "k", "<Up>" }, function()
    local flist = filtered_items()
    if #flist == 0 then return end
    cursor = cursor <= 1 and #flist or cursor - 1
    render()
  end)

  -- Select
  map("<CR>", function()
    local flist = filtered_items()
    if #flist == 0 then return end
    local item = flist[cursor]
    if not item then return end
    _selected = true
    close()
    if on_select then
      vim.schedule(function() on_select(item) end)
    end
  end)

  -- Delete
  if on_delete then
    map("D", function()
      local flist = filtered_items()
      if #flist == 0 then return end
      local item = flist[cursor]
      if not item then return end

      local function refresh_fn(new_items)
        items = new_items or {}
        local new_flist = filtered_items()
        cursor = clamp(cursor, 1, math.max(1, #new_flist))
        if vim.api.nvim_win_is_valid(win) then
          render()
        end
      end

      on_delete(item, refresh_fn)
    end)
  end

  -- Custom actions (e.g. M:mask, W:watch, !:write)
  -- action.close_on_select = true: close picker then call fn (like on_select)
  -- action.close_on_select = false/nil: call fn then re-render (stateful toggle)
  for _, action in ipairs(actions) do
    map(action.key, function()
      local flist = filtered_items()
      if #flist == 0 then return end
      local item = flist[cursor]
      if not item then return end
      if action.close_on_select then
        _selected = true
        close()
        if action.fn then vim.schedule(function() action.fn(item) end) end
      else
        if action.fn then action.fn(item) end
        render()
      end
    end)
  end

  -- Filter (/ or gp)
  -- vim.fn.input() always uses native cmdline: never intercepted by dressing/noice
  local function activate_filter()
    local prompt = filter ~= "" and ("Filter [" .. filter .. "]: ") or "Filter: "
    local CANCEL = "\0"
    local ok, input = pcall(vim.fn.input, { prompt = prompt, default = filter, cancelreturn = CANCEL })
    if not ok or input == CANCEL then return end  -- Ctrl-C or Esc = no change
    filter = input
    cursor = 1
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      render()
    end
  end

  -- F: clear current filter
  map("F", function()
    filter = ""
    cursor = 1
    render()
  end)

  map({ "/", "gp" }, activate_filter)

  -- n/N: cycle through filtered results (next/prev)
  map("n", function()
    local flist = filtered_items()
    if #flist == 0 then return end
    cursor = cursor >= #flist and 1 or cursor + 1
    render()
  end)

  map("N", function()
    local flist = filtered_items()
    if #flist == 0 then return end
    cursor = cursor <= 1 and #flist or cursor - 1
    render()
  end)

  -- ── initial render ──

  render()
end

--- Dispatch to configured picker backend. Falls back to built-in when:
--- (a) opts.actions is non-empty (complex pickers need built-in features),
--- (b) the configured backend is not installed.
function M.pick(opts)
  local picker_type = require("dadbod-grip").get_opts().picker
  if picker_type ~= "builtin" and not (opts.actions and #opts.actions > 0) then
    local mod = "dadbod-grip.pickers." .. picker_type
    local ok, backend = pcall(require, mod)
    if ok then return backend.open(opts) end
  end
  return M.open(opts)
end

return M
