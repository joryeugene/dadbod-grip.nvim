-- query_pad_spec.lua: unit tests for query_pad.sync_query
-- Tests the replace-vs-append logic without any DB I/O.
dofile("tests/minimal_init.lua")

local qp = require("dadbod-grip.query_pad")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg, tostring(b), tostring(a)))
  end
end

-- Helper: create a scratch buffer, wire it as the pad, return bufnr.
-- We expose _set_pad_bufnr for testing only.
local function make_pad()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = true
  qp._set_pad_bufnr(bufnr)
  return bufnr
end

local function get_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- ── sync_query: populate empty pad ──────────────────────────────────────────

do
  local b = make_pad()
  set_lines(b, {})
  qp.sync_query("SELECT * FROM users")
  local lines = get_lines(b)
  eq(lines[1], "SELECT * FROM users", "empty pad: line 1 is the SQL")
  eq(#lines, 1, "empty pad: exactly 1 line")
end

-- ── sync_query: replace hint-only pad ───────────────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run  gA:ai  go:tables", "" })
  qp.sync_query("SELECT * FROM orders")
  local lines = get_lines(b)
  eq(lines[1], "SELECT * FROM orders", "hint pad: line 1 is the SQL")
  eq(#lines, 1, "hint pad: exactly 1 line after replace")
end

-- ── sync_query: append to pad with existing content ─────────────────────────

do
  local b = make_pad()
  set_lines(b, { "SELECT id FROM users" })
  qp.sync_query("SELECT * FROM orders")
  local lines = get_lines(b)
  eq(lines[1], "SELECT id FROM users", "append: original query preserved on line 1")
  -- blank separator + appended SQL
  eq(lines[2], "", "append: blank separator line 2")
  eq(lines[3], "SELECT * FROM orders", "append: new SQL on line 3")
end

-- ── sync_query: consecutive auto-syncs replace the last one ───────────────────
-- Plain table-hopping (no edits) must NOT pile up SELECTs. The first block here
-- is user content (set directly), so it's preserved; the auto-synced tail is
-- replaced each jump.

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })     -- user content
  qp.sync_query("SELECT 2")         -- differs from tail → append
  qp.sync_query("SELECT 3")         -- tail is our own "SELECT 2" → replace it
  local lines = get_lines(b)
  eq(lines[1], "SELECT 1", "auto-sync: user's first block preserved")
  eq(lines[2], "", "auto-sync: blank separator kept")
  eq(lines[3], "SELECT 3", "auto-sync: tail replaced, not accumulated")
  eq(#lines, 3, "auto-sync: no pile-up (3 lines, not 5)")
end

-- ── sync_query: pure navigation never accumulates ─────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run  gA:ai", "" })  -- fresh hint-only pad
  qp.sync_query('SELECT * FROM "A"')
  qp.sync_query('SELECT * FROM "B"')
  qp.sync_query('SELECT * FROM "C"')
  local lines = get_lines(b)
  eq(lines[1], 'SELECT * FROM "C"', "pure-nav: only the latest table remains")
  eq(#lines, 1, "pure-nav: exactly one query, no accumulation")
end

-- ── sync_query: an edited query is preserved, next jump appends below it ───────

do
  local b = make_pad()
  set_lines(b, { "-- C-CR:run", "" })
  qp.sync_query('SELECT * FROM "A"')                 -- auto
  set_lines(b, { [[SELECT * FROM "A" WHERE id = 1]] })  -- user edits the tail
  qp.sync_query('SELECT * FROM "B"')                 -- tail edited → append
  qp.sync_query('SELECT * FROM "C"')                 -- tail is our "B" → replace
  local lines = get_lines(b)
  eq(lines[1], [[SELECT * FROM "A" WHERE id = 1]], "edited: user's edit preserved")
  eq(lines[3], 'SELECT * FROM "C"', "edited: later auto-syncs replace only the tail")
  eq(#lines, 3, "edited: one preserved block + one live tail")
end

-- ── sync_query: never restates a query the pad already ends with ─────────────
-- The FK round trip: the user runs a query from the pad, jumps away with gf (we
-- append the FK query below theirs), then <C-o> back — which syncs their original
-- query again. Restating it would leave the pad holding it twice.

do
  local b = make_pad()
  set_lines(b, { "SELECT id, user_id FROM orders" })  -- user ran this from the pad
  qp.sync_query('SELECT * FROM "users" WHERE ("id" = 1)')  -- gf: appended below
  qp.sync_query("SELECT id, user_id FROM orders")          -- <C-o>: back to theirs
  local lines = get_lines(b)
  eq(#lines, 1, "round trip: the query is not duplicated")
  eq(lines[1], "SELECT id, user_id FROM orders", "round trip: the user's query is what's left")
end

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  qp.sync_query("SELECT 1")  -- pad already ends with exactly this
  local lines = get_lines(b)
  eq(#lines, 1, "already-there: nothing appended")
  eq(lines[1], "SELECT 1", "already-there: content untouched")
end

-- Dropping our block must not make us the owner of the user's block: a later
-- jump has to append below it, not overwrite it.
do
  local b = make_pad()
  set_lines(b, { "SELECT id, user_id FROM orders" })
  qp.sync_query('SELECT * FROM "users" WHERE ("id" = 1)')
  qp.sync_query("SELECT id, user_id FROM orders")  -- dedup: our block dropped
  qp.sync_query('SELECT * FROM "products"')        -- next jump
  local lines = get_lines(b)
  eq(lines[1], "SELECT id, user_id FROM orders", "ownership: user's query still there")
  eq(lines[3], 'SELECT * FROM "products"', "ownership: new query appended below it")
  eq(#lines, 3, "ownership: one user block + one live tail")
end

-- ── sync_query: hint on line 1, real content below → append, not replace ─────
-- The pad starts with the hint comment. If the user has written SQL below it,
-- the buffer is NOT empty. sync_query must append, not clobber.

do
  local b = make_pad()
  set_lines(b, {
    "-- C-CR:run  gA:ai  go:tables",
    "",
    "SELECT id, name FROM customers",
    "WHERE active = true",
  })
  qp.sync_query("SELECT * FROM orders")
  local lines = get_lines(b)
  eq(lines[1], "-- C-CR:run  gA:ai  go:tables", "hint+content: hint line preserved")
  eq(lines[3], "SELECT id, name FROM customers", "hint+content: user query preserved")
  local last = lines[#lines]
  eq(last, "SELECT * FROM orders", "hint+content: new query appended at end")
end

-- ── sync_query: no-op on blank/whitespace sql ────────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  qp.sync_query("   ")
  local lines = get_lines(b)
  eq(#lines, 1, "whitespace sql: pad unchanged")
  eq(lines[1], "SELECT 1", "whitespace sql: content preserved")
end

-- ── sync_query: no-op when pad bufnr is nil ──────────────────────────────────

do
  qp._set_pad_bufnr(nil)
  local ok = pcall(qp.sync_query, "SELECT 1")
  eq(ok, true, "nil pad bufnr: no error thrown")
end

-- ── _has_real_content: pure helper tests ─────────────────────────────────────

do
  -- empty table
  eq(qp._has_real_content({}), false, "hrc: empty lines = no content")
  -- single blank line
  eq(qp._has_real_content({ "" }), false, "hrc: single blank = no content")
  -- whitespace only
  eq(qp._has_real_content({ "   " }), false, "hrc: whitespace only = no content")
  -- hint-only (single)
  eq(qp._has_real_content({ "-- C-CR:run  gA:ai  go:tables" }), false, "hrc: hint line only = no content")
  -- hint + blank line
  eq(qp._has_real_content({ "-- C-CR:run  gA:ai  go:tables", "" }), false, "hrc: hint+blank = no content")
  -- AI separator only
  eq(qp._has_real_content({ "-- AI generated: SELECT 1" }), false, "hrc: ai-sep only = no content")
  -- hint + real SQL
  eq(qp._has_real_content({ "-- C-CR:run  gA:ai  go:tables", "", "SELECT 1" }), true, "hrc: hint+sql = has content")
  -- real SQL (no hint)
  eq(qp._has_real_content({ "SELECT id FROM users" }), true, "hrc: plain sql = has content")
  -- multi-line SQL
  eq(qp._has_real_content({ "SELECT *", "FROM orders", "WHERE id = 1" }), true, "hrc: multiline sql = has content")
  -- AI sep + real SQL below
  eq(qp._has_real_content({ "-- AI generated:", "", "SELECT 42" }), true, "hrc: ai-sep+sql = has content")
end

-- ── _block_under_cursor ───────────────────────────────────────────────────────

-- Helper: create a buffer with lines, open it in a window, position cursor.
-- Returns bufnr. The window is set as current so nvim_win_get_cursor(0) works.
local function buf_with_cursor(lines, cursor_line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor", width = 80, height = 20, row = 0, col = 0, style = "minimal",
  })
  vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
  return bufnr, win
end

local function close_win(win)
  if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
end

do
  -- cursor inside a ```sql block
  local lines = {
    "# Header",
    "Some text.",
    "```sql",
    "SELECT 1",
    "FROM dual",
    "```",
    "More text.",
  }
  local b, w = buf_with_cursor(lines, 4)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 1\nFROM dual", "block_under_cursor: cursor inside block returns SQL")
  close_win(w)
end

do
  -- cursor on the opening fence line: still extracts the block below it
  local lines = { "```sql", "SELECT 2", "```" }
  local b, w = buf_with_cursor(lines, 1)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 2", "block_under_cursor: cursor on opening fence extracts block below")
  close_win(w)
end

do
  -- cursor outside any block (plain text)
  local lines = { "Some prose.", "No SQL here." }
  local b, w = buf_with_cursor(lines, 1)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: cursor outside block returns nil")
  close_win(w)
end

do
  -- cursor on the closing fence
  local lines = { "```sql", "SELECT 3", "```" }
  local b, w = buf_with_cursor(lines, 3)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: cursor on closing fence returns nil")
  close_win(w)
end

do
  -- multiple blocks: cursor in second block returns only second block
  local lines = {
    "```sql",
    "SELECT 1",
    "```",
    "Text between blocks.",
    "```sql",
    "SELECT 2",
    "FROM t",
    "```",
  }
  local b, w = buf_with_cursor(lines, 6)
  local result = qp._block_under_cursor(b)
  eq(result, "SELECT 2\nFROM t", "block_under_cursor: cursor in second block returns second block")
  close_win(w)
end

do
  -- non-sql fence (```python) does not match
  local lines = { "```python", "print('hi')", "```" }
  local b, w = buf_with_cursor(lines, 2)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: non-sql fence returns nil")
  close_win(w)
end

do
  -- unclosed block (no closing fence) returns nil
  local lines = { "```sql", "SELECT 4" }
  local b, w = buf_with_cursor(lines, 2)
  local result = qp._block_under_cursor(b)
  eq(result, nil, "block_under_cursor: unclosed block returns nil")
  close_win(w)
end

-- ── _stmt_under_cursor ────────────────────────────────────────────────────────
-- Regression: jumping between tables makes sync_query stack SELECTs separated by
-- a blank line. C-CR must run ONLY the statement under the cursor, not the whole
-- pad (which would wrap 3 statements in one subquery → syntax error).

do
  -- three stacked queries; cursor in the second → returns only the second
  local lines = {
    'SELECT * FROM "Organization"',
    "",
    'SELECT * FROM "OrganizationPermission"',
    "",
    'SELECT * FROM "PartnerIntegrationOrganization"',
  }
  local b, w = buf_with_cursor(lines, 3)
  eq(qp._stmt_under_cursor(b), 'SELECT * FROM "OrganizationPermission"',
    "stmt_under_cursor: returns only the paragraph under the cursor")
  close_win(w)
end

do
  -- cursor on the last stacked query
  local lines = {
    'SELECT * FROM "a"',
    "",
    'SELECT * FROM "b"',
  }
  local b, w = buf_with_cursor(lines, 3)
  eq(qp._stmt_under_cursor(b), 'SELECT * FROM "b"', "stmt_under_cursor: last statement")
  close_win(w)
end

do
  -- a single multi-line statement (no blank lines) → the whole thing
  local lines = { "SELECT *", 'FROM "t"', "WHERE x = 1" }
  local b, w = buf_with_cursor(lines, 2)
  eq(qp._stmt_under_cursor(b), 'SELECT *\nFROM "t"\nWHERE x = 1',
    "stmt_under_cursor: multi-line statement kept intact")
  close_win(w)
end

do
  -- cursor on the blank separator line attaches to the statement above
  local lines = { 'SELECT * FROM "a"', "", 'SELECT * FROM "b"' }
  local b, w = buf_with_cursor(lines, 2)
  eq(qp._stmt_under_cursor(b), 'SELECT * FROM "a"',
    "stmt_under_cursor: boundary line attaches to the paragraph above")
  close_win(w)
end

do
  -- leading blank line: cursor there attaches to the statement below
  local lines = { "", 'SELECT * FROM "only"' }
  local b, w = buf_with_cursor(lines, 1)
  eq(qp._stmt_under_cursor(b), 'SELECT * FROM "only"',
    "stmt_under_cursor: leading boundary falls through to statement below")
  close_win(w)
end

do
  -- the hint comment is a boundary, not part of the statement
  local lines = { "-- C-CR:run block or buffer", 'SELECT * FROM "t"' }
  local b, w = buf_with_cursor(lines, 2)
  eq(qp._stmt_under_cursor(b), 'SELECT * FROM "t"',
    "stmt_under_cursor: hint line excluded from the statement")
  close_win(w)
end

do
  -- a ```sql fence still wins over paragraph detection
  local lines = { "```sql", "SELECT 1", "```" }
  local b, w = buf_with_cursor(lines, 2)
  eq(qp._stmt_under_cursor(b), "SELECT 1", "stmt_under_cursor: markdown fence takes priority")
  close_win(w)
end

do
  -- empty / hint-only buffer → nil (caller falls back to get_content)
  local lines = { "-- C-CR:run block or buffer", "" }
  local b, w = buf_with_cursor(lines, 1)
  eq(qp._stmt_under_cursor(b), nil, "stmt_under_cursor: no real statement returns nil")
  close_win(w)
end

print(string.format("\nquery_pad_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
