-- grid_reuse_spec.lua: integration test for grid window reuse
-- RED/GREEN: verifies view.open() with reuse_win does not stack grid windows.
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")

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

-- Helper: create a minimal grip state
local function make_state(table_name)
  return data.new({
    columns = { "id", "name" },
    rows = { { "1", "alice" }, { "2", "bob" } },
    primary_keys = { "id" },
    table_name = table_name,
    url = "sqlite:test.db",
    sql = "SELECT * FROM " .. (table_name or "test"),
  })
end

-- Helper: count grip grid windows (not query pad, not schema)
local function count_grid_wins()
  local n = 0
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wbuf = vim.api.nvim_win_get_buf(winid)
    if view._sessions[wbuf] then
      n = n + 1
    end
  end
  return n
end

-- Helper: find first grip grid window
local function find_grid_win()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wbuf = vim.api.nvim_win_get_buf(winid)
    if view._sessions[wbuf] then
      return winid
    end
  end
  return nil
end

-- Clean up between tests
local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  -- Close all windows except one
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(0)[#vim.api.nvim_tabpage_list_wins(0)], true)
  end
end

-- ── Tests ──

test("view.open: first open creates one grid window", function()
  cleanup()
  local state = make_state("users")
  view.open(state, "sqlite:test.db", "SELECT * FROM users", {})
  eq(count_grid_wins(), 1, "grid window count after first open")
  cleanup()
end)

test("view.open: reuse_win replaces buffer, still one grid window", function()
  cleanup()
  local state1 = make_state("users")
  local buf1 = view.open(state1, "sqlite:test.db", "SELECT * FROM users", {})
  eq(count_grid_wins(), 1, "one grid after first open")

  local grid_win = find_grid_win()
  assert(grid_win, "grid window exists")

  local state2 = make_state("orders")
  local buf2 = view.open(state2, "sqlite:test.db", "SELECT * FROM orders", { reuse_win = grid_win })
  eq(count_grid_wins(), 1, "still one grid after reuse_win open")
  assert(buf1 ~= buf2, "different buffers created")
  -- Old session should be gone
  eq(view._sessions[buf1], nil, "old session cleaned up")
  assert(view._sessions[buf2] ~= nil, "new session exists")
  cleanup()
end)

test("view.open: three consecutive opens with reuse = still one window", function()
  cleanup()
  local state1 = make_state("t1")
  view.open(state1, "sqlite:test.db", "SELECT 1", {})
  local win = find_grid_win()

  local state2 = make_state("t2")
  view.open(state2, "sqlite:test.db", "SELECT 2", { reuse_win = win })
  eq(count_grid_wins(), 1, "one grid after second open")

  win = find_grid_win()
  local state3 = make_state("t3")
  view.open(state3, "sqlite:test.db", "SELECT 3", { reuse_win = win })
  eq(count_grid_wins(), 1, "one grid after third open")

  -- Only one session should exist
  local session_count = 0
  for _ in pairs(view._sessions) do session_count = session_count + 1 end
  eq(session_count, 1, "exactly one session after three opens")
  cleanup()
end)

-- ── query_pad scan simulation ──
-- Reproduces the exact scan logic from query_pad.run_sql() to find reuse_win

--- Mimics query_pad.run_sql() grid-window scanner.
--- Returns (reuse_win, closed_count) just like the real code path.
local function scan_for_grid_win()
  local reuse_win = nil
  local closed = 0
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
        pcall(vim.api.nvim_win_close, winid, true)
        closed = closed + 1
      end
    end
  end
  return reuse_win, closed
end

test("query_pad scan: finds grid window after view.open", function()
  cleanup()
  local state = make_state("users")
  view.open(state, "sqlite:test.db", "SELECT * FROM users", {})

  local reuse_win = scan_for_grid_win()
  assert(reuse_win ~= nil, "scan found the grid window")
  cleanup()
end)

test("query_pad scan + view.open: two consecutive runs = one grid window", function()
  cleanup()
  -- First "C-CR": open grid with no reuse
  local state1 = make_state("users")
  view.open(state1, "sqlite:test.db", "SELECT * FROM users", {})
  eq(count_grid_wins(), 1, "one grid after first run")

  -- Second "C-CR": scan for reuse window, then open with it
  local reuse_win = scan_for_grid_win()
  assert(reuse_win ~= nil, "scan found grid window for reuse")

  local state2 = make_state("orders")
  view.open(state2, "sqlite:test.db", "SELECT * FROM orders", { reuse_win = reuse_win })
  eq(count_grid_wins(), 1, "still one grid after second run")
  cleanup()
end)

test("query_pad scan + view.open: three consecutive runs = one grid window", function()
  cleanup()
  -- Run 1
  local state1 = make_state("t1")
  view.open(state1, "sqlite:test.db", "SELECT 1", {})

  -- Run 2: scan + reuse
  local rw2 = scan_for_grid_win()
  assert(rw2, "scan found grid for run 2")
  local state2 = make_state("t2")
  view.open(state2, "sqlite:test.db", "SELECT 2", { reuse_win = rw2 })
  eq(count_grid_wins(), 1, "one grid after run 2")

  -- Run 3: scan + reuse
  local rw3 = scan_for_grid_win()
  assert(rw3, "scan found grid for run 3")
  local state3 = make_state("t3")
  view.open(state3, "sqlite:test.db", "SELECT 3", { reuse_win = rw3 })
  eq(count_grid_wins(), 1, "one grid after run 3")

  local session_count = 0
  for _ in pairs(view._sessions) do session_count = session_count + 1 end
  eq(session_count, 1, "exactly one session after three runs")
  cleanup()
end)

test("query_pad scan: buffer name fallback detects orphaned grip buffers", function()
  cleanup()
  -- Create a buffer with a grip:// name but NO session (simulates orphaned buffer)
  local orphan = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = orphan })
  pcall(vim.api.nvim_buf_set_name, orphan, "grip://orphan_table")
  vim.cmd("botright split")
  local orphan_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(orphan_win, orphan)

  -- Scan should detect it via name fallback
  local reuse_win = scan_for_grid_win()
  assert(reuse_win ~= nil, "scan found orphan grid via name fallback")
  eq(reuse_win, orphan_win, "reuse_win is the orphan window")

  -- Opening with reuse should replace it cleanly
  local state = make_state("fresh")
  view.open(state, "sqlite:test.db", "SELECT 1", { reuse_win = reuse_win })
  eq(count_grid_wins(), 1, "one grid after replacing orphan")
  cleanup()
