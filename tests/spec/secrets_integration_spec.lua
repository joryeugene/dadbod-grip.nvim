-- secrets_integration_spec.lua -- end-to-end tests for ${VAR} expansion.
--
-- secrets_spec.lua covers the parser/expander in isolation. This spec pins
-- the property the design exists for: the *expanded* URL -- the one carrying
-- a live database password -- is created at exactly one place (db.resolve(),
-- the funnel every db.* call goes through) and never reaches any write path.
-- vim.g.db, .grip/connections.json and .grip/history.jsonl all keep the
-- template.
--
-- Everything here runs against real files and a real sqlite3 process
-- (tests/seed_sqlite.db), so "the adapter got an expanded URL" is proved by
-- rows coming back, not by a mock.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")
local db = require("dadbod-grip.db")
local secrets = require("dadbod-grip.secrets")

-- Rebound to a freshly loaded module by every with_real_file() below (see
-- the harness comment) -- same reason as connections_spec.lua: connections
-- keeps per-URL health in a module-local table with no reset hook.
local connections = require("dadbod-grip.connections")

local SEED_DB = vim.fn.fnamemodify("tests/seed_sqlite.db", ":p")

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

-- ── real-file harness ────────────────────────────────────────────────────
-- Lifted from connections_spec.lua's with_real_file(), with one deliberate
-- difference: grip.open is NOT stubbed here, because the history test needs
-- the real query path. Everything else is stubbed/redirected for the same
-- reasons documented there:
-- - paths.project_root is patched (not paths.grip_dir): connections.lua and
--   history.lua capture grip_dir at require time, but the captured function
--   still calls M.project_root() dynamically, so patching project_root
--   reaches both .grip/connections.json and .grip/history.jsonl.
-- - vim.fn.expand("~") is patched to a fake home so the global connections
--   file used by tests never touches the real ~/.grip/connections.json.
-- - the module under test is reloaded per call so its module-local state
--   starts empty; the file-level `connections` alias is rebound to it.
-- Pending vim.schedule callbacks are flushed *before* teardown, while the
-- stubs and fake dirs are still live.
local function with_real_file(fn)
  local project_dir = vim.fn.tempname() .. "_grip_secrets_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_opts = grip.get_opts()
  local orig_open_welcome = grip.open_welcome
  local orig_schema = package.loaded["dadbod-grip.schema"]
  local orig_query_pad = package.loaded["dadbod-grip.query_pad"]
  local orig_completion = package.loaded["dadbod-grip.completion"]
  local orig_connections = package.loaded["dadbod-grip.connections"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({}) -- deterministic OPTS baseline (connections_path = nil, etc.)
  grip.open_welcome = function() end
  package.loaded["dadbod-grip.schema"] = {
    is_open = function() return true end,
    refresh = function() end,
    toggle = function() end,
    get_winid = function() return nil end,
    -- view.lua asks the sidebar where to place the grid.
    get_right_win = function() return nil end,
  }
  package.loaded["dadbod-grip.query_pad"] = { open = function() end, sync_query = function() end }
  package.loaded["dadbod-grip.completion"] = { invalidate = function() end, warm_schema = function() end }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")
  secrets.clear_cache()

  local local_grip = project_dir .. "/.grip"
  local env_path = project_dir .. "/.env"
  paths.ensure_dir(local_grip)
  local ok, err = pcall(fn, local_grip, env_path)
  vim.wait(50) -- flush any vim.schedule() callbacks queued by switch()/open()

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  grip.setup(orig_opts)
  grip.open_welcome = orig_open_welcome
  package.loaded["dadbod-grip.schema"] = orig_schema
  package.loaded["dadbod-grip.query_pad"] = orig_query_pad
  package.loaded["dadbod-grip.completion"] = orig_completion
  package.loaded["dadbod-grip.connections"] = orig_connections
  connections = orig_connections
  secrets.clear_cache()

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

--- Seed .env + connections.json with a single templated entry and make it
--- the active connection. Returns the template URL.
local function seed_templated_conn(local_grip, env_path, var, value, extra)
  vim.fn.writefile({ var .. "=" .. value }, env_path)
  local entry = vim.tbl_extend("force", {
    name = "dev", url = "${" .. var .. "}", env_file = env_path,
  }, extra or {})
  vim.fn.writefile({ vim.fn.json_encode({ entry }) }, local_grip .. "/connections.json")
  return entry.url
end

-- ── the expanded URL never reaches disk ──────────────────────────────────

test("switch: a templated URL never reaches disk expanded", function()
  with_real_file(function(local_grip, env_path)
    local secret_url = "sqlite:" .. vim.fn.tempname()
    seed_templated_conn(local_grip, env_path, "DB_URL", secret_url)

    connections.switch("${DB_URL}", "dev")
    vim.wait(200, function() return false end)

    local raw = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
    assert(raw:find("${DB_URL}", 1, true), "template preserved on disk")
    assert(not raw:find("sqlite:/", 1, true), "expanded value must not be persisted")
    eq(vim.g.db, "${DB_URL}", "vim.g.db holds the template")
  end)
end)

test("switch: aborts without writing anything when a placeholder cannot be resolved", function()
  with_real_file(function(local_grip, env_path)
    -- .env exists but does not define the variable the URL references.
    vim.fn.writefile({ "SOMETHING_ELSE=1" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${MISSING_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")
    local before = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
    vim.g.db = nil

    connections.switch("${MISSING_URL}", "dev")

    eq(vim.g.db, nil, "no connection activated")
    eq(table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n"), before,
      "nothing written: expansion is checked before any mutation")
  end)
end)

-- ── expansion happens at the dispatch point ──────────────────────────────

test("db.resolve hands the adapter an expanded URL", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "SEED_URL", "sqlite:" .. SEED_DB)
    vim.g.db = url

    -- A real sqlite3 process against the seeded database. Rows coming back
    -- is the proof: the adapter cannot open "${SEED_URL}".
    local result, err = db.query("SELECT COUNT(*) AS n FROM users", url)
    eq(err, nil, "query succeeded")
    assert(result and result.rows and #result.rows == 1, "one row returned")
    assert(tonumber(result.rows[1][1]) and tonumber(result.rows[1][1]) > 0,
      "seeded users table has rows, got " .. vim.inspect(result and result.rows))
    eq(vim.g.db, url, "vim.g.db still holds the template after a query")
  end)
end)

test("db.resolve expands the URL taken from vim.g.db when none is passed", function()
  with_real_file(function(local_grip, env_path)
    vim.g.db = seed_templated_conn(local_grip, env_path, "SEED_URL", "sqlite:" .. SEED_DB)

    local result, err = db.query("SELECT COUNT(*) AS n FROM users")
    eq(err, nil, "query succeeded off vim.g.db alone")
    assert(result and #result.rows == 1, "one row returned")
  end)
end)

test("db.resolve reports the expansion error instead of a bogus adapter error", function()
  with_real_file(function(local_grip, env_path)
    vim.fn.writefile({ "SOMETHING_ELSE=1" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${MISSING_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")

    local result, err = db.query("SELECT 1", "${MISSING_URL}")
    eq(result, nil, "no result")
    -- Specifically the expander's message, not the adapter's "Unsupported
    -- database scheme: ${MISSING_URL}" -- which is what a resolve() that
    -- skipped expansion would produce, and would still mention the variable.
    assert(err and err:find("unresolved variable ${MISSING_URL}", 1, true),
      "error is the expander's, got " .. tostring(err))
    assert(err:find("^secrets:"), "error carries the secrets: prefix, got " .. err)
  end)
end)

-- ── literal URLs are untouched (backwards compatibility) ─────────────────

test("a literal URL costs no .env read at all", function()
  with_real_file(function(local_grip, env_path)
    -- An entry that *has* an env_file, so the only thing keeping the
    -- expander out of the way is the URL having no placeholder.
    vim.fn.writefile({ "UNUSED=1" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "sqlite:" .. SEED_DB, env_file = env_path },
    }) }, local_grip .. "/connections.json")

    local reads = 0
    local orig_parse = secrets.parse_env_file
    secrets.parse_env_file = function(...)
      reads = reads + 1
      return orig_parse(...)
    end
    local result, err = db.query("SELECT COUNT(*) AS n FROM users", "sqlite:" .. SEED_DB)
    secrets.parse_env_file = orig_parse

    eq(err, nil, "literal URL still queries")
    assert(result and #result.rows == 1, "one row returned")
    eq(reads, 0, "no .env file was read for a literal URL")
  end)
end)

test("a templated URL does read the .env file (the counter above can move)", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "SEED_URL", "sqlite:" .. SEED_DB)

    local reads = 0
    local orig_parse = secrets.parse_env_file
    secrets.parse_env_file = function(...)
      reads = reads + 1
      return orig_parse(...)
    end
    local _, err = db.query("SELECT COUNT(*) AS n FROM users", url)
    secrets.parse_env_file = orig_parse

    eq(err, nil, "query succeeded")
    assert(reads > 0, "the templated path really does go through parse_env_file")
  end)
end)

-- ── history keeps the template ───────────────────────────────────────────

test("history records the template, not the expansion", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "SEED_URL", "sqlite:" .. SEED_DB)
    vim.g.db = url

    -- The real grid path: resolve_query -> db.query -> history.record.
    grip.open("SELECT id FROM users LIMIT 1", url, {})

    local lines = vim.fn.readfile(local_grip .. "/history.jsonl")
    assert(#lines > 0, "a history entry was written")
    local entry = vim.fn.json_decode(lines[#lines])
    assert(entry.url:find("${", 1, true), "history url keeps the template, got " .. entry.url)
    assert(not entry.url:find(SEED_DB, 1, true),
      "history url must not contain the expanded target, got " .. entry.url)

    local raw = table.concat(lines, "\n")
    assert(not raw:find(SEED_DB, 1, true), "no expanded URL anywhere in history.jsonl")
  end)
end)

-- ── DuckDB attachments: persisted templated, expanded on replay ──────────

test("save_attachments persists the templated dsn, not the expanded one", function()
  with_real_file(function(local_grip, env_path)
    vim.fn.writefile({ "PG_URL=postgresql://u:hunter2@localhost:5432/app" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "duck", url = "duckdb::memory:" },
      { name = "app", url = "${PG_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")

    -- What the a:attach picker action / :GripAttach hand to save_attachments:
    -- the live record carries the expanded dsn plus the template it came from.
    connections.save_attachments("duckdb::memory:", {
      { dsn = "postgres:dbname=app user=u password=hunter2 host=localhost port=5432",
        alias = "app", template = "${PG_URL}" },
    })

    local raw = table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n")
    assert(not raw:find("hunter2", 1, true), "attachment password must not be persisted")
    assert(raw:find("${PG_URL}", 1, true), "attachment dsn stored as the template")
  end)
end)

test("save_attachments still persists a literal dsn verbatim", function()
  with_real_file(function(local_grip)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "duck", url = "duckdb::memory:" },
    }) }, local_grip .. "/connections.json")

    connections.save_attachments("duckdb::memory:", {
      { dsn = "sqlite:/tmp/side.db", alias = "side" },
    })

    local data = vim.fn.json_decode(table.concat(vim.fn.readfile(local_grip .. "/connections.json"), "\n"))
    eq(data[1].attachments[1].dsn, "sqlite:/tmp/side.db", "literal dsn round-trips unchanged")
    eq(data[1].attachments[1].alias, "side", "alias round-trips")
  end)
end)

