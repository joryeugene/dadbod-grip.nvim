-- export_spec.lua: TDD spec for view._format_export()
-- The pure formatting function is exported as view._format_export(rows, cols, format, table_name).
-- Run: just test
local view = require("dadbod-grip.view")
local db = require("dadbod-grip.db")
local query = require("dadbod-grip.query")
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
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function contains(s, pattern, msg)
  assert(tostring(s):find(pattern, 1, true),
    (msg or "") .. ": expected to contain '" .. pattern .. "', got: " .. tostring(s))
end

local function not_contains(s, pattern, msg)
  assert(not tostring(s):find(pattern, 1, true),
    (msg or "") .. ": expected NOT to contain '" .. pattern .. "', got: " .. tostring(s))
end

local fmt = view._format_export

-- ── CSV ─────────────────────────────────────────────────────────────────────

test("format_export csv: header row is first line", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "csv", "users")
  eq(lines[1], "name,age")
end)

test("format_export csv: data row follows header", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "csv", "users")
  eq(lines[2], "alice,30")
end)

test("format_export csv: value with comma is wrapped in quotes", function()
  local lines = fmt({ {"Smith, John", "25"} }, {"name", "age"}, "csv", "users")
  contains(lines[2], '"Smith, John"')
end)

test("format_export csv: NULL value is empty string in csv", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "csv", "users")
  -- nil value → empty field
  eq(lines[2], ",30")
end)

test("format_export csv: two rows produce three lines (header + 2)", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "csv", "t")
  eq(#lines, 3)
end)

-- ── JSON ─────────────────────────────────────────────────────────────────────

test("format_export json: output is valid JSON (parseable)", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "json", "users")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "Expected parseable JSON, got: " .. joined)
  assert(type(decoded) == "table" and #decoded == 1)
end)

test("format_export json: NULL value is json null (not string 'null')", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "json", "users")
  local joined = table.concat(lines, "\n")
  -- Raw null keyword must appear, not the string "null"
  contains(joined, '"name": null')
  not_contains(joined, '"name": "null"')
end)

test("format_export json: two rows produces array of two objects", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "json", "t")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "JSON parse failed: " .. joined)
  eq(#decoded, 2)
end)

-- ── SQL ──────────────────────────────────────────────────────────────────────

