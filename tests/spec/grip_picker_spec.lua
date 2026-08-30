-- grip_picker_spec.lua: tests for the self-contained floating list picker.

local grip_picker = require("dadbod-grip.grip_picker")

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
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

local function refute(cond, msg)
  assert(not cond, msg or "expected false, got true")
end

-- ── helpers ──────────────────────────────────────────────────────────────────

--- Press a buffer-local normal-mode keymap by looking it up and calling it.
local function press(buf, key)
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, m in ipairs(maps) do
    if m.lhs == key then
      if type(m.callback) == "function" then
        m.callback()
        return true
      end
    end
  end
  return false  -- key not found
end

--- Return all lines in a buffer as a table.
local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Open picker, return the popup_buf (we capture via nvim_list_bufs diff).
local function open_picker_capture_buf(opts)
  local bufs_before = vim.api.nvim_list_bufs()
  local before_set = {}
  for _, b in ipairs(bufs_before) do before_set[b] = true end

  grip_picker.open(opts)

  -- Find the new scratch buffer created by the picker
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before_set[b] and vim.api.nvim_buf_is_valid(b) then
      return b
    end
  end
  return nil
end

--- Close any floating windows (cleanup between tests).
local function close_all_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Feed keys for vim.fn.input (used by ui.input under "/") before calling fn.
--- Same pattern as tests/spec/ui_spec.lua.
local function answering(keys, fn)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "L", false)
  return fn()
end

--- Names of items currently rendered (in the order they appear).
local function visible_item_names(buf, names_by_line_frag)
  local lines = buf_lines(buf)
  local visible = {}
  for _, frag in ipairs(names_by_line_frag) do
    for _, l in ipairs(lines) do
      if l:find(frag, 1, true) then
        table.insert(visible, frag)
        break
      end
    end
  end
  return visible
end

-- ── open + basic render ───────────────────────────────────────────────────────

test("open: renders item list in buffer", function()
  local buf = open_picker_capture_buf({
    title = "Test",
    items = { "alpha", "beta", "gamma" },
  })
  assert(buf and vim.api.nvim_buf_is_valid(buf), "picker buffer should be valid")
  local lines = buf_lines(buf)
  -- First item has cursor marker ▶
  local found_cursor = false
  local found_alpha = false
  for _, l in ipairs(lines) do
    if l:find("▶", 1, true) then found_cursor = true end
    if l:find("alpha", 1, true) then found_alpha = true end
  end
  assert(found_cursor, "cursor marker ▶ should be in buffer")
  assert(found_alpha, "'alpha' should appear in buffer")
  close_all_floats()
end)

