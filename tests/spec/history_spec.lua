-- history_spec.lua -- unit tests for query history
local history = require("dadbod-grip.history")

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

-- ── mock helpers ────────────────────────────────────────────────────────────

local mock_store = {}

local function setup_mock()
  mock_store = {}
  local orig_read = history._read_all
  local orig_write = history._write_all
  local orig_notify = vim.notify
  history._read_all = function() return mock_store end
  history._write_all = function(data) mock_store = data end
  vim.notify = function() end
  return function()
    history._read_all = orig_read
    history._write_all = orig_write
    vim.notify = orig_notify
  end
end

local function with_mock(fn)
  local teardown = setup_mock()
  local ok, err = pcall(fn)
  teardown()
  if not ok then error(err) end
end

-- ── _redact_url ─────────────────────────────────────────────────────────────

test("_redact_url: strips password from postgresql URL", function()
  local result = history._redact_url("postgresql://myuser:s3cret@localhost/grip_test")
  eq(result, "postgresql://myuser:***@localhost/grip_test", "password redacted")
end)

test("_redact_url: strips password from mysql URL", function()
  local result = history._redact_url("mysql://root:hunter2@127.0.0.1:3306/testdb")
  eq(result, "mysql://root:***@127.0.0.1:3306/testdb", "password redacted")
end)

test("_redact_url: handles password with @ in it (greedy last-@)", function()
  local result = history._redact_url("mysql://user:p@ss@host/db")
  -- gsub matches first colon-to-@ segment
  contains(result, "***@", "should have redacted portion")
end)

test("_redact_url: no-op for sqlite URL (no auth)", function()
  local result = history._redact_url("sqlite:tests/seed_sqlite.db")
  eq(result, "sqlite:tests/seed_sqlite.db", "unchanged")
end)

test("_redact_url: no-op for duckdb memory URL", function()
  local result = history._redact_url("duckdb::memory:")
  eq(result, "duckdb::memory:", "unchanged")
end)

test("_redact_url: nil input returns empty string", function()
  eq(history._redact_url(nil), "", "nil becomes empty")
end)

-- ── record ──────────────────────────────────────────────────────────────────

test("record: stores entry with correct fields", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "sqlite:test.db", table_name = "users", type = "query" })
    eq(#mock_store, 1, "one entry")
    eq(mock_store[1].sql, "SELECT 1", "sql")
    eq(mock_store[1].url, "sqlite:test.db", "url")
    eq(mock_store[1]["table"], "users", "table")
    eq(mock_store[1].type, "query", "type")
    assert(type(mock_store[1].ts) == "number", "ts should be number")
  end)
end)

test("record: consecutive dedup updates timestamp", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    eq(#mock_store, 1, "still one entry")
    assert(mock_store[1].ts > 1000, "timestamp should be updated")
  end)
end)

test("record: non-consecutive identical queries both stored", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" },
      { sql = "SELECT 2", url = "sqlite:x.db", ts = 2000, type = "query" },
    }
    history.record({ sql = "SELECT 1", url = "sqlite:x.db" })
    eq(#mock_store, 3, "three entries (not deduped)")
  end)
end)

test("record: different SQL is not deduped", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 2", url = "sqlite:x.db" })
    eq(#mock_store, 2, "two entries")
  end)
end)

test("record: same SQL different URL is not deduped", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:a.db", ts = 1000, type = "query" }}
    history.record({ sql = "SELECT 1", url = "sqlite:b.db" })
    eq(#mock_store, 2, "two entries")
  end)
end)

