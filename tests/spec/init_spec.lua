-- init_spec.lua: unit tests for resolve_query routing, is_queryable_file and
-- the welcome screen (open_welcome)
local grip = require("dadbod-grip")

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

local function contains(s, pattern, msg)
  assert(s:find(pattern, 1, true), (msg or "") .. ": expected '" .. s .. "' to contain '" .. pattern .. "'")
end

-- ── is_queryable_file: path prefix ───────────────────────────────────────────

test("is_queryable_file: absolute path with .parquet", function()
  eq(grip._is_queryable_file("/data/sales.parquet"), true)
end)

test("is_queryable_file: tilde path with .csv", function()
  eq(grip._is_queryable_file("~/data/report.csv"), true)
end)

test("is_queryable_file: dot-slash with .json", function()
  eq(grip._is_queryable_file("./data.json"), true)
end)

test("is_queryable_file: dot-dot-slash with .tsv", function()
  eq(grip._is_queryable_file("../up/data.tsv"), true)
end)

test("is_queryable_file: bare name is not a file path", function()
  eq(grip._is_queryable_file("tablename"), false)
end)

-- ── is_queryable_file: extension ─────────────────────────────────────────────

test("is_queryable_file: .parquet", function()
  eq(grip._is_queryable_file("/x.parquet"), true)
end)

test("is_queryable_file: .csv", function()
  eq(grip._is_queryable_file("/x.csv"), true)
end)

test("is_queryable_file: .json", function()
  eq(grip._is_queryable_file("/x.json"), true)
end)

test("is_queryable_file: .xlsx", function()
  eq(grip._is_queryable_file("/x.xlsx"), true)
end)

test("is_queryable_file: .ndjson", function()
  eq(grip._is_queryable_file("/x.ndjson"), true)
end)

test("is_queryable_file: .jsonl", function()
  eq(grip._is_queryable_file("/x.jsonl"), true)
end)

test("is_queryable_file: shared ORC, Arrow, and IPC extensions", function()
  eq(grip._is_queryable_file("/x.orc"), true)
  eq(grip._is_queryable_file("/x.arrow"), true)
  eq(grip._is_queryable_file("/x.ipc"), true)
end)

test("is_queryable_file: .txt not supported", function()
  eq(grip._is_queryable_file("/x.txt"), false)
end)

-- ── is_queryable_file: case insensitivity ────────────────────────────────────

test("is_queryable_file: uppercase .CSV", function()
  eq(grip._is_queryable_file("/path/file.CSV"), true)
end)

-- ── resolve_query: routing ───────────────────────────────────────────────────

test("resolve_query: table name returns table spec", function()
  local spec, tbl = grip._resolve_query("users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name")
end)

test("resolve_query: SELECT extracts table name from FROM clause", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "table_name should be extracted from SELECT")
end)

test("resolve_query: WITH returns raw spec", function()
  local spec = grip._resolve_query("WITH cte AS (SELECT 1) SELECT * FROM cte", 50)
  assert(spec, "spec should not be nil")
end)

test("resolve_query: TABLE extracts table name", function()
  local spec, tbl = grip._resolve_query("TABLE orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "TABLE should extract table name")
end)

test("resolve_query: nil with expand stub returns table spec", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "users" end
  local spec, tbl = grip._resolve_query(nil, 50)
  vim.fn.expand = orig
  assert(spec, "spec should not be nil")
  eq(tbl, "users", "table_name from cword")
end)

test("resolve_query: empty string with empty expand returns nil + error", function()
  local orig = vim.fn.expand
  vim.fn.expand = function() return "" end
  local spec, err = grip._resolve_query("", 50)
  vim.fn.expand = orig
  eq(spec, nil, "spec should be nil")
  assert(err, "should return error message")
end)

test("resolve_query: lowercase 'select' returns raw spec", function()
  local spec = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
end)

-- ── resolve_query: table extraction from SELECT/TABLE ────────────────────────

test("resolve_query: SELECT with double-quoted PascalCase table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "should unquote double-quoted table name")
end)

test("resolve_query: SELECT with backtick-quoted table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM `my_table`", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "my_table", "should unquote backtick-quoted table name")
end)

test("resolve_query: SELECT with schema-qualified table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM public.users", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.users", "should extract schema-qualified table name")
end)

test("resolve_query: SELECT with schema-qualified quoted table", function()
  local spec, tbl = grip._resolve_query('SELECT * FROM "public"."Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "public.Participant", "should unquote schema-qualified quoted table")
end)

test("resolve_query: SELECT with WHERE clause still extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders WHERE id = 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table when WHERE clause follows")
end)

