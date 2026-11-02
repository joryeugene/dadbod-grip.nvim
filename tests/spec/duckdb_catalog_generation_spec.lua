-- A catalog lookup pumps the event loop; attachment/DDL invalidation can run
-- before that lookup returns. Stale completions must not repopulate its cache.
local adapter = require("dadbod-grip.adapters.duckdb")
local pass, fail, serial = 0, 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function eq(a, b, label)
  assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function with_lookup(invalidate, first_fails, fn)
  serial = serial + 1
  local url = "duckdb:/tmp/grip-catalog-generation-" .. serial .. ".duckdb"
  local original, catalogs = vim.system, 0
  vim.system = function(_, opts, callback)
    if opts.stdin:find("FROM duckdb_databases()", 1, true) then
      catalogs = catalogs + 1
      if catalogs == 1 then
        vim.schedule(function()
          if invalidate then invalidate(url) end
          callback({ stdout = "database_name\noldcat\n", stderr = first_fails and "model failure" or "",
            code = first_fails and 1 or 0 })
        end)
      else
        callback({ stdout = "database_name\nnewcat\n", stderr = "", code = 0 })
      end
    else
      callback({ stdout = "column_name,data_type,is_nullable,column_default,constraints\nid,INTEGER,NO,,\n",
        stderr = "", code = 0 })
    end
    return { wait = function() end }
  end
  local ok, err = xpcall(function() fn(url, function() return catalogs end) end, debug.traceback)
  vim.system = original
  if not ok then error(err) end
end

test("attachment changes during a catalog query prevent stale publish", function()
  with_lookup(function(url) adapter._attach_unchecked(url, ":memory:", "changed") end, false,
    function(url, calls)
      assert(adapter.get_column_info("oldcat.items", url))
      assert(adapter.get_column_info("oldcat.items", url))
      eq(calls(), 2, "invalidated in-flight catalog result must not be cached")
      assert(adapter.get_column_info("oldcat.items", url))
      eq(calls(), 2, "fresh generation can cache normally")
    end)
end)

test("explicit schema invalidation prevents in-flight catalog publish", function()
  assert(type(adapter.invalidate_schema) == "function", "missing clear-only adapter hook")
  with_lookup(function(url) adapter.invalidate_schema(url) end, false, function(url, calls)
    assert(adapter.get_column_info("oldcat.items", url))
    assert(adapter.get_column_info("oldcat.items", url))
    eq(calls(), 2)
  end)
end)

test("a failed catalog lookup cannot persist an empty success cache", function()
  with_lookup(nil, true, function(url, calls)
    assert(adapter.get_column_info("oldcat.items", url))
    assert(adapter.get_column_info("oldcat.items", url))
    eq(calls(), 2)
  end)
end)

print(string.format("\nduckdb_catalog_generation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
