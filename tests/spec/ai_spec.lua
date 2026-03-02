-- ai_spec.lua -- unit tests for AI SQL generation module
local ai = require("dadbod-grip.ai")

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

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

-- ── resolve_api_key ──────────────────────────────────────────────────────────

test("resolve_api_key: direct string passed through", function()
  ai.setup({ api_key = "test-key-123" })
  local key = ai.resolve_api_key("openai")
  eq(key, "test-key-123", "direct key")
  ai.setup({}) -- reset
end)

test("resolve_api_key: env: prefix reads named var", function()
  -- Set a test env var
  vim.env.GRIP_TEST_KEY = "from-env"
  ai.setup({ api_key = "env:GRIP_TEST_KEY" })
  local key = ai.resolve_api_key("openai")
  eq(key, "from-env", "env key")
  ai.setup({})
  vim.env.GRIP_TEST_KEY = nil
end)

test("resolve_api_key: returns nil for unknown provider", function()
  local key, err = ai.resolve_api_key("nonexistent")
  assert(key == nil, "should be nil")
  contains(err, "Unknown provider", "error message")
end)

test("resolve_api_key: ollama returns empty string (no key needed)", function()
  ai.setup({})
  local key = ai.resolve_api_key("ollama")
  eq(key, "", "ollama needs no key")
end)

-- ── resolve_provider ─────────────────────────────────────────────────────────

test("resolve_provider: explicit config wins", function()
  ai.setup({ provider = "gemini" })
  eq(ai.resolve_provider(), "gemini", "explicit provider")
  ai.setup({})
end)

test("resolve_provider: auto-detect from env", function()
  ai.setup({})
  -- Without any env vars set, should fall back to ollama
  local saved_a = os.getenv("ANTHROPIC_API_KEY")
  local saved_o = os.getenv("OPENAI_API_KEY")
  local saved_g = os.getenv("GEMINI_API_KEY")

  -- Clear all
  vim.env.ANTHROPIC_API_KEY = nil
  vim.env.OPENAI_API_KEY = nil
  vim.env.GEMINI_API_KEY = nil

  eq(ai.resolve_provider(), "ollama", "fallback to ollama")

  -- Restore
  if saved_a then vim.env.ANTHROPIC_API_KEY = saved_a end
  if saved_o then vim.env.OPENAI_API_KEY = saved_o end
  if saved_g then vim.env.GEMINI_API_KEY = saved_g end
end)

test("resolve_provider: anthropic first when available", function()
  ai.setup({})
  local saved = os.getenv("ANTHROPIC_API_KEY")
  vim.env.ANTHROPIC_API_KEY = "test"
  eq(ai.resolve_provider(), "anthropic", "anthropic detected first")
  if saved then vim.env.ANTHROPIC_API_KEY = saved
  else vim.env.ANTHROPIC_API_KEY = nil end
end)

-- ── _format_ddl_line ─────────────────────────────────────────────────────────

test("_format_ddl_line: basic columns", function()
  local cols = {
    { column_name = "id", data_type = "integer", is_nullable = "NO" },
    { column_name = "name", data_type = "text", is_nullable = "YES" },
  }
  local result = ai._format_ddl_line("users", cols, {"id"}, {})
  contains(result, "CREATE TABLE users", "table name")
  contains(result, "id integer PK", "PK marker")
  contains(result, "name text", "column type")
end)

test("_format_ddl_line: FK markers (test-style field names)", function()
  local cols = {
    { column_name = "id", data_type = "integer", is_nullable = "NO" },
    { column_name = "org_id", data_type = "integer", is_nullable = "YES" },
  }
  local fks = {{ column_name = "org_id", foreign_table_name = "orgs", foreign_column_name = "id" }}
  local result = ai._format_ddl_line("users", cols, {"id"}, fks)
  contains(result, "FK->orgs.id", "FK marker")
end)

test("_format_ddl_line: FK markers (adapter-style field names)", function()
  local cols = {
    { column_name = "id", data_type = "integer", is_nullable = "NO" },
    { column_name = "user_id", data_type = "integer", is_nullable = "YES" },
  }
  -- Adapters return { column, ref_table, ref_column } not { column_name, foreign_table_name, foreign_column_name }
  local fks = {{ column = "user_id", ref_table = "users", ref_column = "id" }}
  local result = ai._format_ddl_line("orders", cols, {"id"}, fks)
  contains(result, "FK->users.id", "FK marker with adapter field names")
end)

test("_format_ddl_line: NOT NULL markers", function()
  local cols = {
    { column_name = "id", data_type = "integer", is_nullable = "NO" },
    { column_name = "email", data_type = "text", is_nullable = "NO" },
  }
  local result = ai._format_ddl_line("users", cols, {"id"}, {})
  -- id is PK so NOT NULL not shown, email is NOT NULL
  contains(result, "email text NOT NULL", "NOT NULL")
  assert(not result:find("id integer PK NOT NULL"), "PK should not also say NOT NULL")
end)

-- ── _strip_fences ────────────────────────────────────────────────────────────

test("_strip_fences: removes sql code fences", function()
  local result = ai._strip_fences("```sql\nSELECT * FROM users\n```")
  eq(result, "SELECT * FROM users", "fences removed")
end)

test("_strip_fences: removes plain code fences", function()
  local result = ai._strip_fences("```\nSELECT 1\n```")
  eq(result, "SELECT 1", "plain fences removed")
end)

test("_strip_fences: no-op on clean SQL", function()
  local result = ai._strip_fences("SELECT * FROM users WHERE id = 1")
  eq(result, "SELECT * FROM users WHERE id = 1", "unchanged")
end)

test("_strip_fences: handles nil", function()
  eq(ai._strip_fences(nil), "", "nil returns empty")
end)

test("_strip_fences: extracts SQL from chatty response", function()
  local chatty = "I need to see the schema for the users table.\n\nHowever, based on common conventions:\n\nSELECT * FROM users WHERE age IS NOT NULL ORDER BY age ASC LIMIT 1\n\nPlease share the actual schema."
  local result = ai._strip_fences(chatty)
  contains(result, "SELECT * FROM users", "SQL extracted from prose")
  assert(not result:find("schema"), "prose stripped")
end)

test("_strip_fences: extracts SQL from code block in prose", function()
  local mixed = "Here is the query:\n\n```sql\nSELECT * FROM users LIMIT 5\n```\n\nThis will return 5 rows."
  local result = ai._strip_fences(mixed)
  eq(result, "SELECT * FROM users LIMIT 5", "SQL extracted from fenced block in prose")
end)

-- ── setup ────────────────────────────────────────────────────────────────────

test("setup: stores config", function()
  ai.setup({ provider = "anthropic", model = "test-model" })
  eq(ai.resolve_provider(), "anthropic", "provider stored")
  ai.setup({})
end)

test("setup: defaults provider to nil (auto-detect)", function()
  ai.setup({})
  -- Will auto-detect or fall back to ollama
  local p = ai.resolve_provider()
  assert(type(p) == "string", "provider is string")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nai_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
