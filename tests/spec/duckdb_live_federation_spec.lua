-- Real DuckDB scanner smoke test. PR CI assigns PostgreSQL, MySQL, or MariaDB
-- and makes a missing scanner/server/credential path fail instead of skip.

local REMOTE_URL = vim.env.GRIP_TEST_DUCKDB_FEDERATION_URL
local REQUIRED = vim.env.GRIP_REQUIRE_DUCKDB_FEDERATION == "1"

local function unavailable(reason)
  if REQUIRED then
    error("duckdb_live_federation_spec: " .. reason
      .. " while GRIP_REQUIRE_DUCKDB_FEDERATION=1")
  end
  print("SKIP: duckdb_live_federation_spec (" .. reason .. ")")
  print("\nduckdb_live_federation_spec: 0 passed, 0 failed (skipped)")
end

if not REMOTE_URL or REMOTE_URL == "" then
  unavailable("GRIP_TEST_DUCKDB_FEDERATION_URL not set")
  return
end
if vim.fn.executable("duckdb") ~= 1 then
  unavailable("duckdb CLI not found")
  return
end

local duckdb = require("dadbod-grip.adapters.duckdb")
local duck_url = "duckdb::memory:"
local err = duckdb.attach(duck_url, REMOTE_URL, "live_remote")
if err then error("live attachment failed: " .. err) end

local pass, fail = 0, 0
local function test(name, fn)
  local ok, test_err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(test_err))
  end
end

test("credentialed live attachment can query the seeded database", function()
  local result, query_err = duckdb.query('SELECT COUNT(*) FROM "live_remote"."users"', duck_url)
  assert(result, query_err)
  assert(tonumber(result.rows[1][1]) == 15, vim.inspect(result.rows))
end)

test("live attachment appears in federated schema discovery", function()
  local tables, list_err = duckdb.list_tables(duck_url)
  assert(tables, list_err)
  local found = false
  for _, item in ipairs(tables) do
    if item.name == "live_remote.users" then found = true end
  end
  assert(found, vim.inspect(tables))

  local cols, col_err = duckdb.get_column_info("live_remote.users", duck_url)
  assert(cols, col_err)
  assert(cols[1] and cols[1].column_name == "id", vim.inspect(cols))
end)

duckdb.detach(duck_url, "live_remote")
print(string.format("\nduckdb_live_federation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
