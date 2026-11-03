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

local ui = require("dadbod-grip.ui")

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
  local first_visible = 1
  local _selected = false  -- true once a real selection or action fires

  -- ── filter ──

  -- render() alone calls filtered_items() twice, and several key handlers
  -- call it again before render() to read the hovered item. Memoize on
  -- (filter, items): `items` is only ever reassigned wholesale (see
  -- refresh_fn below), never mutated in place, so reference identity is
  -- enough to detect a fresh item list. Because the check compares against
  -- the live `filter`/`items` upvalues rather than a separate "dirty" flag,
  -- there is no invalidation step that could run too late relative to a
  -- query edit — any call, from anywhere, recomputes the moment either
  -- value differs from what produced the cached result.
  local _cache_filter, _cache_items, _cache_result

  local function filtered_items()
    if _cache_filter == filter and _cache_items == items then
      return _cache_result
    end
    local result
    if filter == "" then
      result = items
    else
      result = {}
      local needle = filter:lower()
      for _, item in ipairs(items) do
        if tostring(display(item)):lower():find(needle, 1, true) then
          table.insert(result, item)
        end
      end
    end
    _cache_filter, _cache_items, _cache_result = filter, items, result
    return result
  end

  -- Force the next filtered_items() call to recompute. Needed wherever
  -- something `display()` reads can change without `filter` or `items`
  -- moving — e.g. a custom action (like connections.lua's M:mask) that
  -- toggles state captured by the caller's `display` closure. `filter` is
  -- always a string, so nil can never match it, guaranteeing a miss.
  local function invalidate_cache()
    _cache_filter = nil
  end

  -- ── buffers ──

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = popup_buf })
  vim.b[popup_buf].grip_owned_float = true

  local preview_buf, preview_win

  -- ── dimension helpers ──

  local PREVIEW_W   = 54   -- max preview pane width
  local PREVIEW_GAP = 2    -- columns between picker and preview

  local function footer_parts()
    local parts = { "Enter:select" }
    if on_delete then parts[#parts + 1] = "D:delete" end
    local current = filtered_items()[cursor]
    for _, action in ipairs(actions) do
      if not action.when or not current or action.when(current) then parts[#parts + 1] = action.label end
    end
    parts[#parts + 1], parts[#parts + 2] = "/:filter", "q:close"
    return parts
  end

  local function footer_lines(w, parts)
    local lines, line = {}, "  "
    for _, part in ipairs(parts) do
      part = ui.truncate_display(part, math.max(1, w - 2), true)
      if line ~= "  " and vim.fn.strdisplaywidth(line .. "  " .. part) > w then
        lines[#lines + 1], line = line, "  "
      end
      line = line .. (line == "  " and "" or "  ") .. part
    end
    lines[#lines + 1] = line
    return lines
  end

  local function calc_width(flist, parts)
    local max_w = math.max(1, math.min(vim.o.columns - 6, 70))
    local min_w = math.min(math.max(vim.fn.strdisplaywidth(title) + 6, 30), max_w)
    local content_w = min_w
    for _, item in ipairs(flist) do
      content_w = math.max(content_w, vim.fn.strdisplaywidth(tostring(display(item))) + 6)
    end
    content_w = math.max(content_w, vim.fn.strdisplaywidth(table.concat(parts, "  ")) + 2)
    return clamp(content_w, min_w, max_w)
  end

  local function calc_height(flist, w, parts)
    local item_count = math.max(1, #flist)
    local overhead = 1 + #footer_lines(w, parts) + (filter ~= "" and 1 or 0)
    return math.min(item_count + overhead, math.max(overhead + 1, math.floor(vim.o.lines * 0.6)))
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

  local function sync_preview(w, h)
    if not preview_fn then return end
    local pvw = get_pv_w(w)
    if pvw == 0 then
      if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        vim.api.nvim_win_close(preview_win, true)
      end
      preview_win = nil
      return
    end
    if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
      preview_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[preview_buf].bufhidden = "wipe"
      vim.bo[preview_buf].filetype = "sql"
      vim.b[preview_buf].grip_owned_float = true
    end
    local cfg = {
      relative = "editor", row = math.floor((vim.o.lines - h) / 2),
      col = get_picker_col(w) + w + PREVIEW_GAP, width = pvw, height = h,
    }
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, cfg)
    else
      cfg.style, cfg.border = "minimal", ui.border()
      cfg.title, cfg.title_pos, cfg.focusable, cfg.zindex = " Preview ", "center", false, 54
      local eventignore = vim.o.eventignore
      vim.o.eventignore = "all"
      local ok, result = pcall(vim.api.nvim_open_win, preview_buf, false, cfg)
      vim.o.eventignore = eventignore
      if not ok then error(result) end
      preview_win = result
      vim.wo[preview_win].wrap = true
    end
  end

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
      border      = ui.border(),
      title       = " " .. title .. " ",
      title_pos   = "center",
      zindex      = 55,
    })
    sync_preview(w, h)
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
    local parts = footer_parts()
    local new_w = calc_width(flist, parts)
    local foot = footer_lines(new_w, parts)
    local new_h = calc_height(flist, new_w, parts)
    local item_rows = math.max(1, new_h - #foot - 1 - (filter ~= "" and 1 or 0))
    first_visible = clamp(first_visible, 1, math.max(1, #flist - item_rows + 1))
    if cursor < first_visible then first_visible = cursor end
    if cursor >= first_visible + item_rows then first_visible = cursor - item_rows + 1 end

    local lines = {}

    -- Filter indicator
    if filter ~= "" then
      local filter_line = ui.truncate_display("  / " .. filter, new_w, true)
      table.insert(lines, filter_line)
    end

    -- Items
    if #flist == 0 then
      table.insert(lines, "  (no items)")
    else
      for i = first_visible, math.min(#flist, first_visible + item_rows - 1) do
        local label = ui.truncate_display(tostring(display(flist[i])), math.max(1, new_w - 6), true)
        local prefix = (i == cursor) and "  ▶ " or "    "
        table.insert(lines, prefix .. label)
      end
    end

    -- Separator + footer
    table.insert(lines, "")
    for _, line in ipairs(foot) do lines[#lines + 1] = line end

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
      pcall(vim.api.nvim_win_set_cursor, win, { cursor - first_visible + 1 + item_offset, 0 })
    end

    sync_preview(new_w, new_h)
    update_preview()
  end

  -- ── open initial windows ──

  local initial_flist = filtered_items()
  local initial_parts = footer_parts()
  local init_w = calc_width(initial_flist, initial_parts)
  local init_h = calc_height(initial_flist, init_w, initial_parts)
  win = open_wins(init_w, init_h)

  local resize = vim.api.nvim_create_autocmd("VimResized", {
    group = _ag,
    callback = function() if vim.api.nvim_win_is_valid(win) then render() end end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = _ag, buffer = popup_buf, once = true,
    callback = function() pcall(vim.api.nvim_del_autocmd, resize) end,
  })

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
      if action.when and not action.when(item) then return end
      if action.close_on_select then
        _selected = true
        close()
        if action.fn then vim.schedule(function() action.fn(item) end) end
      else
        if action.fn then action.fn(item) end
        -- action.fn may have changed something display() reads (e.g. a
        -- mask/reveal toggle) without touching `filter` or `items`, which
        -- the cache wouldn't otherwise notice.
        invalidate_cache()
        render()
      end
    end)
  end

  -- Filter (/ or gp)
  local function activate_filter()
    local prompt = filter ~= "" and ("Filter [" .. filter .. "]: ") or "Filter: "
    -- Blank clears the filter, so only Ctrl-C / Esc mean "no change".
    local input = ui.input({ prompt = prompt, default = filter, allow_empty = true })
    if not input then return end
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