end)

-- ── realistic layout: query pad + grid ──
-- Simulates the actual window layout users see when pressing C-CR

test("realistic: query pad + grid, second open reuses grid", function()
  cleanup()
  -- Set up query pad window (top)
  local pad_buf = vim.api.nvim_create_buf(true, false)
  vim.bo[pad_buf].buftype = "acwrite"
  vim.bo[pad_buf].filetype = "sql"
  pcall(vim.api.nvim_buf_set_name, pad_buf, "grip://query")
  local pad_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pad_win, pad_buf)

  -- First C-CR: open grid (creates split below query pad)
  local state1 = make_state("users")
  view.open(state1, "sqlite:test.db", "SELECT * FROM users", {})
  eq(count_grid_wins(), 1, "one grid after first C-CR")

  -- Switch focus back to query pad (like user would)
  vim.api.nvim_set_current_win(pad_win)

  -- Second C-CR: scan for grid, reuse it
  local rw = scan_for_grid_win()
  assert(rw ~= nil, "scan found grid from query pad context")

  local state2 = make_state("orders")
  view.open(state2, "sqlite:test.db", "SELECT * FROM orders", { reuse_win = rw })
  eq(count_grid_wins(), 1, "still one grid after second C-CR")

  -- Total windows: query pad + grid = 2
  local total_wins = #vim.api.nvim_tabpage_list_wins(0)
  eq(total_wins, 2, "exactly two windows (pad + grid)")

  -- Clean up the query pad
  pcall(vim.api.nvim_buf_delete, pad_buf, { force = true })
  cleanup()
end)

test("realistic: query pad + grid, three runs from pad context", function()
  cleanup()
  -- Query pad window
  local pad_buf = vim.api.nvim_create_buf(true, false)
  vim.bo[pad_buf].buftype = "acwrite"
  vim.bo[pad_buf].filetype = "sql"
  pcall(vim.api.nvim_buf_set_name, pad_buf, "grip://query")
  local pad_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pad_win, pad_buf)

  -- Run 1: no reuse (first grid)
  local state1 = make_state("t1")
  view.open(state1, "sqlite:test.db", "SELECT 1", {})

  -- Run 2: back to pad, scan, reuse
  vim.api.nvim_set_current_win(pad_win)
  local rw2 = scan_for_grid_win()
  assert(rw2, "scan found grid for run 2")
  local state2 = make_state("t2")
  view.open(state2, "sqlite:test.db", "SELECT 2", { reuse_win = rw2 })
  eq(count_grid_wins(), 1, "one grid after run 2")

  -- Run 3: back to pad, scan, reuse
  vim.api.nvim_set_current_win(pad_win)
  local rw3 = scan_for_grid_win()
  assert(rw3, "scan found grid for run 3")
  local state3 = make_state("t3")
  view.open(state3, "sqlite:test.db", "SELECT 3", { reuse_win = rw3 })
  eq(count_grid_wins(), 1, "one grid after run 3")

  eq(#vim.api.nvim_tabpage_list_wins(0), 2, "exactly two windows after three runs")

  pcall(vim.api.nvim_buf_delete, pad_buf, { force = true })
  cleanup()
end)

