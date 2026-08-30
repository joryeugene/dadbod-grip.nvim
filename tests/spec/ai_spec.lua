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

test("resolve_api_key: cmd script is delivered through stdin", function()
  local orig_system = vim.system
  local captured_args, captured_opts
  vim.system = function(args, opts)
    captured_args, captured_opts = args, opts
    return { wait = function() return { code = 0, stdout = "from-command\n" } end }
  end
  ai.setup({ api_key = "cmd:printf from-command" })
  local ok, key = pcall(ai.resolve_api_key, "openai")
  ai.setup({})
  vim.system = orig_system

  assert(ok, key)
  eq(key, "from-command", "command output")
  eq(vim.inspect(captured_args), vim.inspect({ "sh", "-s" }), "constant shell argv")
  eq(captured_opts.stdin, "printf from-command\n", "script on stdin")
end)

test("resolve_api_key: failed cmd does not reproduce the command", function()
  local orig_system = vim.system
  vim.system = function()
    return { wait = function() return { code = 1, stdout = "", stderr = "failed" } end }
  end
  local secret_command = "printf command_secret_7f3c"
  ai.setup({ api_key = "cmd:" .. secret_command })
  local key, err = ai.resolve_api_key("openai")
  ai.setup({})
  vim.system = orig_system

  eq(key, nil, "no key")
  contains(err, "API key command failed", "actionable error")
  assert(not err:find(secret_command, 1, true), "failed key command leaked into its error")
end)

test("resolve_api_key: cmd spawn failure is returned without reproducing the command", function()
  local orig_system = vim.system
  local secret_command = "printf spawn_secret_7f3c"
  vim.system = function() error("ENOENT " .. secret_command) end
  ai.setup({ api_key = "cmd:" .. secret_command })
  local ok, key, err = pcall(ai.resolve_api_key, "openai")
  ai.setup({})
  vim.system = orig_system

  assert(ok, key)
  eq(key, nil, "no key")
  eq(err, "API key command failed", "safe spawn failure")
  assert(not err:find(secret_command, 1, true), "spawn failure leaked the key command")
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
  eq(result, "CREATE TABLE users (id integer PK, name text);",
    "complete DDL has one PK marker")
end)

