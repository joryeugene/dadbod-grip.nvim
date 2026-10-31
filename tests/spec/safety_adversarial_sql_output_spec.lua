-- Public copy/export paths must carry original typed values into SQL output.
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local view = require("dadbod-grip.view")
local oracle = "SELECT id,typeof(payload),hex(payload),typeof(n),n,typeof(r),printf('%!.26g',r) FROM t ORDER BY id"
for _, scope in ipairs({ "Current page", "All matching rows" }) do
  H.test("X01 typed SQL export roundtrips " .. scope, function(c)
    c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT,n,r);"
      .. "INSERT INTO t VALUES(1,X'0041FF',9007199254740993,1.2345678901234567),"
      .. "(2,'NULL',7.5,5e-324)")
    local before = c.rows(oracle)
    local buf = c.open("SELECT * FROM t ORDER BY id DESC")
    local select = vim.ui.select
    vim.ui.select = function(_, opts, callback)
      callback(opts.prompt == "Export scope:" and scope or "SQL INSERT")
    end
    local ok, err = pcall(view.export_to_clipboard, buf)
    vim.ui.select = select
    assert(ok, err)
    local output = vim.fn.getreg("+")
    assert(output:find("INSERT INTO", 1, true), "public export did not generate SQL")
    H.eq(c.rows(oracle), before, "export must not mutate the source")
    c.exec("DELETE FROM t")
    c.exec(output)
    H.eq(c.rows(oracle), before, "SQL output changed cell bytes, numeric precision, or storage type")
  end)
end
H.test("X02 public copied clone SQL retains typed source values", function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT,n,r);"
    .. "INSERT INTO t VALUES(1,X'0041FF',9007199254740993,1.2345678901234567)")
  local before = c.rows(oracle)
  local buf, session = c.open("t")
  session.on_clone(buf, 1)
  c.action("grid_copy_sql")
  H.eq(c.rows(oracle), before, "copy only stages and formats")
  c.exec(vim.fn.getreg("+"))
  local after = c.rows(oracle)
  local cloned = vim.deepcopy(before[1]); cloned[1] = "2"
  H.eq(after, { before[1], cloned }, "copied SQL differs from typed forward Apply")
end)
H.finish("safety_adversarial_sql_output_spec")
