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

-- ── sync_query: multiple appends accumulate ──────────────────────────────────

do
  local b = make_pad()
  set_lines(b, { "SELECT 1" })
  qp.sync_query("SELECT 2")
  qp.sync_query("SELECT 3")
  local lines = get_lines(b)
  eq(lines[1], "SELECT 1", "multi-append: original preserved")
  eq(lines[3], "SELECT 2", "multi-append: second query appended")
  eq(lines[5], "SELECT 3", "multi-append: third query appended")
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

print(string.format("\nquery_pad_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