test("switch replays a templated attachment against the live database", function()
  with_real_file(function(local_grip, env_path)
    if vim.fn.executable("duckdb") == 0 then
      print("SKIP: switch replays a templated attachment (duckdb CLI not installed)")
      return
    end
    vim.fn.writefile({ "SIDE_URL=sqlite:" .. SEED_DB }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      {
        name = "duck", url = "duckdb::memory:",
        attachments = { { dsn = "${SIDE_URL}", alias = "side" } },
      },
      { name = "side", url = "${SIDE_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")

    connections.switch("duckdb::memory:", "duck")
    vim.wait(100, function() return false end)

    local duckdb = require("dadbod-grip.adapters.duckdb")
    local atts = duckdb.get_attachments("duckdb::memory:")
    eq(#atts, 1, "attachment replayed")
    assert(atts[1].dsn:find(SEED_DB, 1, true),
      "the live attachment dsn is expanded, got " .. tostring(atts[1].dsn))
    eq(atts[1].template, "${SIDE_URL}", "the template is kept for the next save")

    -- And it is genuinely attached: query the seeded table through the alias.
    local result, err = duckdb.query("SELECT COUNT(*) FROM side.users", "duckdb::memory:")
    eq(err, nil, "federated query succeeded")
    assert(result and tonumber(result.rows[1][1]) > 0, "rows came back through the alias")
    duckdb.detach("duckdb::memory:", "side")
  end)
end)

-- ── ATTACH failure text carries no credentials ───────────────────────────
--
-- The fixtures below are VERBATIM stderr captured from the real duckdb CLI
-- (v1.5.5 "Variegata" d8cdaa33fd) on 2026-07-31, by running the exact SQL
-- M.attach builds. They are pinned as literals because they are the whole
-- point of the test: the first version of this suite asserted against a
-- message the test itself had composed ("Failed to attach " .. dsn), which is
-- a tautology -- the mask was checked against a string built from the very
-- value it matches on -- and it passed while a real password went to the
-- screen. Note in both samples that DuckDB does NOT echo the DSN back
-- unchanged: the URL loses a slash and gains the process cwd, and the
-- key=value form loses its "postgres:" prefix. Any whole-string match misses.
--
-- Fidelity note: fixture 1 is the complete message, byte for byte. Fixture 2
-- is a verbatim *prefix* -- the real stderr continues with a second line,
-- "\n\tIs the server running on that host and accepting TCP/IP connections?",
-- which is credential-free and dropped here for readability. The live tests
-- further down work on the untruncated output.
local DUCKDB_URL_STDERR =
  'IO Error: Cannot open file "/Users/gleb/dev/dadbod-grip.nvim/postgresql:/'
  .. 'pguser:s3cr3t_from_dotenv@127.0.0.1:5472/postgres": No such file or directory'
local DUCKDB_QUOTED_PW_STDERR =
  'IO Error: Unable to connect to Postgres at "dbname=app host=127.0.0.1 port=1 '
  .. "user=u password='hun ter2'\": connection to server at \"127.0.0.1\", port 1 "
  .. "failed: Connection refused"

test("attach error: real duckdb stderr for a URL-shaped dsn carries no password", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  local dsn = "postgresql://pguser:s3cr3t_from_dotenv@127.0.0.1:5472/postgres"
  local msg = duckdb._redact_attach_error(DUCKDB_URL_STDERR, dsn)
  assert(not msg:find("s3cr3t_from_dotenv", 1, true), "password removed, got " .. msg)
  assert(msg:find("No such file or directory", 1, true),
    "the diagnostic itself survives, got " .. msg)
  assert(msg:find("127.0.0.1", 1, true), "non-secret parts survive, got " .. msg)
end)

test("attach error: real duckdb stderr for a quoted key=value password carries no password", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  -- libpq conninfo allows a quoted value with spaces, and :GripAttach rejoins
  -- its argv with spaces, so this DSN is reachable by typing.
  local dsn = "postgres:dbname=app host=127.0.0.1 port=1 user=u password='hun ter2'"
  local msg = duckdb._redact_attach_error(DUCKDB_QUOTED_PW_STDERR, dsn)
  assert(not msg:find("hun ter2", 1, true), "whole password removed, got " .. msg)
  assert(not msg:find("ter2", 1, true), "no tail of the password survives, got " .. msg)
  assert(msg:find("Connection refused", 1, true), "the diagnostic survives, got " .. msg)
end)

test("attach error: the live duckdb binary cannot leak a password through M.attach", function()
  if vim.fn.executable("duckdb") == 0 then
    print("SKIP: live duckdb attach-leak test (duckdb CLI not installed)")
    return
  end
  local duckdb = require("dadbod-grip.adapters.duckdb")
  -- Port 1 is unreachable, and DuckDB's postgres extension never claims the
  -- "postgresql://" prefix for ATTACH anyway -- it falls through to its file
  -- reader. Either way this fails fast, without touching the network, and
  -- whatever the real binary says has to come back with no password in it.
  local dsn = "postgresql://pguser:s3cr3t_live_pw@127.0.0.1:1/postgres"
  local err = duckdb.attach("duckdb::memory:", dsn, "leaky")
  assert(err, "the attach failed, as this test requires")
  assert(not err:find("s3cr3t_live_pw", 1, true),
    "no password in what the real duckdb binary produced: " .. err)
  eq(#duckdb.get_attachments("duckdb::memory:"), 0, "nothing was stored")
end)

test("attach: a database duckdb has no scanner for is refused before the CLI runs", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  -- Reachable with two keystrokes: a:attach in the picker on a saved SQL
  -- Server connection. url_to_dsn has no conversion for it, so the URL used
  -- to go to DuckDB verbatim and come back as a "Cannot open file" quoting
  -- the credentials.
  local dsn = "sqlserver://sa:P%40ssw0rd_from_env@10.255.255.1:1433/app"
  eq(duckdb.url_to_dsn(dsn), dsn, "url_to_dsn passes sqlserver:// through unchanged")
  local err = duckdb.attach("duckdb::memory:", dsn, "app")
  assert(err, "refused")
  assert(err:find("no scanner for sqlserver://", 1, true), "says why, got " .. err)
  assert(not err:find("P%40ssw0rd_from_env", 1, true),
    "the refusal names the scheme, never the credentials, got " .. err)
  eq(#duckdb.get_attachments("duckdb::memory:"), 0, "nothing was stored")
end)

test("attach: postgres/mysql/sqlite URLs are not caught by the scheme refusal", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  for _, dsn in ipairs({
    "postgres:dbname=app host=h", "mysql:host=h user=u", "sqlite:/tmp/x.db",
    "sqlite://tmp/x.db", "md:analytics", "/plain/path/to.duckdb",
  }) do
    eq(duckdb._unsupported_attach_scheme(dsn), nil, "attachable: " .. dsn)
  end
  assert(duckdb._unsupported_attach_scheme("oracle://u:p@h/db"), "oracle is refused")
end)

test("attach error: a credential-free message is returned untouched", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  local stderr = "Error: Extension \"postgres_scanner\" not found"
  eq(duckdb._redact_attach_error(stderr, "postgres:dbname=app host=db.internal"), stderr,
    "no over-masking of a plain diagnostic")
end)

-- ── live-binary leak tests ───────────────────────────────────────────────
-- Every case below drives the real duckdb CLI through the plugin's own path
-- and asserts on what the binary actually produced. Nothing here composes the
-- message it then greps: that pattern is what let the original ATTACH test
-- pass while a password reached the screen.
--
-- All point at 127.0.0.1:1, which refuses instantly -- no network wait, and
-- no live server is touched.

--- Run fn only when the duckdb CLI is present; print a visible skip if not.
local function with_duckdb(label, fn)
  if vim.fn.executable("duckdb") == 0 then
    print("SKIP: " .. label .. " (duckdb CLI not installed)")
    return
  end
  fn()
end

test("attach error: a password containing @ survives url_to_dsn and is fully masked", function()
  with_duckdb("@-in-password leak test", function()
    local duckdb = require("dadbod-grip.adapters.duckdb")
    -- url_to_dsn used to split the authority on the FIRST "@", yielding
    -- password=P host=ssw0rd@127.0.0.1 -- so the mask masked one character
    -- and DuckDB printed the other seven. It now uses sql.split_authority.
    local dsn = duckdb.url_to_dsn("postgresql://u:P@ssw0rd@127.0.0.1:1/app")
    local err = duckdb.attach("duckdb::memory:", dsn, "atsign")
    duckdb.detach("duckdb::memory:", "atsign")
    assert(err, "the attach failed, as this test requires")
    -- Leak assertion first: it is the one that must speak when the parse
    -- regresses, and it reports what the real binary printed.
    assert(not err:find("ssw0rd", 1, true), "no fragment of the password: " .. err)
    eq(dsn, "postgres:dbname=app user=u password=P@ssw0rd host=127.0.0.1 port=1",
      "the whole password lands in password=, not half of it in host=")
  end)
end)

test("attach error: a backslash-escaped quote inside a quoted password is fully masked", function()
  with_duckdb("escaped-quote leak test", function()
    local duckdb = require("dadbod-grip.adapters.duckdb")
    -- libpq documents \' as the way to put a quote inside a quoted value.
    -- The scan used to stop at that escaped quote and leave "ter2'" on screen.
    local dsn = [[postgres:dbname=app host=127.0.0.1 port=1 user=u password='hun\'ter2']]
    local err = duckdb.attach("duckdb::memory:", dsn, "escq")
    assert(err, "the attach failed, as this test requires")
    assert(not err:find("ter2", 1, true), "no tail of the password: " .. err)
    duckdb.detach("duckdb::memory:", "escq")
  end)
end)

test("attach error: libpq sslpassword is masked", function()
  with_duckdb("sslpassword leak test", function()
    local duckdb = require("dadbod-grip.adapters.duckdb")
    -- sslpassword is the client-key passphrase -- exactly the kind of value a
    -- ${VAR} holds -- and was missing from DSN_SECRET_KEYS entirely.
    local dsn = "postgres:dbname=app host=127.0.0.1 port=1 user=u sslpassword=keyphrase_s3cret"
    local err = duckdb.attach("duckdb::memory:", dsn, "sslpw")
    assert(err, "the attach failed, as this test requires")
    assert(not err:find("keyphrase_s3cret", 1, true), "passphrase masked: " .. err)
    duckdb.detach("duckdb::memory:", "sslpw")
  end)
end)

test("query error: an attachment that dies after attach cannot leak on the next query", function()
  with_duckdb("query-path leak test", function()
    local duckdb = require("dadbod-grip.adapters.duckdb")
    -- The ordinary failure mode: the attachment validated at attach time and
    -- the server went away afterwards (restart, VPN drop). build_attach_prefix
    -- puts the DSN at the head of every query from then on, and M.query used
    -- to return DuckDB's stderr raw to vim.notify. _attach_unchecked is how
    -- the test gets to that state without a server that later dies.
    duckdb._attach_unchecked("duckdb::memory:",
      "postgres:dbname=app user=u password=s3cr3t_query_path host=127.0.0.1 port=1", "gone")
    local result, err = duckdb.query("SELECT 1", "duckdb::memory:")
    duckdb.detach("duckdb::memory:", "gone")
    eq(result, nil, "the query failed, as this test requires")
    assert(err and not err:find("s3cr3t_query_path", 1, true),
      "no password on the query path: " .. tostring(err))
    assert(err:find("Connection refused", 1, true) or err:find("Unable to connect", 1, true),
      "the diagnostic still says what went wrong: " .. err)
  end)
end)

test("attach error: a motherduck token never reaches the message", function()
  with_duckdb("motherduck token test", function()
    local duckdb = require("dadbod-grip.adapters.duckdb")
    -- Honest scope: DuckDB v1.5.5 rejects this before it echoes the DSN, so
    -- this asserts the property (no token on screen) rather than proving the
    -- mask fired. It is a forward guard against a binary that does echo -- and
    -- unlike the composed-message test it replaces, it cannot pass by
    -- construction.
    local dsn = "md:analytics?motherduck_token=eyJhbGciOi_fake_token"
    local err = duckdb.attach("duckdb::memory:", dsn, "mdtok")
    duckdb.detach("duckdb::memory:", "mdtok")
    assert(not (err or ""):find("eyJhbGciOi_fake_token", 1, true),
      "no token in the message: " .. tostring(err))
  end)
end)

test("the secret-key list covers the audited libpq and token keywords", function()
  local duckdb = require("dadbod-grip.adapters.duckdb")
  -- Deliberately a structural assertion on the list itself, not a masking run
  -- against a message this test composed: that shape proves nothing about the
  -- real output (see the live tests above, which do). What it pins is the
  -- outcome of the keyword audit -- including the two decided against.
  local keys = duckdb._dsn_secret_keys
  for _, key in ipairs({
    "password", "sslpassword", "passwd", "pwd", "token", "motherduck_token",
    "access_token", "auth_token", "session_token", "api_key", "apikey",
    "secret", "secret_access_key",
  }) do
    eq(keys[key], true, key .. " is classified as a credential")
  end
  -- Paths, not secrets: masking one protects nothing and makes the error
  -- unactionable.
  for _, key in ipairs({ "passfile", "sslkey", "user", "dbname", "host" }) do
    eq(keys[key], nil, key .. " is deliberately not masked")
  end
end)

-- ── the failure path: no trace, and a legible error ──────────────────────

test("the git-crypt hint reaches the user", function()
  with_real_file(function(local_grip, env_path)
    -- git-crypt's own magic header (see secrets.lua's GITCRYPT_MAGIC).
    -- io.open in "wb" mode, not vim.fn.writefile(), so the leading NUL
    -- byte survives -- writefile() would turn it into a newline and the
    -- lock would never be detected.
    local f = io.open(env_path, "wb")
    f:write("\0GITCRYPT\0" .. string.rep("x", 20))
    f:close()
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${LOCKED_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")

    local captured
    local harness_notify = vim.notify -- with_real_file's no-op stub
    vim.notify = function(msg, level) captured = { msg = msg, level = level } end

    connections.switch("${LOCKED_URL}", "dev")

    vim.notify = harness_notify

    assert(captured, "vim.notify was called")
    eq(captured.level, vim.log.levels.ERROR, "reported at ERROR level")
    assert(captured.msg:find("git-crypt unlock", 1, true),
      "message tells the user how to fix it, got " .. tostring(captured.msg))
    assert(captured.msg:find(env_path, 1, true),
      "message names the locked file, got " .. tostring(captured.msg))
  end)
end)

-- ── T:test on an unresolvable entry ───────────────────────────────────────
-- Before this, T:test handed the literal "${VAR}" straight to db.ping(),
-- which resolves internally, fails, and swallows the expansion error --
-- the picker just showed a generic "x" fail, indistinguishable from a
-- database that is actually unreachable.

test("T:test reports the expansion error and marks it distinctly, not a bogus fail", function()
  with_real_file(function(local_grip, env_path)
    -- .env exists but the variable the URL references was renamed/removed.
    vim.fn.writefile({ "SOMETHING_ELSE=1" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${RENAMED_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")

    local grip_picker = require("dadbod-grip.grip_picker")
    local orig_picker_open = grip_picker.open
    local captured
    grip_picker.open = function(opts) captured = opts end
    connections.pick()
    grip_picker.open = orig_picker_open

    assert(captured and captured.actions, "pick() reached grip_picker.open with actions")
    local test_action
    for _, a in ipairs(captured.actions) do
      if a.label == "T:test" then test_action = a end
    end
    assert(test_action, "T:test action present")

    local dev
    for _, item in ipairs(captured.items) do
      if item.name == "dev" then dev = item end
    end
    assert(dev, "dev present among picker items")

    local captured_notify
    local harness_notify = vim.notify -- with_real_file's no-op stub
    vim.notify = function(msg, level) captured_notify = { msg = msg, level = level } end
    test_action.fn(dev)
    vim.notify = harness_notify

    eq(connections.get_health(dev.url), "unresolved",
      "health is a distinct 'unresolved' status, not the generic 'fail' a real ping would set")
    assert(captured_notify, "the expansion error was surfaced via vim.notify")
    eq(captured_notify.level, vim.log.levels.ERROR, "reported at ERROR level")
    assert(captured_notify.msg:find("unresolved variable ${RENAMED_URL}", 1, true),
      "message is the expander's, not a scheme error, got " .. tostring(captured_notify.msg))

    -- The picker marker for it must not read as a plain failure ("x").
    eq(captured.display(dev):sub(1, 1), "?", "distinct health marker for an unresolvable entry")
  end)
end)

-- ── templates resolve where the *scheme* is what matters ─────────────────

test("db.resolved_url gives dialect-sensitive callers a real scheme", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "PG_URL",
      "postgresql://u:hunter2@db.internal:5432/app")

    eq(db.resolved_url(url), "postgresql://u:hunter2@db.internal:5432/app",
      "template resolved for scheme dispatch")
    eq(require("dadbod-grip.adapters").kind(db.resolved_url(url)), "postgresql",
      "adapters.kind now sees postgresql, not nil")
    eq(require("dadbod-grip.explain").detect_adapter(url), "postgresql",
      "Query Doctor keeps its parser instead of degrading to 'unknown'")
    eq(require("dadbod-grip.adapters").display_name(db.resolved_url(url)), "PostgreSQL",
      "the LLM prompt gets the right dialect")
  end)
end)

test("db.resolved_url leaves literals alone and never errors on a broken template", function()
  with_real_file(function(local_grip, env_path)
    eq(db.resolved_url("postgresql://u:p@h/db"), "postgresql://u:p@h/db", "literal unchanged")
    eq(db.resolved_url(nil), nil, "nil unchanged")
    vim.fn.writefile({ "SOMETHING_ELSE=1" }, env_path)
    vim.fn.writefile({ vim.fn.json_encode({
      { name = "dev", url = "${MISSING_URL}", env_file = env_path },
    }) }, local_grip .. "/connections.json")
    -- Best-effort: a display/dialect caller must degrade, not blow up.
    eq(db.resolved_url("${MISSING_URL}"), "${MISSING_URL}", "unresolvable comes back as-is")
    eq(require("dadbod-grip.explain").detect_adapter("${MISSING_URL}"), "unknown",
      "and the caller falls back exactly as it did before this feature")
  end)
end)

test("DROP TABLE on a templated postgres connection still emits CASCADE", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "PG_URL",
      "postgresql://u:hunter2@db.internal:5432/app")
    local ddl = require("dadbod-grip.ddl")

    -- No server is contacted: the DDL text is built from the adapter kind
    -- alone, so only the FK lookup needs standing in for.
    local orig_refs = db.get_referencing_foreign_keys
    db.get_referencing_foreign_keys = function()
      return { { table = "public.orders", column = "user_id", ref_column = "id" } }
    end
    local ok, err = pcall(ddl.drop_table, "public.users", url)
    db.get_referencing_foreign_keys = orig_refs
    assert(ok, "drop_table raised: " .. tostring(err))

    -- destructive_confirm draws its preview into a scratch buffer and enters
    -- its window, so the SQL that would run is readable right here.
    local popup = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.api.nvim_win_close(0, true)

    assert(popup:find("CASCADE", 1, true), "CASCADE survives on postgresql, got:\n" .. popup)
    assert(not popup:find("doesn't support CASCADE", 1, true),
      "no false 'this adapter can't CASCADE' note, got:\n" .. popup)
  end)
end)

test("completion looks up duckdb attachments under the expanded URL", function()
  with_real_file(function(local_grip, env_path)
    local url = seed_templated_conn(local_grip, env_path, "DUCK_URL", "duckdb::memory:")
    local duckdb = require("dadbod-grip.adapters.duckdb")
    duckdb._attach_unchecked("duckdb::memory:", "sqlite:/tmp/side.db", "side")

    -- What completion.lua does for `alias.<tab>`: the registry is keyed by
    -- the expanded URL, the buffer variable holds the template.
    eq(#duckdb.get_attachments(url), 0, "the template is not a registry key")
    eq(#duckdb.get_attachments(db.resolved_url(url)), 1, "the resolved URL is")
    duckdb.detach("duckdb::memory:", "side")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nsecrets_integration_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
