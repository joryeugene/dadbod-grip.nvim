-- Additive actual native SQLite controls; the scalar extension is our fixture.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local db, adapters = require("dadbod-grip.db"), require("dadbod-grip.adapters")
local function scalar_query(c, statement)
  assert(vim.fn.executable("cc") == 1, "native scalar fixture needs existing C compiler")
  local lib, counter = c.root .. "/volatile.so", c.root .. "/counter"
  local build = vim.system({ "cc", "-shared", "-fPIC", "tests/fixtures/safety_sqlite_volatile.c", "-o", lib }):wait()
  assert(build.code == 0, build.stderr)
  local original = adapters.run_cmd
  adapters.run_cmd = function(argv, timeout, opts)
    if argv[1] == "sqlite3" and opts and opts.stdin and opts.stdin:find("grip_review_value", 1, true) then
      argv = vim.deepcopy(argv)
      table.insert(argv, #argv, "-cmd")
      table.insert(argv, #argv, '.load "' .. lib .. '"')
      opts = vim.tbl_extend("force", opts, { env = vim.tbl_extend("force", opts.env or {},
        { GRIP_REVIEW_COUNTER_FILE = counter }) })
    end
    return original(argv, timeout, opts)
  end
  local ok, result, err = pcall(db.query, statement, c.url)
  adapters.run_cmd = original
  assert(ok, result)
  local count = vim.fn.filereadable(counter) == 1 and #table.concat(vim.fn.readfile(counter, "b")) or 0
  return result, err, count
end
H.test("S01 volatile SQLite projection is evaluated once before cell encoding", function(c)
  c.exec("CREATE TABLE source(id INTEGER PRIMARY KEY); INSERT INTO source VALUES(1)")
  local result, err, count = scalar_query(c, "SELECT grip_review_value() AS value FROM source")
  assert(result, err)
  H.eq(count, 1, "original expression was evaluated more than once")
  H.eq(result.rows, { { "AB" } })
  H.eq(result.cell_types, { { "blob" } }, "receipt must describe the value actually evaluated")
end)
for _, encoding in ipairs({ "UTF-16le", "UTF-16be" }) do
  H.test("S02 " .. encoding .. " is exact or refused before read and mutation", function(c)
    local path = c.url:sub(#"sqlite:" + 1)
    local function raw(statement)
      local r = vim.system({ "sqlite3", "-batch", "-noheader", path }, { stdin = statement, text = true }):wait()
      assert(r.code == 0, r.stderr)
      return (r.stdout:gsub("\n$", ""))
    end
    raw("PRAGMA encoding='" .. encoding .. "'; CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT); INSERT INTO t VALUES(1,'A');")
    H.eq(raw("PRAGMA encoding"), encoding)
    local oracle = "SELECT id,typeof(payload),hex(CAST(payload AS BLOB)) FROM t ORDER BY id"
    local before = raw(oracle)
    local result, err, count = scalar_query(c, "SELECT id,payload,grip_review_value() AS probe FROM t")
    if not result then
      assert(tostring(err):lower():find("encod", 1, true) or tostring(err):lower():find("utf", 1, true),
        "unsupported database encoding must be explicit")
      H.eq(raw(oracle), before)
      H.eq(count, 0, "unsupported encoding was refused after original evaluation")
      print("CONTAINED: " .. encoding .. " refused before original read; no UTF16 support claimed")
      return
    end
    H.eq(result.rows, { { "1", "A", "AB" } }, "database-encoded bytes are not UTF8 cell values")
    H.eq(count, 1, "supported encoding must evaluate original once")
    local buf, session = c.open("t")
    session.on_delete(buf, 1)
    c.action("grid_apply")
    H.eq(raw("SELECT count(*) FROM t"), "0")
    c.action("grid_undo")
    H.eq(raw(oracle), before, "committed DELETE needs an executable exact reversal")
  end)
end
H.finish("safety_adversarial_sqlite_read_spec")