test("record: empty SQL is ignored", function()
  with_mock(function()
    history.record({ sql = "", url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for empty SQL")
  end)
end)

test("record: whitespace-only SQL is ignored", function()
  with_mock(function()
    history.record({ sql = "   \n\t  ", url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for whitespace SQL")
  end)
end)

test("record: nil SQL is ignored", function()
  with_mock(function()
    history.record({ url = "sqlite:x.db" })
    eq(#mock_store, 0, "no entry for nil SQL")
  end)
end)

test("record: caps at 500 entries, trims oldest", function()
  with_mock(function()
    for i = 1, 500 do
      table.insert(mock_store, { sql = "Q" .. i, url = "x", ts = i, type = "query" })
    end
    eq(#mock_store, 500, "full")
    history.record({ sql = "Q501", url = "x" })
    eq(#mock_store, 500, "still 500 after cap")
    eq(mock_store[1].sql, "Q2", "oldest trimmed (Q1 gone)")
    eq(mock_store[500].sql, "Q501", "newest is last")
  end)
end)

test("record: redacts password in stored URL", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "postgresql://user:secret@host/db" })
    eq(mock_store[1].url, "postgresql://user:***@host/db", "password redacted")
  end)
end)

test("record: defaults type to query", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "x" })
    eq(mock_store[1].type, "query", "default type")
  end)
end)

-- ── list ────────────────────────────────────────────────────────────────────

test("list: returns newest first", function()
  with_mock(function()
    mock_store = {
      { sql = "first", url = "x", ts = 1, type = "query" },
      { sql = "second", url = "x", ts = 2, type = "query" },
      { sql = "third", url = "x", ts = 3, type = "query" },
    }
    local result = history.list()
    eq(result[1].sql, "third", "newest first")
    eq(result[3].sql, "first", "oldest last")
  end)
end)

test("list: respects limit parameter", function()
  with_mock(function()
    mock_store = {
      { sql = "Q1", url = "x", ts = 1, type = "query" },
      { sql = "Q2", url = "x", ts = 2, type = "query" },
      { sql = "Q3", url = "x", ts = 3, type = "query" },
    }
    local result = history.list(2)
    eq(#result, 2, "limited to 2")
    eq(result[1].sql, "Q3", "newest first")
    eq(result[2].sql, "Q2", "second newest")
  end)
end)

test("list: empty history returns empty", function()
  with_mock(function()
    local result = history.list()
    eq(#result, 0, "empty")
  end)
end)

-- ── clear ───────────────────────────────────────────────────────────────────

test("clear: removes all entries", function()
  with_mock(function()
    mock_store = {
      { sql = "Q1", url = "x", ts = 1, type = "query" },
      { sql = "Q2", url = "x", ts = 2, type = "query" },
    }
    history.clear()
    eq(#mock_store, 0, "empty after clear")
  end)
end)

-- ── round-trip ──────────────────────────────────────────────────────────────

test("round-trip: record then list returns same data", function()
  with_mock(function()
    history.record({ sql = "SELECT * FROM users", url = "sqlite:test.db", table_name = "users", type = "query" })
    history.record({ sql = "DELETE FROM orders WHERE id = 1", url = "sqlite:test.db", type = "dml" })
    local result = history.list()
    eq(#result, 2, "two entries")
    eq(result[1].sql, "DELETE FROM orders WHERE id = 1", "newest first")
    eq(result[1].type, "dml", "type preserved")
    eq(result[2].sql, "SELECT * FROM users", "oldest second")
    eq(result[2]["table"], "users", "table preserved")
  end)
end)

-- ── elapsed_ms ────────────────────────────────────────────────────────────────

test("record: stores elapsed_ms field", function()
  with_mock(function()
    history.record({ sql = "SELECT 1", url = "sqlite:x.db", elapsed_ms = 42 })
    eq(mock_store[1].elapsed_ms, 42, "elapsed_ms stored")
  end)
end)

test("record: elapsed_ms preserved through dedup", function()
  with_mock(function()
    mock_store = {{ sql = "SELECT 1", url = "sqlite:x.db", ts = 1000, type = "query", elapsed_ms = 100 }}
    history.record({ sql = "SELECT 1", url = "sqlite:x.db", elapsed_ms = 50 })
    eq(#mock_store, 1, "still one entry")
    eq(mock_store[1].elapsed_ms, 50, "elapsed_ms updated to latest")
  end)
end)

-- ── get_for_table ────────────────────────────────────────────────────────────

test("get_for_table: returns entries matching by table field", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "SELECT * FROM orders", url = "x", ts = 2, type = "query", ["table"] = "orders" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "one match")
    eq(result[1]["table"], "users", "correct entry returned")
  end)
end)

test("get_for_table: returns entries matching by sql content", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT name FROM users WHERE id = 1", url = "x", ts = 1, type = "query" },
      { sql = "SELECT * FROM orders", url = "x", ts = 2, type = "query" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "one match by sql")
    contains(result[1].sql, "users", "sql contains table name")
  end)
end)

test("get_for_table: returns newest first", function()
  with_mock(function()
    mock_store = {
      { sql = "old users query", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "new users query", url = "x", ts = 2, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("users")
    eq(result[1].sql, "new users query", "newest first")
    eq(result[2].sql, "old users query", "oldest second")
  end)
end)

test("get_for_table: respects limit parameter", function()
  with_mock(function()
    mock_store = {
      { sql = "q1 users", url = "x", ts = 1, type = "query", ["table"] = "users" },
      { sql = "q2 users", url = "x", ts = 2, type = "query", ["table"] = "users" },
      { sql = "q3 users", url = "x", ts = 3, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("users", 2)
    eq(#result, 2, "limited to 2")
    eq(result[1].sql, "q3 users", "newest first within limit")
  end)
end)

test("get_for_table: returns empty for nil table_name", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table(nil)
    eq(#result, 0, "empty for nil")
  end)
end)

test("get_for_table: returns empty for empty table_name", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM users", url = "x", ts = 1, type = "query", ["table"] = "users" },
    }
    local result = history.get_for_table("")
    eq(#result, 0, "empty for empty string")
  end)
end)

test("get_for_table: does not return unrelated entries", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM orders", url = "x", ts = 1, type = "query", ["table"] = "orders" },
      { sql = "DELETE FROM products WHERE id = 5", url = "x", ts = 2, type = "dml" },
    }
    local result = history.get_for_table("users")
    eq(#result, 0, "no matches for unrelated table")
  end)
end)

test("get_for_table: sql match is case-insensitive", function()
  with_mock(function()
    mock_store = {
      { sql = "SELECT * FROM Users WHERE active = 1", url = "x", ts = 1, type = "query" },
    }
    local result = history.get_for_table("users")
    eq(#result, 1, "case-insensitive sql match")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nhistory_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