test("curl config quoting: escapes only curl's documented quoted-string controls", function()
  eq(ai._curl_config_quote('a\\b"c\t\n\r\v'), '"a\\\\b\\"c\\t\\n\\r\\v"',
    "curl config quoted string")
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

-- ── build_schema_context: get_schema_batch integration ──────────────────────
-- Regression guard for the batch/per-table split: tables served by
-- get_schema_batch must skip get_column_info entirely (that's the whole point
-- of batching -- one CLI spawn instead of one per table), and any table the
-- batch doesn't cover must still get its columns via the old per-table call
-- so nothing silently disappears from the AI prompt.

local db = require("dadbod-grip.db")

local function mock_ai_db(list, batch, opts)
  opts = opts or {}
  local orig_list  = db.list_tables
  local orig_batch = db.get_schema_batch
  local orig_cols  = db.get_column_info
  local orig_pks   = db.get_primary_keys
  local orig_fks   = db.get_foreign_keys

  db.list_tables = function(_) return list, nil end
  db.get_schema_batch = function(_)
    if opts.batch_throws then error("adapter blew up inside get_schema_batch") end
    return batch
  end
  db.get_column_info = function(tbl, _)
    if opts.fail_on_get_column_info then
      error("get_column_info must not be called for '" .. tbl .. "' -- batch already served it")
    end
    return (opts.fallback_cols or {})[tbl]
  end
  db.get_primary_keys = function(_, _) return {} end
  db.get_foreign_keys = function(_, _) return {} end

  return function()
    db.list_tables      = orig_list
    db.get_schema_batch  = orig_batch
    db.get_column_info  = orig_cols
    db.get_primary_keys = orig_pks
    db.get_foreign_keys = orig_fks
  end
end

test("build_schema_context: batch-served tables skip get_column_info", function()
  local restore = mock_ai_db(
    { { name = "users" }, { name = "orders" } },
    {
      users  = { { column_name = "id", data_type = "integer", is_nullable = "NO" } },
      orders = { { column_name = "id", data_type = "integer", is_nullable = "NO" } },
    },
    { fail_on_get_column_info = true }
  )
  local ok_call, ddl = pcall(ai.build_schema_context, "test://batch-only", "")
  restore()
  assert(ok_call, "build_schema_context must not call get_column_info when batch covers every table: " .. tostring(ddl))
  contains(ddl, "CREATE TABLE users", "users table present")
  contains(ddl, "CREATE TABLE orders", "orders table present")
end)

test("build_schema_context: table missing from batch falls back to get_column_info", function()
  local restore = mock_ai_db(
    { { name = "users" }, { name = "legacy" } },
    { users = { { column_name = "id", data_type = "integer", is_nullable = "NO" } } },  -- "legacy" absent from batch
    { fallback_cols = { legacy = { { column_name = "old_id", data_type = "text", is_nullable = "YES" } } } }
  )
  local ok_call, ddl = pcall(ai.build_schema_context, "test://batch-partial", "")
  restore()
  assert(ok_call, "build_schema_context must not error: " .. tostring(ddl))
  contains(ddl, "CREATE TABLE users", "users from batch present")
  contains(ddl, "CREATE TABLE legacy", "legacy table present via per-table fallback")
  contains(ddl, "old_id", "legacy column present via fallback")
end)

test("build_schema_context: adapter without batch support falls back entirely", function()
  local restore = mock_ai_db(
    { { name = "users" } },
    nil,  -- adapter has no get_schema_batch / it errored -- same as today's behavior
    { fallback_cols = { users = { { column_name = "id", data_type = "integer", is_nullable = "NO" } } } }
  )
  local ok_call, ddl = pcall(ai.build_schema_context, "test://no-batch", "")
  restore()
  assert(ok_call, "build_schema_context must not error: " .. tostring(ddl))
  contains(ddl, "CREATE TABLE users", "users table present via full fallback")
end)

test("build_schema_context: table present in batch but with zero columns still falls back", function()
  -- {} is truthy in Lua -- a naive "batch_cols[tbl] or get_column_info(...)" would
  -- treat an empty-but-present batch entry as "already resolved" and drop the table.
  local restore = mock_ai_db(
    { { name = "users" } },
    { users = {} },  -- present in batch, but batch resolved zero columns for it
    { fallback_cols = { users = { { column_name = "id", data_type = "integer", is_nullable = "NO" } } } }
  )
  local ok_call, ddl = pcall(ai.build_schema_context, "test://batch-empty-cols", "")
  restore()
  assert(ok_call, "build_schema_context must not error: " .. tostring(ddl))
  contains(ddl, "CREATE TABLE users", "users table recovered via fallback despite empty batch entry")
end)

test("build_schema_context: a throwing get_schema_batch degrades to per-table", function()
  -- get_foreign_keys is pcall'd a few lines below for exactly this reason: an
  -- adapter can throw. An unguarded batch call would take the whole prompt down
  -- instead of using the per-table path that is already right there.
  local restore = mock_ai_db(
    { { name = "users" } },
    nil,
    {
      batch_throws = true,
      fallback_cols = { users = { { column_name = "id", data_type = "integer", is_nullable = "NO" } } },
    }
  )
  local ok_call, ddl = pcall(ai.build_schema_context, "test://batch-throws", "")
  restore()
  assert(ok_call, "build_schema_context must survive a throwing batch call: " .. tostring(ddl))
  contains(ddl, "CREATE TABLE users", "users table present via per-table fallback")
end)

test("build_schema_context: zero tables never spawns get_schema_batch", function()
  local orig_list  = db.list_tables
  local orig_batch = db.get_schema_batch
  local batch_called = false

  db.list_tables = function(_) return {}, nil end
  db.get_schema_batch = function(_)
    batch_called = true
    return nil
  end

  local ok_call, ddl = pcall(ai.build_schema_context, "test://zero-tables", "")

  db.list_tables      = orig_list
  db.get_schema_batch  = orig_batch

  assert(ok_call, "build_schema_context must not error: " .. tostring(ddl))
  assert(not batch_called, "get_schema_batch must not be called when there are no tables")
  eq(ddl, "", "no tables means no DDL")
end)

-- ── generate_sql: system prompt pinned byte-for-byte ─────────────────────────
-- The prompt was only ever checked against throwaway snapshots taken while
-- refactoring around it, so any edit to its wording -- a doubled space, a
-- reordered rule, a lost blank line -- could ship silently and quietly change
-- every generated query. generate_sql is driven all the way down to the curl
-- stdin here and the prompt is read back out of the JSON body that would have
-- been POSTed: those are the exact bytes the provider receives.
--
-- Fixture notes: the provider is pinned to anthropic (its build_request puts
-- the system prompt in a `system` field of its own, unmixed with the
-- question), and the URL scheme is deliberately unknown to adapters.display_name
-- so the "SQL"-compatible fallback is pinned too.

--- Capture the system prompt generate_sql would POST, without spawning curl.
--- @return string system prompt, string user message
local function captured_prompt(question, url, existing_sql)
  local restore = mock_ai_db({ { name = "users" } }, {
    users = {
      { column_name = "id",    data_type = "integer", is_nullable = "NO" },
      { column_name = "email", data_type = "text",    is_nullable = "NO" },
    },
  })
  local orig_system = vim.system
  local orig_notify = vim.notify
  local captured_args, captured_opts
  -- post_json passes its own completion callback, which is simply never
  -- invoked: the request is inspected, not answered.
  vim.system = function(args, opts)
    captured_args, captured_opts = args, opts
    return { wait = function() return {} end }
  end
  vim.notify = function() end
  ai.setup({ provider = "anthropic", api_key = "test-key", model = "pinned-model" })

  local cb_err
  local ok, err = pcall(ai.generate_sql, question, url, function(_, e) cb_err = e end, existing_sql)

  ai.setup({})
  vim.system = orig_system
  vim.notify = orig_notify
  restore()

  if not ok then error(err, 0) end
  assert(cb_err == nil, "generate_sql failed before building a request: " .. tostring(cb_err))
  assert(captured_args, "curl was invoked")
  eq(vim.inspect(captured_args),
    vim.inspect({ "curl", "--disable", "--silent", "--show-error", "--config", "-" }),
    "curl argv")
  local config = assert(captured_opts and captured_opts.stdin, "curl config delivered on stdin")
  local quoted = assert(config:match("data%-binary%s*=%s*([^\n]+)"), "request body in curl config")
  local payload = quoted:sub(2, -2):gsub("\\(.)", {
    ['\\'] = '\\', ['"'] = '"', t = "\t", n = "\n", r = "\r", v = "\v",
  })
  local body = vim.fn.json_decode(payload)
  return body.system, body.messages[1].content
end

local EXPECTED_PROMPT = [[
You are a SQL query generator. Output ONLY the raw SQL query. No explanations, no comments, no markdown, no prose, no questions. Do not ask for more information. The complete schema is provided below. Use SQL-compatible SQL.

Rules:
- ONLY use column names that appear in the schema below. Never invent or guess column names.
- When asked about a column that doesn't exist, pick the closest match from the schema.
- 'oldest' or 'earliest' = ORDER BY column ASC. 'newest' or 'latest' = ORDER BY column DESC.
- Filter out NULLs when using ORDER BY, MIN, MAX, or aggregates on nullable columns.
- Use IS NOT NULL in WHERE clauses when sorting to find extremes.
- Use LIMIT for 'top N' or 'oldest/newest' queries.
- Include column aliases for computed columns.

Complete database schema:
CREATE TABLE users (id integer NOT NULL, email text NOT NULL);]]

test("generate_sql: system prompt is byte-identical to the pinned snapshot", function()
  local prompt, user_msg = captured_prompt("oldest user", "test://prompt-snapshot", nil)
  eq(prompt, EXPECTED_PROMPT, "system prompt")
  eq(user_msg, "oldest user", "question is sent verbatim, not folded into the prompt")
end)

test("generate_sql: existing editor query is appended verbatim after the schema", function()
  local prompt = captured_prompt("only active ones", "test://prompt-snapshot-existing", "SELECT * FROM users")
  eq(prompt, EXPECTED_PROMPT .. [[


The user has this existing query in their editor:
SELECT * FROM users

If the user's request relates to modifying this query, return the modified version. Otherwise generate a new query.]],
    "system prompt with the existing-query block")
end)

test("generate_sql: an empty editor query adds nothing to the prompt", function()
  local prompt = captured_prompt("oldest user", "test://prompt-snapshot-empty", "")
  eq(prompt, EXPECTED_PROMPT, "empty existing_sql must not open the existing-query block")
end)

test("generate_sql: transport errors never reproduce request secrets", function()
  local restore = mock_ai_db({ { name = "users" } }, {
    users = { { column_name = "private_schema_value", data_type = "text", is_nullable = "NO" } },
  })
  local orig_system = vim.system
  local orig_notify = vim.notify
  local key = "transport_key_secret_7f3c"
  local question = "transport_prompt_secret_7f3c"
  vim.notify = function() end
  vim.system = function(_, _, callback)
    callback({
      code = 7,
      stdout = "",
      stderr = table.concat({ key, question, "private_schema_value" }, " "),
    })
    return {}
  end
  ai.setup({ provider = "anthropic", api_key = key })
  local callback_done, callback_err = false, nil
  ai.generate_sql(question, "test://safe-transport-error", function(_, err)
    callback_done, callback_err = true, err
  end)
  assert(vim.wait(1000, function() return callback_done end, 1), "transport callback never fired")

  ai.setup({})
  vim.system = orig_system
  vim.notify = orig_notify
  restore()

  contains(callback_err, "curl failed", "transport category retained")
  for _, secret in ipairs({ key, question, "private_schema_value" }) do
    assert(not callback_err:find(secret, 1, true), "transport error leaked " .. secret)
  end
end)

test("generate_sql: curl spawn failures are delivered safely through the callback", function()
  local restore = mock_ai_db({}, nil)
  local orig_system = vim.system
  local orig_notify = vim.notify
  local spawn_secret = "spawn_error_request_secret_7f3c"
  vim.notify = function() end
  vim.system = function()
    error("ENOENT " .. spawn_secret)
  end
  ai.setup({ provider = "anthropic", api_key = "test-key" })
  local callback_done, callback_err = false, nil
  local ok, thrown = pcall(ai.generate_sql, "question", "test://safe-spawn-error", function(_, err)
    callback_done, callback_err = true, err
  end)
  assert(vim.wait(1000, function() return callback_done end, 1), "spawn-failure callback never fired")

  ai.setup({})
  vim.system = orig_system
  vim.notify = orig_notify
  restore()

  assert(ok, thrown)
  eq(callback_err, "Could not start curl", "safe spawn failure")
  assert(not callback_err:find(spawn_secret, 1, true), "spawn failure leaked process error")
end)

test("generate_sql: API errors retain a safe type without reproducing the remote message", function()
  local restore = mock_ai_db({}, nil)
  local orig_system = vim.system
  local orig_notify = vim.notify
  local remote_secret = "remote_error_echoed_request_secret_7f3c"
  vim.notify = function() end
  vim.system = function(_, _, callback)
    callback({
      code = 0,
      stdout = vim.fn.json_encode({
        error = { type = "invalid_request_error", message = remote_secret },
      }),
      stderr = "",
    })
    return {}
  end
  ai.setup({ provider = "anthropic", api_key = "test-key" })
  local callback_done, callback_err = false, nil
  ai.generate_sql("question", "test://safe-api-error", function(_, err)
    callback_done, callback_err = true, err
  end)
  assert(vim.wait(1000, function() return callback_done end, 1), "API error callback never fired")

  ai.setup({})
  vim.system = orig_system
  vim.notify = orig_notify
  restore()

  eq(callback_err, "API error: invalid_request_error", "safe error type")
  assert(not callback_err:find(remote_secret, 1, true), "remote error message leaked request content")
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
