local db = require("dadbod-grip.db")
local demo = require("dadbod-grip.demo")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

local function eq(actual, expected, message)
  assert(actual == expected,
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local root = vim.fn.getcwd()
local function with_spec(spec, fn)
  local real = demo.spec
  demo.spec = function() return spec end
  local ok, err = pcall(fn)
  demo.spec = real
  if not ok then error(err) end
end

local function sql_blocks()
  local blocks, current = {}, nil
  for _, line in ipairs(vim.fn.readfile(root .. "/demo/softrear-internal.md")) do
    if line == "```sql" then
      current = {}
    elseif line == "```" and current then
      blocks[#blocks + 1] = table.concat(current, "\n")
      current = nil
    elseif current then
      current[#current + 1] = line
    end
  end
  return blocks
end

test("SQLite fallback seeds cleanly and runs every non-federated notebook query", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local spec = {
    kind = "sqlite",
    path = dir .. "/softrear.db",
    url = "sqlite:" .. dir .. "/softrear.db",
    seed = root .. "/demo/softrear_sqlite.sql",
    supplier_path = dir .. "/supplier.db",
  }
  local blocks = sql_blocks()
  with_spec(spec, function()
    local prepared, err = demo.prepare(true)
    assert(prepared, err)
    local counts = assert(db.query(
      "SELECT COUNT(*) AS rolls, (SELECT COUNT(*) FROM youtube_comments "
        .. "WHERE conspiracy_adjacent IS NULL) AS unreviewed FROM rolls", spec.url))
    eq(tonumber(counts.rows[1][1]), 35, "compact roll count")
    eq(tonumber(counts.rows[1][2]), 2, "compact unreviewed count")
    for index = 1, 12 do
      local result, query_err = db.query(blocks[index], spec.url)
      assert(result and #result.rows > 0,
        string.format("SQLite notebook block %d failed: %s", index, query_err or "empty"))
    end
  end)
  vim.fn.delete(dir, "rf")
end)

test("a failing database client leaves no partial demo or workspace", function()
  local dir = vim.fn.tempname()
  local bin = dir .. "/bin"
  vim.fn.mkdir(bin, "p")
  local client = bin .. "/sqlite3"
  vim.fn.writefile({
    "#!/bin/sh",
    "for last do :; done",
    "printf partial > \"$last\"",
    "/bin/cat >/dev/null",
    "echo 'fake seed failure' >&2",
    "exit 7",
  }, client)
  vim.fn.setfperm(client, "rwx------")

  local result = vim.system({
    vim.g.grip_test_progpath,
    "--headless", "-u", "NONE",
    "--cmd", "set rtp^=" .. vim.fn.fnameescape(root),
    "-l", root .. "/tests/fixtures/demo_failure_integration.lua",
  }, {
    cwd = dir,
    text = true,
    env = {
      PATH = bin,
      XDG_DATA_HOME = dir .. "/data",
      XDG_CONFIG_HOME = dir .. "/config",
    },
  }):wait()
  local output = (result.stdout or "") .. (result.stderr or "")
  vim.fn.delete(dir, "rf")
  assert(result.code == 0, output)
end)

test("real GripStart is isolated, complete, and executes the walkthrough", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local result = vim.system({
    vim.g.grip_test_progpath,
    "--headless", "-u", "NONE",
    "--cmd", "set rtp^=" .. vim.fn.fnameescape(root),
    "-l", root .. "/tests/fixtures/demo_start_integration.lua",
  }, {
    cwd = dir,
    text = true,
    env = {
      XDG_DATA_HOME = dir .. "/data",
      XDG_CONFIG_HOME = dir .. "/config",
      GRIP_REPO_ROOT = root,
      GRIP_REQUIRE_DUCKDB = vim.env.GRIP_REQUIRE_DUCKDB or "",
    },
  }):wait()
  local output = (result.stdout or "") .. (result.stderr or "")
  vim.fn.delete(dir, "rf")
  assert(result.code == 0, output)
end)

print(string.format("\ndemo_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
