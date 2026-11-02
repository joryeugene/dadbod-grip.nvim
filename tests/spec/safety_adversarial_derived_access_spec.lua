-- Controlled pre-process access boundary. No database/client command runs.
local ok, read = pcall(require, "dadbod-grip.mysql_read")
if not ok or type(read.derived_query) ~= "function" then
  print("safety_adversarial_derived_access_spec: SKIP (gated path unavailable)"); return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local adapters = require("dadbod-grip.adapters")
for _, statement in ipairs({
  "SET SESSION TRANSACTION READ WRITE; UPDATE t SET payload='denied'", "CALL mutate_fixture()",
  "CREATE TABLE denied_fixture(id INTEGER)", "DELETE FROM denied_fixture",
}) do
  H.test("D10 configured RO denies custom mutation before process " .. statement, function()
    local system, previous = vim.system, adapters.set_call_readonly(true)
    local calls = 0
    vim.system = function() calls = calls + 1; error("synthetic process trap; no SQL ran") end
    local success, result, err = pcall(read.derived_query, statement, {
      args = { "mysql", "--batch" }, env = {}, timeout = 1000, readonly = true,
      setup = "SET sql_mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES';\nSET SESSION TRANSACTION READ ONLY;\n",
    })
    vim.system = system
    adapters.set_call_readonly(previous)
    assert(success, result)
    H.eq(result, nil)
    H.eq(calls, 0, "potential mutation/session weakening reached native process")
    assert(type(err) == "string" and (err:lower():find("read.only") or err:lower():find("readonly", 1, true)),
      "access refusal must identify read-only policy")
  end)
end
H.finish("safety_adversarial_derived_access_spec")