test("resolve_query: SELECT with JOIN returns nil table (ambiguous)", function()
  local spec, tbl = grip._resolve_query("SELECT a.*, b.* FROM users a JOIN orders b ON a.id = b.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for JOINs")
end)

test("resolve_query: SELECT with LEFT JOIN returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for LEFT JOINs")
end)

test("resolve_query: SELECT with comma-join returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM users, orders WHERE users.id = orders.user_id", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for comma-joins")
end)

test("resolve_query: SELECT from subquery returns nil table", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM (SELECT 1) t", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil for subqueries")
end)

test("resolve_query: select 1 (no FROM) returns nil table", function()
  local spec, tbl = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "should return nil when no FROM clause")
end)

test("resolve_query: TABLE with quoted name extracts unquoted", function()
  local spec, tbl = grip._resolve_query('TABLE "Participant"', 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "Participant", "TABLE should unquote table name")
end)

test("resolve_query: multiline SELECT extracts table", function()
  local spec, tbl = grip._resolve_query("SELECT *\nFROM orders\nWHERE id > 0", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, "orders", "should extract table from multiline SELECT")
end)

-- ── resolve_query: file-as-table ─────────────────────────────────────────────

test("resolve_query: readable file path returns raw spec", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec, tbl, fpath = grip._resolve_query("/data/sales.parquet", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil")
  eq(fpath, "/data/sales.parquet", "file_path")
end)

test("resolve_query: file path with single quote is escaped", function()
  local orig_readable = vim.fn.filereadable
  local orig_fnamemodify = vim.fn.fnamemodify
  vim.fn.filereadable = function() return 1 end
  vim.fn.fnamemodify = function(p) return p end
  local spec = grip._resolve_query("/data/it's.csv", 50)
  vim.fn.filereadable = orig_readable
  vim.fn.fnamemodify = orig_fnamemodify
  assert(spec, "spec should not be nil")
  -- The SQL in the spec should have escaped single quote
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

-- ── is_queryable_file: URL detection ────────────────────────────────────────

test("is_queryable_file: https URL with .csv", function()
  eq(grip._is_queryable_file("https://example.com/data.csv"), true)
end)

test("is_queryable_file: http URL with .parquet", function()
  eq(grip._is_queryable_file("http://example.com/data.parquet"), true)
end)

test("is_queryable_file: S3 URL with .parquet", function()
  eq(grip._is_queryable_file("s3://analytics/data.parquet"), true)
end)

test("is_queryable_file: https URL with .json", function()
  eq(grip._is_queryable_file("https://example.com/data.json"), true)
end)

test("is_queryable_file: https URL with .ndjson", function()
  eq(grip._is_queryable_file("https://example.com/data.ndjson"), true)
end)

test("is_queryable_file: https URL with .xlsx", function()
  eq(grip._is_queryable_file("https://example.com/data.xlsx"), true)
end)

test("is_queryable_file: https URL with unsupported extension", function()
  eq(grip._is_queryable_file("https://example.com/page.html"), false)
end)

test("is_queryable_file: URL with query string stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.csv?token=abc"), true)
end)

test("is_queryable_file: URL with fragment stripped for extension check", function()
  eq(grip._is_queryable_file("https://example.com/data.parquet#row=5"), true)
end)

test("is_queryable_file: URL case insensitive", function()
  eq(grip._is_queryable_file("https://example.com/DATA.CSV"), true)
end)

test("is_queryable_file: bare https not a file", function()
  eq(grip._is_queryable_file("https://example.com/"), false)
end)

-- ── resolve_query: URL-as-table ─────────────────────────────────────────────

