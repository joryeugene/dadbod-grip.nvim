-- sticky_header_spec.lua: TDD tests for the sticky column header (winbar).
--
-- Feature: on a long table the grid's column-name row scrolls off the top and
-- the user loses track of which column the cursor is in. The header row is
-- mirrored into the window's 'winbar', which stays put while the buffer
-- scrolls vertically. Because a winbar does NOT follow the buffer's horizontal
-- scroll, the mirrored line has to be sliced by hand at the window's leftcol.
--
-- ui.slice_display is that slice: display-column arithmetic, not byte
-- arithmetic, so CJK/emoji headers stay aligned with the grid underneath.
-- `from` is a 0-based display-column offset (same units as winsaveview().leftcol).

local ui = require("dadbod-grip.ui")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
end

-- ── ui.slice_display ────────────────────────────────────────────────────────

test("slice_display: ASCII slice from the left edge", function()
  eq(ui.slice_display("║ id    │ name ║", 0, 8), "║ id    ")
end)

test("slice_display: skips `from` display cells (horizontal scroll)", function()
  -- "║ id    │ name ║": display cols 3..8 are "id" + four pad spaces
  eq(ui.slice_display("║ id    │ name ║", 2, 6), "id    ")
end)

test("slice_display: a wide char cut by `from` becomes a space, keeping alignment", function()
  -- 日 occupies display cols 1-2; from=1 starts mid-glyph, so only its right
  -- half is visible. Emitting the whole glyph would shift the rest one cell
  -- left of the grid underneath.
  eq(ui.slice_display("日本語", 1, 3), " 本")
end)

test("slice_display: a wide char cut by `width` becomes a space, filling the slice", function()
  -- 本 spans display cols 3-4 but only col 3 is left in the slice.
  eq(ui.slice_display("日本語", 0, 3), "日 ")
end)

-- ── sticky_header.build ─────────────────────────────────────────────────────
-- Turns the grid's header row into a 'winbar' string: sliced at leftcol,
-- wrapped in the GripHeader group, '%' escaped so winbar does not read it as a
-- statusline item.

local sticky = require("dadbod-grip.view.sticky_header")

test("build: wraps the sliced header row in the GripHeader group", function()
  eq(sticky.build("║ id │ name ║", 0, 12), "%#GripHeader#║ id │ name %*")
end)

test("build: escapes % so winbar does not read a column name as an item", function()
  -- A column literally named "100%" would otherwise render as the statusline
  -- item "% " (or eat the following char).
  eq(sticky.build("║ 100% ║", 0, 8), "%#GripHeader#║ 100%% ║%*")
end)

test("build: highlights the column under the cursor", function()
  -- byte positions as render() records them in hdr_byte_positions: 0-based,
  -- `finish` inclusive. "║ id │ " is 11 bytes (║ and │ are 3 each).
  eq(sticky.build("║ id │ name ║", 0, 13, { start = 11, finish = 14 }),
     "%#GripHeader#║ id │ %#GripHeaderActive#name%#GripHeader# ║%*")
end)

test("build: keeps the active column aligned when scrolled horizontally", function()
  -- leftcol=8 hides "║ id │ n": the slice starts one cell into the active column.
  eq(sticky.build("║ id │ name ║", 8, 5, { start = 11, finish = 14 }),
     "%#GripHeaderActive#ame%#GripHeader# ║%*")
end)

test("build: reserves room for the watch/write badges on the right", function()
  -- The badges already lived in this winbar (view._update_badge). They win the
  -- right edge; the header gets what is left, or it would render under them.
  eq(sticky.build("║ id │ name ║", 0, 13, nil, { { text = "↺ 5s", hl = "GripWatch" } }),
     "%#GripHeader#║ id │ %=%#GripWatch#  ↺ 5s%*")
end)

-- ── integration: a real grid window ─────────────────────────────────────────