test("format_export sql: produces INSERT statements", function()
  local lines = fmt({ {"alice", "30"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "INSERT INTO")
  contains(joined, "users")
end)

test("format_export sql: NULL value becomes SQL NULL keyword", function()
  local lines = fmt({ {nil, "30"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "NULL")
  -- should not be a quoted string 'NULL'
  not_contains(joined, "'NULL'")
end)

test("format_export sql: value with single quote is escaped", function()
  local lines = fmt({ {"O'Brien", "25"} }, {"name", "age"}, "sql", "users")
  local joined = table.concat(lines, "\n")
  contains(joined, "O''Brien")
end)

test("format_export sql: two rows produce two INSERT statements", function()
  local lines = fmt({ {"a", "1"}, {"b", "2"} }, {"name", "val"}, "sql", "t")
  local count = 0
  for _, line in ipairs(lines) do
    if line:find("INSERT INTO", 1, true) then count = count + 1 end
  end
  eq(count, 2)
end)

test("format_export sql: raw query uses _grip_result as table name when no table", function()
  local lines = fmt({ {"x"} }, {"col"}, "sql", nil)
  local joined = table.concat(lines, "\n")
  contains(joined, "_grip_result")
end)

test("format_export sql: column names are included in INSERT header", function()
  local lines = fmt({ {"alice"} }, {"full_name"}, "sql", "people")
  local joined = table.concat(lines, "\n")
  contains(joined, "full_name")
  contains(joined, "VALUES")
end)

test("format_export sql: multiple NULL columns all become NULL", function()
  local lines = fmt({ {nil, nil, "x"} }, {"a", "b", "c"}, "sql", "t")
  local joined = table.concat(lines, "\n")
  -- Two NULLs: pattern NULL, NULL must appear
  contains(joined, "NULL, NULL")
end)

-- ── CSV edge cases ────────────────────────────────────────────────────────────

test("format_export csv: value with double-quote is escaped by doubling", function()
  local lines = fmt({ {'say "hi"', "1"} }, {"msg", "n"}, "csv", "t")
  -- RFC 4180: embedded " → wrap in quotes and double each internal "
  contains(lines[2], '""hi""')
end)

test("format_export csv: value with newline is wrapped in quotes", function()
  local lines = fmt({ {"line1\nline2", "2"} }, {"text", "n"}, "csv", "t")
  contains(lines[2], '"line1\nline2"')
end)

-- ── JSON edge cases ───────────────────────────────────────────────────────────

test("format_export json: numeric value is unquoted in output", function()
  local lines = fmt({ {"alice", "42"} }, {"name", "score"}, "json", "t")
  local joined = table.concat(lines, "\n")
  -- "score": 42  (no quotes around 42)
  contains(joined, '"score": 42')
  not_contains(joined, '"score": "42"')
end)

test("format_export json: value with backslash is escaped", function()
  local lines = fmt({ {"C:\\path"} }, {"dir"}, "json", "t")
  local joined = table.concat(lines, "\n")
  -- backslash must be escaped as \\
  contains(joined, "C:\\\\path")
end)

test("format_export json: empty row list produces empty array", function()
  local lines = fmt({}, {"a", "b"}, "json", "t")
  local joined = table.concat(lines, "\n")
  local ok, decoded = pcall(vim.fn.json_decode, joined)
  assert(ok, "Expected parseable JSON for empty rows")
  assert(type(decoded) == "table" and #decoded == 0)
end)

-- ── unknown format ────────────────────────────────────────────────────────────

test("format_export unknown format returns empty table", function()
  local lines = fmt({ {"x"} }, {"col"}, "nope", "t")
  eq(#lines, 0)
end)

-- ── file safety / streaming ────────────────────────────────────────────────────────

test("write_export_file streams JSON batches and atomically replaces destination", function()
  local path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "old content" }, path)
  local rows = {}
  for i = 1, 1001 do rows[i] = { tostring(i), "name_" .. i } end
  local ok, err = view._write_export_file(rows, { "id", "name" }, "json", "users", path)
  assert(ok, "export failed: " .. tostring(err))
  local decoded = vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
  eq(#decoded, 1001, "all streamed rows present")
  eq(decoded[1001].name, "name_1001", "last batch present")
  eq(#vim.fn.glob(path .. ".grip-tmp-*", false, true), 0, "no temp file remains")
  vim.fn.delete(path)
end)

test("write_export_file failure preserves destination and removes partial temp", function()
  local path = vim.fn.tempname() .. ".csv"
  vim.fn.writefile({ "keep me" }, path)
  local explosive = setmetatable({}, { __tostring = function() error("formatter exploded") end })
  local rows = {}
  for i = 1, 1000 do rows[i] = { tostring(i) } end
  rows[1001] = { explosive }
  local ok, err = view._write_export_file(rows, { "id" }, "csv", "users", path)
  eq(ok, nil, "failure reported")
  contains(err, "formatter exploded", "original failure returned")
  eq(table.concat(vim.fn.readfile(path), "\n"), "keep me", "destination untouched")
  eq(#vim.fn.glob(path .. ".grip-tmp-*", false, true), 0, "partial temp removed")
  vim.fn.delete(path)
end)

test("clipboard export prompts scope before format and removes only pagination", function()
  local bufnr = 99123
  local spec = query.new_table("users", 100)
  spec = query.add_filter(spec, '"active" = true')
  spec = query.toggle_sort(spec, "name")
  spec = query.set_page(spec, 2)
  view._sessions[bufnr] = {
    state = { columns = { "id", "name" }, rows = { { "page", "row" } }, table_name = "users" },
    query_spec = spec,
    total_rows = 2,
    url = "sqlite:test.db",
  }

  local prompts, sent_sql = {}, nil
  local orig_select, orig_query = vim.ui.select, db.query
  vim.ui.select = function(_, opts, callback)
    prompts[#prompts + 1] = opts.prompt
    callback(opts.prompt == "Export scope:" and "All matching rows" or "CSV")
  end
  db.query = function(sql)
    sent_sql = sql
    return { columns = { "id", "name" }, rows = { { "1", "Alice" }, { "2", "Bob" } } }
  end
  local ok, err = pcall(view.export_to_clipboard, bufnr)
  vim.ui.select, db.query = orig_select, orig_query
  view._sessions[bufnr] = nil
  if not ok then error(err) end

  eq(prompts[1], "Export scope:", "scope is first")
  eq(prompts[2], "Export format:", "format is second")
  contains(sent_sql, 'WHERE ("active" = true)', "filter kept")
  contains(sent_sql, 'ORDER BY "name" ASC', "sort kept")
  not_contains(sent_sql, "LIMIT", "pagination removed")
  not_contains(sent_sql, "OFFSET", "page offset removed")
end)

test("clipboard all-row export refuses more than 100000 rows before querying", function()
  local bufnr = 99124
  view._sessions[bufnr] = {
    state = { columns = { "id" }, rows = { { "1" } }, table_name = "users" },
    query_spec = query.new_table("users", 100), total_rows = 100001, url = "sqlite:test.db",
  }
  local queried, notified = false, nil
  local orig_select, orig_query, orig_notify = vim.ui.select, db.query, vim.notify
  vim.ui.select = function(_, opts, callback)
    callback(opts.prompt == "Export scope:" and "All matching rows" or "CSV")
  end
  db.query = function() queried = true; return nil, "must not run" end
  vim.notify = function(msg) notified = msg end
  local ok, err = pcall(view.export_to_clipboard, bufnr)
  vim.ui.select, db.query, vim.notify = orig_select, orig_query, orig_notify
  view._sessions[bufnr] = nil
  if not ok then error(err) end
  eq(queried, false, "oversized clipboard query not run")
  contains(notified, "100,000", "cap explained")
end)

test("all-row export above 10000 requires confirmation before querying", function()
  local session = {
    state = { columns = { "id" }, rows = { { "1" } } },
    query_spec = query.new_table("users", 100), total_rows = 10001, url = "sqlite:test.db",
  }
  local queried, delivered = false, false
  local orig_select, orig_query, orig_confirm = vim.ui.select, db.query, ui.confirm
  vim.ui.select = function(_, _, callback) callback("All matching rows") end
  db.query = function() queried = true; return { columns = {}, rows = {} } end
  ui.confirm = function() return false end
  local ok, err = pcall(view._request_export_rows, session, "file", function() delivered = true end)
  vim.ui.select, db.query, ui.confirm = orig_select, orig_query, orig_confirm
  if not ok then error(err) end
  eq(queried, false, "query waits for confirmation")
  eq(delivered, false, "cancel returns no export")
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nexport_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