-- ── edge case: grid window closed between runs ──

test("edge case: grid closed manually, next run creates new grid (no stack)", function()
  cleanup()
  -- Query pad
  local pad_buf = vim.api.nvim_create_buf(true, false)
  vim.bo[pad_buf].buftype = "acwrite"
  pcall(vim.api.nvim_buf_set_name, pad_buf, "grip://query")
  local pad_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pad_win, pad_buf)

  -- First run: create grid
  local state1 = make_state("users")
  view.open(state1, "sqlite:test.db", "SELECT 1", {})
  eq(count_grid_wins(), 1, "one grid after first run")

  -- Close the grid window manually
  local gw = find_grid_win()
  pcall(vim.api.nvim_win_close, gw, true)
  eq(count_grid_wins(), 0, "no grid after manual close")

  -- Focus back to pad
  vim.api.nvim_set_current_win(pad_win)

  -- Second run: no grid found, creates new one
  local rw = scan_for_grid_win()
  -- rw may be nil (grid was closed) or may find orphan via name fallback
  local state2 = make_state("orders")
  view.open(state2, "sqlite:test.db", "SELECT 2", rw and { reuse_win = rw } or {})
  eq(count_grid_wins(), 1, "one grid after second run (no stacking)")

  pcall(vim.api.nvim_buf_delete, pad_buf, { force = true })
  cleanup()
end)

-- ── THE ACTUAL BUG: no reuse_win passed but grid exists ──
-- This is the scenario that causes stacking: a caller (gT picker, :Grip command,
-- or any path that forgets reuse_win) calls view.open() without reuse_win while
-- a grid window is already visible. view.open() should auto-detect and reuse it.

test("defensive reuse: view.open without reuse_win still reuses existing grid", function()
  cleanup()
  -- First open: creates grid window
  local state1 = make_state("users")
  local buf1 = view.open(state1, "sqlite:test.db", "SELECT * FROM users", {})
  eq(count_grid_wins(), 1, "one grid after first open")

  -- Second open: NO reuse_win passed (simulates gT picker, :Grip, etc.)
  local state2 = make_state("orders")
  local buf2 = view.open(state2, "sqlite:test.db", "SELECT * FROM orders", {})
  eq(count_grid_wins(), 1, "still one grid after second open WITHOUT reuse_win")
  assert(buf1 ~= buf2, "different buffers")
  eq(view._sessions[buf1], nil, "old session cleaned up")
  assert(view._sessions[buf2] ~= nil, "new session exists")
  cleanup()
end)

test("defensive reuse: three opens without reuse_win = still one grid", function()
  cleanup()
  view.open(make_state("t1"), "sqlite:test.db", "SELECT 1", {})
  eq(count_grid_wins(), 1, "one grid after open 1")

  view.open(make_state("t2"), "sqlite:test.db", "SELECT 2", {})
  eq(count_grid_wins(), 1, "one grid after open 2 (no reuse_win)")

  view.open(make_state("t3"), "sqlite:test.db", "SELECT 3", {})
  eq(count_grid_wins(), 1, "one grid after open 3 (no reuse_win)")

  local session_count = 0
  for _ in pairs(view._sessions) do session_count = session_count + 1 end
  eq(session_count, 1, "exactly one session")
  cleanup()
end)

test("defensive reuse: from query pad context, no reuse_win = still one grid", function()
  cleanup()
  -- Query pad
  local pad_buf = vim.api.nvim_create_buf(true, false)
  vim.bo[pad_buf].buftype = "acwrite"
  pcall(vim.api.nvim_buf_set_name, pad_buf, "grip://query")
  local pad_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(pad_win, pad_buf)

  -- First C-CR creates grid
  view.open(make_state("users"), "sqlite:test.db", "SELECT 1", {})
  eq(count_grid_wins(), 1, "one grid after first run")

  -- Back to pad, second C-CR WITHOUT reuse_win
  vim.api.nvim_set_current_win(pad_win)
  view.open(make_state("orders"), "sqlite:test.db", "SELECT 2", {})
  eq(count_grid_wins(), 1, "still one grid after second run WITHOUT reuse_win")
  eq(#vim.api.nvim_tabpage_list_wins(0), 2, "two windows total (pad + grid)")

  pcall(vim.api.nvim_buf_delete, pad_buf, { force = true })
  cleanup()
end)

test("force_split: bypasses defensive reuse, creates new window", function()
  cleanup()
  view.open(make_state("t1"), "sqlite:test.db", "SELECT 1", {})
  eq(count_grid_wins(), 1, "one grid initially")

  -- force_split should create a second grid window
  view.open(make_state("t2"), "sqlite:test.db", "SELECT 2", { force_split = true })
  eq(count_grid_wins(), 2, "two grids after force_split")
  cleanup()
end)

print(string.format("\ngrid_reuse_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