local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    pcall(vim.api.nvim_win_close, wins[#wins], true)
  end
end

local function open_grid(row_count)
  local rows = {}
  for i = 1, row_count or 2 do
    rows[i] = { tostring(i), "name" .. i, "u" .. i .. "@example.com" }
  end
  local st = data.new({
    columns = { "id", "name", "email" },
    rows = rows,
    primary_keys = { "id" },
    table_name = "users",
    url = "sqlite:tests/seed_sqlite.db",
  })
  return view.open(st, st.url, "SELECT * FROM users")
end

--- Open a grid tall enough to scroll and put the buffer's own header row off
--- the top of the window, which is when the sticky header takes over.
local function open_scrolled_grid()
  local bufnr = open_grid(200)
  local win = vim.fn.bufwinid(bufnr)
  vim.api.nvim_win_call(win, function() vim.fn.winrestview({ topline = 20, lnum = 25 }) end)
  -- Through the autocmd rather than a direct call, so the wiring is under test
  -- too: scrolling is what has to bring the header in.
  vim.api.nvim_exec_autocmds("WinScrolled", { buffer = bufnr })
  return bufnr, win
end

test("scrolled: the grid window carries the header row in its winbar", function()
  cleanup()
  local _, win = open_scrolled_grid()
  local winbar = vim.wo[win].winbar
  assert(winbar:find("GripHeader", 1, true), "no GripHeader group: " .. vim.inspect(winbar))
  assert(winbar:find("email", 1, true), "column names missing: " .. vim.inspect(winbar))
  cleanup()
end)

test("cursor move: the column under the cursor is marked in the winbar", function()
  cleanup()
  local bufnr, win = open_scrolled_grid()
  local r = view._sessions[bufnr]._render
  local bp = r.hdr_byte_positions["name"]
  vim.api.nvim_win_set_cursor(win, { 25, bp.start })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  local winbar = vim.wo[win].winbar
  assert(winbar:find("%%#GripHeaderActive#name"),
    "active column not marked: " .. vim.inspect(winbar))
  cleanup()
end)

test("option: sticky_header=false leaves the winbar to the badges alone", function()
  cleanup()
  local grip = require("dadbod-grip")
  grip.setup({ sticky_header = false })
  local bufnr = open_grid()
  eq(vim.wo[vim.fn.bufwinid(bufnr)].winbar, "", "winbar with the feature off")
  cleanup()
  grip.setup({ sticky_header = true })
end)

test("option: sticky_header=false still renders the write badge", function()
  cleanup()
  local grip = require("dadbod-grip")
  grip.setup({ sticky_header = false })
  local bufnr = open_grid()
  view._sessions[bufnr].write_mode = true
  view._update_winbar(bufnr)
  local winbar = vim.wo[vim.fn.bufwinid(bufnr)].winbar
  assert(winbar:find("WRITE", 1, true), "badge lost with the header off: " .. vim.inspect(winbar))
  cleanup()
  grip.setup({ sticky_header = true })
end)

test("badges survive the blank winbar while the header is still on screen", function()
  cleanup()
  local bufnr = open_grid()
  view._sessions[bufnr].write_mode = true
  view._update_winbar(bufnr)
  local winbar = vim.wo[vim.fn.bufwinid(bufnr)].winbar
  assert(winbar:find("WRITE", 1, true), "badge dropped before scrolling: " .. vim.inspect(winbar))
  cleanup()
end)

test("leaving the grid clears the winbar it set on the window", function()
  cleanup()
  local bufnr = open_grid()
  local win = vim.fn.bufwinid(bufnr)
  -- 'winbar' is window-local: replacing the buffer in this window would leave
  -- the grid's column names hanging over an unrelated buffer.
  vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
  eq(vim.wo[win].winbar, "", "winbar after the grid left the window")
  cleanup()
end)

test("gutter: the winbar is indented past 'number'/'signcolumn'", function()
  cleanup()
  local bufnr, win = open_scrolled_grid()
  -- A winbar spans the whole window, the buffer text starts after the gutter.
  -- Without a matching indent the mirrored header sits left of its own columns.
  vim.wo[win].number = true
  vim.wo[win].numberwidth = 6
  view._update_winbar(bufnr)
  local textoff = vim.fn.getwininfo(win)[1].textoff
  assert(textoff > 0, "test setup: expected a gutter, got textoff " .. textoff)
  local plain = vim.wo[win].winbar:gsub("%%#%w*#", ""):gsub("%%%*", ""):gsub("%%=", "")
  eq(plain:sub(1, textoff + 3), string.rep(" ", textoff) .. "║",
     "header must start one gutter in")
  cleanup()
end)

test("no duplicate: the winbar stays blank while the real header is on screen", function()
  cleanup()
  local bufnr = open_grid()
  local win = vim.fn.bufwinid(bufnr)
  view._update_winbar(bufnr)
  local winbar = vim.wo[win].winbar
  assert(not winbar:find("createdAt", 1, true) and not winbar:find("email", 1, true),
    "header shown twice while the buffer's own header is visible: " .. vim.inspect(winbar))
  -- Blank, not absent: an empty winbar drops the line and the grid jumps by one
  -- row every time scrolling crosses the threshold.
  assert(winbar ~= "", "winbar must stay reserved to keep the layout stable")
  cleanup()
end)

print("\nsticky_header_spec: " .. pass .. " passed, " .. fail .. " failed")
if fail > 0 then os.exit(1) end
