-- init_spec.lua — unit tests for resolve_query routing and is_queryable_file
local grip = require("dadbod-grip")

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. " — " .. tostring(err))
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

test("resolve_query: SELECT returns raw spec", function()
  local spec, tbl = grip._resolve_query("SELECT * FROM orders", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil for raw queries")
end)

test("resolve_query: WITH returns raw spec", function()
  local spec = grip._resolve_query("WITH cte AS (SELECT 1) SELECT * FROM cte", 50)
  assert(spec, "spec should not be nil")
end)

test("resolve_query: TABLE returns raw spec", function()
  local spec = grip._resolve_query("TABLE orders", 50)
  assert(spec, "spec should not be nil")
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
  local spec, tbl = grip._resolve_query("select 1", 50)
  assert(spec, "spec should not be nil")
  eq(tbl, nil, "table_name should be nil")
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

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\ninit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