test("resolve_query: https URL returns raw spec with URL as file_path", function()
  local spec, tbl, fpath = grip._resolve_query("https://example.com/data.csv", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for URL queries")
  eq(fpath, "https://example.com/data.csv", "file_path should be the URL")
end)

test("resolve_query: S3 URL returns raw spec with URL as file_path", function()
  local spec, tbl, fpath = grip._resolve_query("s3://analytics/data.parquet", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for S3 queries")
  eq(fpath, "s3://analytics/data.parquet", "file_path should be the S3 URL")
  contains(require("dadbod-grip.query").build_sql(spec), "s3://analytics/data.parquet",
    "SQL should contain the S3 URL")
end)

test("resolve_query: URL SQL contains the URL in FROM clause", function()
  local spec = grip._resolve_query("https://example.com/data.parquet", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "https://example.com/data.parquet", "SQL should contain the URL")
end)

test("resolve_query: URL with single quote is escaped", function()
  local spec = grip._resolve_query("https://example.com/it's.csv", 50)
  assert(spec, "spec should not be nil")
  local built_sql = require("dadbod-grip.query").build_sql(spec)
  contains(built_sql, "it''s", "single quote should be escaped")
end)

test("resolve_query: URL does not call filereadable", function()
  local called = false
  local orig = vim.fn.filereadable
  vim.fn.filereadable = function() called = true; return 0 end
  local spec = grip._resolve_query("https://example.com/data.csv", 50)
  vim.fn.filereadable = orig
  assert(spec, "spec should not be nil")
  eq(called, false, "filereadable should not be called for URLs")
end)

-- ── open_welcome: extmark highlights ─────────────────────────────────────────
-- open_welcome() applies its syntax highlights inside vim.schedule (so they
-- survive the FileType autocmd -- see init.lua), and headless tests have no
-- UI loop driving that callback on their own. Rather than exporting a
-- renderer to call directly, these drive vim.schedule for real and vim.wait
-- on the extmarks actually showing up: that exercises the exact scheduled
-- path :Grip and :GripHome run, not a reimplementation of it.

local WELCOME_NS = vim.api.nvim_create_namespace("grip_welcome")

--- Open the welcome screen for real and wait (bounded, on the actual
--- condition -- not a fixed sleep) for its scheduled highlight pass to run.
--- @return integer buf, table marks  (nvim_buf_get_extmarks with details)
local function open_welcome_and_wait()
  grip.open_welcome()
  local buf = vim.api.nvim_get_current_buf()
  local marks
  local ok = vim.wait(1000, function()
    marks = vim.api.nvim_buf_get_extmarks(buf, WELCOME_NS, 0, -1, { details = true })
    return #marks > 0
  end, 10)
  assert(ok, "welcome highlight scheduling did not fire within 1s")
  return buf, marks
end

-- Every highlight group the welcome screen uses, with a predicate for what a
-- mark of that group is allowed to cover. This plus the three cases below
-- replaces the totals this test used to pin (62 marks, 42 of them Identifier) --
-- numbers that had to be recounted by hand after any edit to the logo or the
-- keymap rows, and that said nothing about *where* the highlights landed.
--
-- GripNullStaged is deliberately absent even though init.lua can apply it (to a
-- "·NULL·" token on any line): the current screen has no such token, so a
-- predicate for it would never run. Leaving the dictionary closed means that if
-- "·NULL·" is ever added to the logo, the first case below fails with
-- "unexpected highlight group ... GripNullStaged" -- pointing at this table so
-- whoever adds it has to say what that mark must cover, instead of the mark
-- going unchecked.
local WELCOME_GROUPS = {
  -- Section headers, bottom separator and tagline: the whole line.
  Comment      = function(text, line) return text == line end,
  -- Logo box rows (╔ ║ ╚): the whole line.
  Special      = function(text, line) return text == line end,
  -- The plugin name plus the version that follows it, to end of line.
  Title        = function(text) return text:match("^dadbod%-grip") ~= nil end,
  Statement    = function(text) return text:match("^:Grip%S*$") ~= nil end,
  -- Keymap keys and --flags: always one whitespace-free token.
  Identifier   = function(text) return text:match("^%S+$") ~= nil end,
  GripModified = function(text) return text == "violet = modified" end,
  GripInserted = function(text) return text == "green = inserted" end,
  GripDeleted  = function(text) return text == "red = deleted" end,
}

--- Index the Identifier marks for lookup by position.
--- @return table  row -> { [start_col] = end_col }
local function identifier_marks(marks)
  local idents = {}
  for _, m in ipairs(marks) do
    if m[4].hl_group == "Identifier" then
      idents[m[2]] = idents[m[2]] or {}
      idents[m[2]][m[3]] = m[4].end_col
    end
  end
  return idents
end

test("open_welcome: every rendered line is highlighted, and every mark fits its group", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local seen_groups, per_line = {}, {}
  for _, m in ipairs(marks) do
    local row, col, det = m[2], m[3], m[4]
    local line = lines[row + 1]
    assert(line, "mark sits on rendered row " .. row)
    local pred = WELCOME_GROUPS[det.hl_group]
    assert(pred, "unexpected highlight group on the welcome screen: " .. tostring(det.hl_group))
    assert(det.end_col and det.end_col > col and det.end_col <= #line,
      det.hl_group .. " mark on line " .. (row + 1) .. " covers a non-empty range inside the line")
    local text = line:sub(col + 1, det.end_col)
    assert(pred(text, line),
      det.hl_group .. " on line " .. (row + 1) .. " covers '" .. text .. "', not what that group marks up")
    seen_groups[det.hl_group] = true
    per_line[row] = (per_line[row] or 0) + 1
  end

  for group in pairs(WELCOME_GROUPS) do
    assert(seen_groups[group], "no " .. group .. " highlight was applied anywhere")
  end

  -- Blank lines are the only unhighlighted ones: a branch that stops firing
  -- leaves its lines bare. This only catches the *first* mark on a line, so the
  -- two positions that carry a second one (the right-hand keymap key and the
  -- --flag in a :Grip example) get a case of their own below.
  for i, line in ipairs(lines) do
    if line ~= "" then
      assert((per_line[i - 1] or 0) > 0, "line " .. i .. " is rendered but unhighlighted: " .. line)
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: keymap rows highlight both keys of the two-column layout", function()
  -- Keymap rows put the left key at byte 2 and, when they have one, a
  -- right-hand key at byte 31 (0-indexed) -- see the keymap branch in
  -- init.lua. Rows are recognised by their own left-key mark instead of by
  -- re-deriving init.lua's line classifier, so this follows the logo text
  -- around: adding or reflowing a keymap row needs no edit here.
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local idents = identifier_marks(marks)

  local rows_checked = 0
  for row, starts in pairs(idents) do
    if starts[2] then  -- a key at byte 2: this row is a keymap row
      local line = lines[row + 1]
      local _, after = line:match("^  (%S+)()")
      eq(starts[2], after - 1, "left key spans exactly its token on line " .. (row + 1))
      if #line >= 34 and line:sub(32, 32) ~= " " then
        local rs, re = line:find("%S+", 32)
        assert(starts[rs - 1] == re, "right-column key '" .. line:sub(rs, re)
          .. "' on line " .. (row + 1) .. " is not highlighted as its own token")
      end
      rows_checked = rows_checked + 1
    end
  end
  assert(rows_checked > 0, "the welcome screen still has keymap rows to check")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: --flag tokens in the :Grip examples are highlighted", function()
  -- The flag mark is a *second* mark on a line that already carries a Statement
  -- (see the :Grip branch in init.lua), so neither "every line carries a mark"
  -- nor the keymap case above -- which recognises rows by an Identifier at byte
  -- 2, and :Grip rows have none -- notices when it stops being applied.
  --
  -- Scanned straight off the rendered text, so it follows the logo around.
  -- init.lua marks the first --flag per :Grip example; every such token on the
  -- current screen is the first on its line, and a second unmarked flag on one
  -- line should surface here rather than pass silently.
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local idents = identifier_marks(marks)

  local flags_checked = 0
  for i, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e = line:find("%-%-%S+", from)
      if not s then break end
      assert((idents[i - 1] or {})[s - 1] == e, "--flag '" .. line:sub(s, e)
        .. "' on line " .. i .. " is not highlighted as its own token")
      flags_checked = flags_checked + 1
      from = e + 1
    end
  end
  assert(flags_checked > 0, "the welcome screen still shows a --flag example to check")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("open_welcome: title and legend marks carry the right range and priority", function()
  local buf, marks = open_welcome_and_wait()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local function find(hl_group)
    for _, m in ipairs(marks) do
      if m[4].hl_group == hl_group then return m end
    end
  end

  -- Title: "dadbod-grip" through end-of-line on the logo row, at the default
  -- extmark priority (nothing overrides it -- see hl_range() in init.lua).
  -- The line contains the version string, so its length isn't hardcoded here:
  -- it's read back from the buffer, the same way hl_range() computed it.
  local title = find("Title")
  assert(title, "Title mark exists")
  local title_line = lines[title[2] + 1]
  local vs = title_line:find("dadbod-grip", 1, true)
  assert(vs, "title line contains the plugin name")
  eq(title[3], vs - 1, "title starts where the name does")
  eq(title[4].end_col, #title_line, "title runs to end of line")
  eq(title[4].priority, 4096, "default extmark priority")

  -- Legend phrases sit at explicit priority 200 so they win over syntax
  -- highlighting on the same line (see hl_phrase() in init.lua).
  for _, spec in ipairs({
    { group = "GripModified", phrase = "violet = modified" },
    { group = "GripInserted", phrase = "green = inserted" },
    { group = "GripDeleted",  phrase = "red = deleted" },
  }) do
    local m = find(spec.group)
    assert(m, spec.group .. " mark exists")
    local legend_line = lines[m[2] + 1]
    local s, e = legend_line:find(spec.phrase, 1, true)
    assert(s, spec.group .. " phrase found in its line")
    eq(m[3], s - 1, spec.group .. " start col")
    eq(m[4].end_col, e, spec.group .. " end col")
    eq(m[4].priority, 200, spec.group .. " priority")
  end

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\ninit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
