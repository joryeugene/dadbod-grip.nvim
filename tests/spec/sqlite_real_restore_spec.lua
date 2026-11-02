-- The installed SQLite parser must be able to restore its own REAL receipt
-- before a reversible grid mutation is submitted. Old parsers can underflow
-- the smallest subnormal when reading their longer printf representation.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local data = require("dadbod-grip.data")

local function oracle(c)
  return c.rows("SELECT printf('%!.26g',id),typeof(payload),printf('%!.26g',payload),note FROM t ORDER BY id")
end
local function retained(c, session)
  assert(data.has_changes(session.state), "refusal discarded staged work")
  local notices = table.concat(c.notices, "\n")
  assert(not notices:find("Applied ", 1, true), "refusal reported Apply success")
  local shown = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    vim.list_extend(shown, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window), 0, -1, false))
  end
  assert(table.concat(shown, "\n"):find("restore", 1, true), "error window must explain the restoration limit")
end

H.test("mixed delete is exact or entirely refused before an irreversible REAL delete", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload REAL,note TEXT);"
    .. "INSERT INTO t VALUES(1,0.1,'ordinary'),(2,5e-324,'subnormal')")
  local before = oracle(c)
  local buf, session = c.open("t")
  session.on_delete(buf, 1); session.on_delete(buf, 2)
  c.action("grid_apply")
  if c.scalar("SELECT count(*) FROM t") == "2" then
    H.eq(oracle(c), before); retained(c, session); return
  end
  H.eq(c.scalar("SELECT count(*) FROM t"), "0")
  c.action("grid_undo")
  H.eq(oracle(c), before, "one unsafe receipt cannot leave the batch deleted")
end)

H.test("REAL key change is exact or refused with the original identity intact", function(c)
  c.exec("CREATE TABLE t(id REAL PRIMARY KEY,payload REAL,note TEXT);"
    .. "INSERT INTO t VALUES(5e-324,0.1,'original')")
  local before = oracle(c)
  local buf, session = c.open("t")
  c.edit(buf, session, 1, "id", "1.5")
  c.action("grid_apply")
  if vim.deep_equal(oracle(c), before) then retained(c, session); return end
  c.action("grid_undo")
  H.eq(oracle(c), before, "Undo must restore the original REAL key")
end)

H.test("clone preserves the REAL payload or refuses before inserting a rounded value", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload REAL,note TEXT);"
    .. "INSERT INTO t VALUES(1,5e-324,'original')")
  local before = c.rows("SELECT typeof(payload),printf('%!.26g',payload),note FROM t")
  local buf, session = c.open("t")
  session.on_clone(buf, 1); c.action("grid_apply")
  local after = c.rows("SELECT typeof(payload),printf('%!.26g',payload),note FROM t ORDER BY id")
  if #after == 1 then H.eq(after, before); retained(c, session); return end
  H.eq(after, { before[1], before[1] }, "a clone cannot silently underflow")
  c.action("grid_undo")
  H.eq(c.rows("SELECT typeof(payload),printf('%!.26g',payload),note FROM t"), before)
end)

H.test("unprojected REAL values are included in delete restoration admission", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload REAL,note TEXT);"
    .. "INSERT INTO t VALUES(1,5e-324,'original')")
  local before = oracle(c)
  local buf, session = c.open("SELECT id,note FROM t")
  session.on_delete(buf, 1); c.action("grid_apply")
  if c.scalar("SELECT count(*) FROM t") == "1" then H.eq(oracle(c), before); retained(c, session); return end
  c.action("grid_undo")
  H.eq(oracle(c), before, "a hidden REAL column still needs an exact inverse")
end)
H.finish("sqlite_real_restore_spec")
