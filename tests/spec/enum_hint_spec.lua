-- enum_hint_spec.lua: enum value hints in the cell editor.
-- When a column has a small set of known distinct values (<= 8 non-NULL),
-- the cell editor shows them as virtual text so the user doesn't have to
-- remember valid enum values. Values come from an on-demand
-- SELECT DISTINCT ... LIMIT 9, cached on the session (session.enum_cache).
-- Uses tests/seed_sqlite.db fixtures: orders.status has 5 distinct values.

local db     = require("dadbod-grip.db")
local view   = require("dadbod-grip.view")
local editor = require("dadbod-grip.editor")

local url = "sqlite:tests/seed_sqlite.db"

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

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(type(s) == "string" and s:find(pattern, 1, true),
    (msg or "") .. ": expected '" .. tostring(s) .. "' to contain '" .. pattern .. "'")
end

--- Minimal session shape: enum_hint_values only needs state.table_name/url.
local function fake_session(table_name)
  return { state = { table_name = table_name, url = url } }
end

--- Count db.query calls made while running fn.
local function count_queries(fn)
  local calls = 0
  local orig = db.query
  db.query = function(...)
    calls = calls + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  db.query = orig
  if not ok then error(err) end
  return calls
end

-- ── view.enum_hint_values: fetching + threshold ───────────────────────────

test("enum column (<= 8 distinct): returns sorted value list", function()
  local session = fake_session("orders")
  local vals = view.enum_hint_values(session, "status")
  truthy(vals, "values returned for orders.status")
  eq(#vals, 5, "five distinct statuses")
  eq(vals[1], "cancelled", "sorted first value")
  eq(vals[5], "shipped", "sorted last value")
end)

test("high-cardinality column (> 8 distinct): returns nil", function()
  local session = fake_session("orders")
  local vals = view.enum_hint_values(session, "id")
  eq(vals, nil, "no hint for 150 distinct ids")
end)

test("second lookup is served from session.enum_cache (no re-query)", function()
  local session = fake_session("orders")
  local first
  local c1 = count_queries(function()
    first = view.enum_hint_values(session, "status")
  end)
  eq(c1, 1, "first lookup queries once")
  truthy(session.enum_cache and session.enum_cache["orders"], "cache populated")
  local second
  local c2 = count_queries(function()
    second = view.enum_hint_values(session, "status")
  end)
  eq(c2, 0, "second lookup: cache hit, no query")
  eq(second, first, "cached table is returned as-is")
end)

test("negative result is cached too (no re-query for wide columns)", function()
  local session = fake_session("orders")
  local c1 = count_queries(function()
    eq(view.enum_hint_values(session, "id"), nil, "first: nil")
  end)
  eq(c1, 1, "first lookup queries once")
  local c2 = count_queries(function()
    eq(view.enum_hint_values(session, "id"), nil, "second: still nil")
  end)
  eq(c2, 0, "negative result cached: no re-query")
end)

test("no table context: returns nil without querying", function()
  local session = { state = { table_name = nil, url = url } }
  local calls = count_queries(function()
    eq(view.enum_hint_values(session, "status"), nil, "nil without table")
  end)
  eq(calls, 0, "no query without table context")
end)

test("nil session: returns nil without erroring", function()
  eq(view.enum_hint_values(nil, "status"), nil, "nil session tolerated")
end)

-- ── SQL shape: quoting, NULL exclusion, limit ─────────────────────────────

test("DISTINCT SQL quotes identifiers and excludes NULLs", function()
  local captured
  local orig = db.query
  db.query = function(sql_str, _)
    captured = sql_str
    return { rows = { { "a" }, { "b" } }, columns = { "status" } }
  end
  local session = fake_session([[weird"table]])
  local ok, err = pcall(function()
    local vals = view.enum_hint_values(session, [[sel"ect]])
    truthy(vals, "values returned from mocked query")
  end)
  db.query = orig
  assert(ok, tostring(err))
  truthy(captured, "query issued")
  contains(captured, [["weird""table"]], "table identifier quoted")
  contains(captured, [["sel""ect"]], "column identifier quoted")
  contains(captured, "IS NOT NULL", "NULLs excluded")
  contains(captured, "LIMIT 9", "fetches at most threshold+1 rows")
  contains(captured, "DISTINCT", "distinct values")
end)

test("query error: returns nil, cached as negative", function()
  local orig = db.query
  db.query = function() return nil, "boom" end
  local session = fake_session("orders")
  local ok, err = pcall(function()
    eq(view.enum_hint_values(session, "status"), nil, "nil on query error")
  end)
  db.query = orig
  assert(ok, tostring(err))
  local calls = count_queries(function()
    eq(view.enum_hint_values(session, "status"), nil, "still nil")
  end)
  eq(calls, 0, "error result cached: no retry storm")
end)

-- ── editor: virtual-text rendering ────────────────────────────────────────

--- Open the editor with opts, inspect its buffer via fn(buf), then cancel.
local function with_editor(opts, fn)
  local committed = nil
  editor.open("orders.status", "pending", function(res)
    if res ~= nil then committed = res end
  end, opts)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local ok, err = pcall(fn, buf)
  -- Leave through the editor's own cancel mapping (NORMAL q) rather than closing
  -- the window out from under it, so the teardown exercises the cancel path
  -- instead of bypassing it. nvim_win_close is only the fallback.
  vim.cmd("stopinsert")
  pcall(vim.cmd, "normal q")
  pcall(vim.api.nvim_win_close, win, true)
  if not ok then error(err) end
  -- Cancelling must report nil, not write the value through. The callback used to
  -- be captured into a table nothing ever read, so a commit-on-cancel regression
  -- would have gone unnoticed here.
  assert(committed == nil, "editor committed a value on cancel: " .. tostring(committed))
end

--- Collect virt_lines hint texts from the enum-hint namespace.
local function enum_hint_lines(buf)
  local ns = vim.api.nvim_create_namespace("grip_enum_hint")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local texts = {}
  for _, m in ipairs(marks) do
    local details = m[4]
    for _, vline in ipairs(details.virt_lines or {}) do
      for _, chunk in ipairs(vline) do
        table.insert(texts, { text = chunk[1], hl = chunk[2] })
      end
    end
  end
  return texts
end

test("editor shows enum values as one virtual line", function()
  with_editor({ enum_values = { "active", "pending", "done" } }, function(buf)
    local hints = enum_hint_lines(buf)
    eq(#hints, 1, "exactly one hint chunk")
    contains(hints[1].text, "values:", "labelled")
    contains(hints[1].text, "active", "first value shown")
    contains(hints[1].text, "pending", "second value shown")
    contains(hints[1].text, "done", "third value shown")
    contains(hints[1].text, "│", "separator between values")
    eq(hints[1].hl, "Comment", "muted highlight (matches timestamp hint)")
  end)
end)

test("editor without enum_values renders no enum hint", function()
  with_editor({}, function(buf)
    eq(#enum_hint_lines(buf), 0, "no hint extmark")
  end)
end)

test("long enum values are truncated in the hint", function()
  local long = string.rep("x", 60)
  with_editor({ enum_values = { long, "ok" } }, function(buf)
    local hints = enum_hint_lines(buf)
    eq(#hints, 1, "one hint chunk")
    assert(not hints[1].text:find(long, 1, true), "full 60-char value not shown")
    contains(hints[1].text, "…", "truncation marker")
    contains(hints[1].text, "ok", "short value intact")
  end)
end)

--- Summary
print(string.format("\nenum_hint_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