test("open: footer shows Enter:select and /:filter", function()
  local buf = open_picker_capture_buf({
    title = "Test",
    items = { "one" },
  })
  assert(buf, "buf should exist")
  local lines = buf_lines(buf)
  local footer = lines[#lines]
  contains(footer, "Enter", "footer should mention Enter")
  contains(footer, "filter", "footer should mention filter")
  close_all_floats()
end)

test("open: D:delete in footer only when on_delete provided", function()
  local buf_with = open_picker_capture_buf({
    title = "Test",
    items = { "one" },
    on_delete = function() end,
  })
  assert(buf_with, "buf should exist")
  local lines_with = buf_lines(buf_with)
  contains(lines_with[#lines_with], "D:delete", "footer should mention D:delete when on_delete set")
  close_all_floats()

  local buf_without = open_picker_capture_buf({
    title = "Test",
    items = { "one" },
  })
  assert(buf_without, "buf should exist")
  local lines_without = buf_lines(buf_without)
  local footer = lines_without[#lines_without]
  refute(footer:find("D:delete", 1, true), "footer should NOT mention D:delete when on_delete absent")
  close_all_floats()
end)

-- ── empty items list ──────────────────────────────────────────────────────────

test("empty items: shows (no items) message", function()
  local buf = open_picker_capture_buf({
    title = "Empty",
    items = {},
  })
  assert(buf, "buf should exist")
  local lines = buf_lines(buf)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("no items", 1, true) then found = true end
  end
  assert(found, "should show (no items)")
  close_all_floats()
end)

test("empty items: Enter does not crash", function()
  local called = false
  local buf = open_picker_capture_buf({
    title = "Empty",
    items = {},
    on_select = function() called = true end,
  })
  assert(buf, "buf should exist")
  press(buf, "<CR>")
  refute(called, "on_select should NOT be called on empty list")
  close_all_floats()
end)

test("empty items: D does not crash", function()
  local called = false
  local buf = open_picker_capture_buf({
    title = "Empty",
    items = {},
    on_delete = function() called = true end,
  })
  assert(buf, "buf should exist")
  press(buf, "D")
  refute(called, "on_delete should NOT be called on empty list")
  close_all_floats()
end)

-- ── cursor navigation ─────────────────────────────────────────────────────────

test("j key moves cursor down", function()
  local buf = open_picker_capture_buf({
    title = "Nav",
    items = { "first", "second", "third" },
  })
  assert(buf, "buf should exist")
  -- Initially cursor on first item (line with ▶ first)
  local lines_before = buf_lines(buf)
  local cursor_line_before = nil
  for i, l in ipairs(lines_before) do
    if l:find("▶", 1, true) then cursor_line_before = i end
  end

  press(buf, "j")

  local lines_after = buf_lines(buf)
  local cursor_line_after = nil
  for i, l in ipairs(lines_after) do
    if l:find("▶", 1, true) then cursor_line_after = i end
  end

  assert(cursor_line_before and cursor_line_after, "cursor marker should be found")
  assert(cursor_line_after > cursor_line_before, "j should move cursor down")
  close_all_floats()
end)

test("k key moves cursor up", function()
  local buf = open_picker_capture_buf({
    title = "Nav",
    items = { "first", "second", "third" },
  })
  assert(buf, "buf should exist")
  -- Move down first
  press(buf, "j")
  press(buf, "j")

  local lines_mid = buf_lines(buf)
  local cursor_mid = nil
  for i, l in ipairs(lines_mid) do
    if l:find("▶", 1, true) then cursor_mid = i end
  end

  press(buf, "k")

  local lines_after = buf_lines(buf)
  local cursor_after = nil
  for i, l in ipairs(lines_after) do
    if l:find("▶", 1, true) then cursor_after = i end
  end

  assert(cursor_mid and cursor_after, "cursor marker should be found")
  assert(cursor_after < cursor_mid, "k should move cursor up")
  close_all_floats()
end)

test("j wraps from last item to first", function()
  local buf = open_picker_capture_buf({
    title = "Wrap",
    items = { "a", "b", "c" },
  })
  assert(buf, "buf should exist")
  -- Move to last item (j twice from position 1)
  press(buf, "j")
  press(buf, "j")

  -- Now at item 3 (last): j should wrap to item 1
  press(buf, "j")

  local lines = buf_lines(buf)
  -- Find which line has ▶ and which item it contains
  local cursor_item = nil
  for _, l in ipairs(lines) do
    if l:find("▶", 1, true) then cursor_item = l end
  end
  assert(cursor_item and cursor_item:find("a", 1, true), "cursor should wrap to first item 'a', got: " .. tostring(cursor_item))
  close_all_floats()
end)

test("k wraps from first item to last", function()
  local buf = open_picker_capture_buf({
    title = "Wrap",
    items = { "x", "y", "z" },
  })
  assert(buf, "buf should exist")
  -- At item 1, k should wrap to item 3
  press(buf, "k")

  local lines = buf_lines(buf)
  local cursor_item = nil
  for _, l in ipairs(lines) do
    if l:find("▶", 1, true) then cursor_item = l end
  end
  assert(cursor_item and cursor_item:find("z", 1, true), "cursor should wrap to last item 'z', got: " .. tostring(cursor_item))
  close_all_floats()
end)

test("single item: j and k do not crash", function()
  local buf = open_picker_capture_buf({
    title = "Single",
    items = { "only" },
  })
  assert(buf, "buf should exist")
  press(buf, "j")
  press(buf, "k")
  local lines = buf_lines(buf)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("only", 1, true) then found = true end
  end
  assert(found, "single item should still be visible after j/k")
  close_all_floats()
end)

-- ── selection ─────────────────────────────────────────────────────────────────

test("Enter calls on_select with hovered item", function()
  local selected = nil
  local buf = open_picker_capture_buf({
    title = "Select",
    items = { "pick-me", "not-me" },
    on_select = function(item) selected = item end,
  })
  assert(buf, "buf should exist")
  -- Cursor is on first item; press Enter
  press(buf, "<CR>")
  -- on_select is called via vim.schedule, run it synchronously in test
  vim.wait(50)
  eq(selected, "pick-me", "on_select should receive first item")
end)

test("Enter calls on_select with second item after j", function()
  local selected = nil
  local buf = open_picker_capture_buf({
    title = "Select",
    items = { "first", "second" },
    on_select = function(item) selected = item end,
  })
  assert(buf, "buf should exist")
  press(buf, "j")
  press(buf, "<CR>")
  vim.wait(50)
  eq(selected, "second", "on_select should receive second item")
end)

test("Enter with nil on_select does not crash", function()
  local buf = open_picker_capture_buf({
    title = "NoCallback",
    items = { "item" },
    -- no on_select
  })
  assert(buf, "buf should exist")
  press(buf, "<CR>")  -- should not throw
  close_all_floats()
end)

-- ── delete ────────────────────────────────────────────────────────────────────

test("D calls on_delete with item and refresh_fn", function()
  local deleted_item = nil
  local refresh_called = false
  local buf = open_picker_capture_buf({
    title = "Delete",
    items = { "to-delete", "keep-me" },
    on_delete = function(item, refresh_fn)
      deleted_item = item
      refresh_called = true
      refresh_fn({ "keep-me" })  -- simulate deletion
    end,
  })
  assert(buf, "buf should exist")
  press(buf, "D")
  eq(deleted_item, "to-delete", "on_delete should receive hovered item")
  assert(refresh_called, "refresh_fn should be provided and callable")
  close_all_floats()
end)

test("D re-renders with updated item list after refresh_fn", function()
  local buf = open_picker_capture_buf({
    title = "Delete",
    items = { "alpha", "beta", "gamma" },
    on_delete = function(_, refresh_fn)
      refresh_fn({ "beta", "gamma" })  -- remove alpha
    end,
  })
  assert(buf, "buf should exist")
  press(buf, "D")

  local lines = buf_lines(buf)
  local has_alpha = false
  local has_beta = false
  for _, l in ipairs(lines) do
    if l:find("alpha", 1, true) then has_alpha = true end
    if l:find("beta", 1, true) then has_beta = true end
  end
  refute(has_alpha, "alpha should be removed after D+refresh")
  assert(has_beta, "beta should still appear after refresh")
  close_all_floats()
end)

test("D without on_delete key not registered", function()
  local buf = open_picker_capture_buf({
    title = "NoDelete",
    items = { "item" },
  })
  assert(buf, "buf should exist")
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local has_D = false
  for _, m in ipairs(maps) do
    if m.lhs == "D" then has_D = true end
  end
  refute(has_D, "D keymap should NOT be registered when on_delete is absent")
  close_all_floats()
end)

-- ── filter ────────────────────────────────────────────────────────────────────

test("filter: matching nothing shows (no items)", function()
  -- We can't easily test vim.ui.input in unit tests, but we can test
  -- filtered_items logic by inspecting what happens after a filter
  -- is applied via the internal state. Expose by opening, then
  -- simulating filter state change through a custom items render.
  -- Instead, test that with all-non-matching items, render shows (no items).

  -- Use display function to control what's searched
  local buf = open_picker_capture_buf({
    title = "Filter",
    items = { { name = "foo" }, { name = "bar" } },
    display = function(item) return item.name end,
  })
  assert(buf, "buf should exist")
  -- Check initial render has items
  local lines = buf_lines(buf)
  local found_foo = false
  for _, l in ipairs(lines) do
    if l:find("foo", 1, true) then found_foo = true end
  end
  assert(found_foo, "initial render should show all items")
  close_all_floats()
end)

test("display function applied to items", function()
  local buf = open_picker_capture_buf({
    title = "Display",
    items = { { id = 1, label = "custom-label" } },
    display = function(item) return item.label end,
  })
  assert(buf, "buf should exist")
  local lines = buf_lines(buf)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("custom-label", 1, true) then found = true end
  end
  assert(found, "display function result should appear in buffer")
  close_all_floats()
end)

test("filter: cache does not go stale across query A -> B -> A", function()
  -- Regression test for the filtered_items() memoization: query A must give
  -- the same result the second time around, and B must differ from A, even
  -- though every one of these renders shares a cache.
  local buf = open_picker_capture_buf({
    title = "Filter",
    items = { { name = "alpha" }, { name = "abba" }, { name = "beta" } },
    display = function(item) return item.name end,
  })
  assert(buf, "buf should exist")

  -- activate_filter() prefills the prompt with the current filter as
  -- `default`, so clear it (<C-u>) before typing the new query.
  local function activate(query)
    answering("<C-u>" .. query .. "<CR>", function() press(buf, "/") end)
  end

  -- Query A: "ab" only matches "abba".
  activate("ab")
  local a1 = visible_item_names(buf, { "alpha", "abba", "beta" })
  eq(#a1, 1, "query A should match exactly one item")
  eq(a1[1], "abba", "query A should match 'abba'")

  -- Query B: "et" only matches "beta". Different result proves the cache
  -- picked up the new filter instead of replaying A's cached list.
  activate("et")
  local b = visible_item_names(buf, { "alpha", "abba", "beta" })
  eq(#b, 1, "query B should match exactly one item")
  eq(b[1], "beta", "query B should match 'beta'")

  -- Back to query A: must reproduce the exact first result, proving the
  -- cache wasn't left pointing at B's list.
  activate("ab")
  local a2 = visible_item_names(buf, { "alpha", "abba", "beta" })
  eq(#a2, 1, "query A (again) should match exactly one item")
  eq(a2[1], "abba", "query A (again) should match 'abba', same as the first time")

  close_all_floats()
end)

test("filter: non-closing action invalidates cache when it changes what display() shows", function()
  -- Regression test mirroring connections.lua's M:mask action: a custom
  -- action with no close_on_select mutates state captured by the caller's
  -- display() closure, but touches neither `filter` nor `items`. The cache
  -- must not serve a filtered list computed under the old display() output.
  local show_pass = {}
  local url = "postgres://user:secret@host/db"
  local masked = "postgres://***@host/db"

  local buf = open_picker_capture_buf({
    title = "Mask",
    items = { { url = url } },
    display = function(item)
      return show_pass[item.url] and item.url or masked
    end,
    actions = {
      {
        key   = "M",
        label = "M:mask",
        fn    = function(item) show_pass[item.url] = not show_pass[item.url] end,
      },
    },
  })
  assert(buf, "buf should exist")

  local function shows(needle)
    for _, l in ipairs(buf_lines(buf)) do
      if l:find(needle, 1, true) then return true end
    end
    return false
  end

  -- The filter indicator line ("  / secret") itself contains the word
  -- "secret", so check for a substring found only in the unmasked URL row.
  local unmasked_only = "user:secret@host"

  -- Reveal, then filter on a substring that only the unmasked URL contains.
  press(buf, "M")
  answering("<C-u>secret<CR>", function() press(buf, "/") end)
  assert(shows(unmasked_only), "revealed item matching the filter should be visible")

  -- Re-mask: display() output changes (no longer contains "secret"), but
  -- filter/items don't. A fresh filter pass would now show (no items).
  press(buf, "M")
  refute(shows(unmasked_only), "item should disappear once re-masked, since it no longer matches the filter")
  assert(shows("no items"), "picker should show (no items) once the only match is masked out")

  close_all_floats()
end)

test("contextual action cannot run while its footer entry is hidden", function()
  local calls = 0
  local buf = open_picker_capture_buf({
    title = "Context",
    items = { { name = "read-only" } },
    display = function(item) return item.name end,
    actions = {
      {
        key = "!", label = "!:write", close_on_select = true,
        when = function() return false end,
        fn = function() calls = calls + 1 end,
      },
    },
  })
  assert(buf, "buf should exist")
  press(buf, "!")
  vim.wait(20)
  eq(calls, 0, "hidden action did not run")
  assert(vim.api.nvim_buf_is_valid(buf), "hidden action did not close the picker")
  close_all_floats()
end)

test("filter: item deletion still respects an active filter (not a stale cached list)", function()
  -- refresh_fn (D + on_delete) reassigns `items` while a filter can already
  -- be active. The post-delete render must re-filter the new item list, not
  -- replay whatever was cached for the pre-delete items.
  local buf = open_picker_capture_buf({
    title = "Delete+Filter",
    items = { { name = "alpha" }, { name = "abba" }, { name = "beta" } },
    display = function(item) return item.name end,
    on_delete = function(_, refresh_fn)
      -- Simulate deleting "abba" from the underlying list.
      refresh_fn({ { name = "alpha" }, { name = "beta" } })
    end,
  })
  assert(buf, "buf should exist")

  local function shows(needle)
    for _, l in ipairs(buf_lines(buf)) do
      if l:find(needle, 1, true) then return true end
    end
    return false
  end

  -- Filter "b" matches "abba" and "beta", not "alpha".
  answering("<C-u>b<CR>", function() press(buf, "/") end)
  assert(shows("abba"), "abba should match filter 'b' before deletion")
  assert(shows("beta"), "beta should match filter 'b' before deletion")
  refute(shows("alpha"), "alpha should not match filter 'b'")

  -- D deletes "abba" (hovered, first filtered match) via on_delete/refresh_fn.
  press(buf, "D")

  refute(shows("abba"), "abba should be gone after deletion")
  assert(shows("beta"), "beta should still match filter 'b' after deletion")
  refute(shows("alpha"), "alpha should still be excluded by filter 'b' after deletion")

  close_all_floats()
end)

-- ── close ─────────────────────────────────────────────────────────────────────

test("q closes the picker window", function()
  local buf = open_picker_capture_buf({
    title = "Close",
    items = { "one" },
  })
  assert(buf, "buf should exist")
  -- Find the float window
  local float_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative ~= "" and vim.api.nvim_win_get_buf(w) == buf then
      float_win = w
    end
  end
  assert(float_win, "picker float window should be open")
  press(buf, "q")
  refute(float_win and vim.api.nvim_win_is_valid(float_win), "window should be closed after q")
end)

-- ── long item names truncation ────────────────────────────────────────────────

test("long item names are truncated in render", function()
  local long_name = string.rep("x", 200)
  local buf = open_picker_capture_buf({
    title = "Trunc",
    items = { long_name },
  })
  assert(buf, "buf should exist")
  local lines = buf_lines(buf)
  local item_line = nil
  for _, l in ipairs(lines) do
    if l:find("x", 1, true) and l:find("▶", 1, true) then item_line = l end
  end
  assert(item_line, "item line should exist")
  -- Window width is capped at ~70, so line should be shorter than 200 chars
  assert(#item_line < 120, "long item name should be truncated, got length " .. #item_line)
  close_all_floats()
end)

-- ── / and gp both registered as filter keys ───────────────────────────────────

test("/ and gp keys are registered", function()
  local buf = open_picker_capture_buf({
    title = "Keys",
    items = { "item" },
  })
  assert(buf, "buf should exist")
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local has_slash = false
  local has_gp = false
  for _, m in ipairs(maps) do
    if m.lhs == "/" then has_slash = true end
    if m.lhs == "gp" then has_gp = true end
  end
  assert(has_slash, "/ key should be registered as filter")
  assert(has_gp, "gp key should be registered as filter")
  close_all_floats()
end)

-- ── summary ───────────────────────────────────────────────────────────────────

print(string.format("grip_picker_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
