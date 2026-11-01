-- Shared lexer boundaries must remain strict outside completion.
local tokenize = require("dadbod-grip.sql_tokens").tokenize
local pass, fail = 0, 0
local function test(name, run)
  local ok, err = pcall(run)
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

for _, comment in ipairs({ "/*+ \\q */", "/*+ SET_VAR(x=1) \\x */", "/*+ hint\n\\C utf8\n*/" }) do
  test("MySQL hint client commands cannot be discarded: " .. comment, function()
    local text = "UPDATE " .. comment .. "items SET value='x' WHERE id=2"
    for _, mode in ipairs({ false, true }) do
      assert(tokenize(text, "mysql", mode, true) == nil, "client command hidden by a hint")
    end
  end)
end

for _, comment in ipairs({ "/*+ MAX_EXECUTION_TIME(1000) */", "/* ordinary \\q comment */" }) do
  test("MySQL inert comment stays usable: " .. comment, function()
    local text = "UPDATE " .. comment .. "items SET value='x' WHERE id=2"
    for _, mode in ipairs({ false, true }) do
      assert(tokenize(text, "mysql", mode), "valid hint or ordinary comment rejected")
    end
  end)
end

print(string.format("\nsql_tokens_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
