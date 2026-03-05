-- tests/spec/duckdb_attach_spec.lua — DuckDB cross-database federation
dofile("tests/minimal_init.lua")
local adapter = require("dadbod-grip.adapters.duckdb")

local T = {}
local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s", msg, tostring(b), tostring(a)))
  end
end

local function contains(str, substr, msg)
  if str and str:find(substr, 1, true) then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected to contain: %s\n  got: %s", msg, substr, tostring(str)))
  end
end

-- detect_extension
eq(adapter._detect_extension("postgres:dbname=sales"), "postgres_scanner", "postgres DSN")
eq(adapter._detect_extension("postgresql:dbname=sales"), "postgres_scanner", "postgresql DSN")
eq(adapter._detect_extension("mysql:host=localhost"), "mysql_scanner", "mysql DSN")
eq(adapter._detect_extension("sqlite:local.db"), "sqlite_scanner", "sqlite DSN")
eq(adapter._detect_extension("md:my_db"), "motherduck", "motherduck md: DSN")
eq(adapter._detect_extension("motherduck:my_db"), "motherduck", "motherduck full DSN")
eq(adapter._detect_extension("/path/to/file.db"), nil, "plain path returns nil")

-- build_attach_prefix with no attachments
local url = "duckdb:test.db"
eq(adapter._build_attach_prefix(url), "", "no attachments returns empty string")

-- attach + build_attach_prefix
adapter._attach_unchecked(url, "postgres:dbname=sales host=localhost user=me", "pg")
local prefix = adapter._build_attach_prefix(url)
contains(prefix, "INSTALL postgres_scanner; LOAD postgres_scanner;", "prefix has extension install")
contains(prefix, "ATTACH IF NOT EXISTS 'postgres:dbname=sales host=localhost user=me' AS pg;", "prefix has ATTACH")

-- second attachment
adapter._attach_unchecked(url, "sqlite:legacy.db", "legacy")
prefix = adapter._build_attach_prefix(url)
contains(prefix, "INSTALL sqlite_scanner; LOAD sqlite_scanner;", "prefix has sqlite extension")
-- resolve_dsn_path expands relative paths to absolute
local expected_legacy = "ATTACH IF NOT EXISTS 'sqlite:" .. vim.fn.fnamemodify("legacy.db", ":p") .. "' AS legacy;"
contains(prefix, expected_legacy, "prefix has sqlite ATTACH")
contains(prefix, "postgres_scanner", "still has postgres extension")

-- idempotent attach (same alias updates DSN)
adapter._attach_unchecked(url, "postgres:dbname=prod host=db.internal", "pg")
local atts = adapter.get_attachments(url)
eq(#atts, 2, "idempotent: still 2 attachments after re-attach")
eq(atts[1].dsn, "postgres:dbname=prod host=db.internal", "idempotent: DSN updated")

-- detach
adapter.detach(url, "pg")
atts = adapter.get_attachments(url)
eq(#atts, 1, "detach removes one attachment")
eq(atts[1].alias, "legacy", "remaining attachment is legacy")

-- detach non-existent alias (no-op)
adapter.detach(url, "nonexistent")
eq(#adapter.get_attachments(url), 1, "detach non-existent is no-op")

-- detach last
adapter.detach(url, "legacy")
eq(#adapter.get_attachments(url), 0, "detach all leaves empty list")
eq(adapter._build_attach_prefix(url), "", "no attachments after full detach")

-- bulk store via _attach_unchecked (simulates load_attachments without validation)
adapter._attach_unchecked(url, "postgres:dbname=a", "a")
adapter._attach_unchecked(url, "sqlite:b.db", "b")
adapter._attach_unchecked(url, "md:cloud", "cloud")
atts = adapter.get_attachments(url)
eq(#atts, 3, "bulk store loads 3")
eq(atts[1].extension, "postgres_scanner", "loaded extension detected for postgres")
eq(atts[2].extension, "sqlite_scanner", "loaded extension detected for sqlite")
eq(atts[3].extension, "motherduck", "loaded extension detected for motherduck")

-- load_attachments with nil clears
adapter.load_attachments(url, nil)
eq(#adapter.get_attachments(url), 0, "load nil clears attachments")

-- extension dedup in prefix
local url2 = "duckdb:dedup.db"
adapter._attach_unchecked(url2, "sqlite:a.db", "a")
adapter._attach_unchecked(url2, "sqlite:b.db", "b")
prefix = adapter._build_attach_prefix(url2)
local _, count = prefix:gsub("INSTALL sqlite_scanner", "")
eq(count, 1, "extension INSTALL only appears once despite 2 sqlite attachments")
local _, attach_count = prefix:gsub("ATTACH IF NOT EXISTS", "")
eq(attach_count, 2, "both ATTACH statements present")

-- cleanup
adapter.detach(url2, "a")
adapter.detach(url2, "b")

-- url_to_dsn: credential-less postgres URLs
eq(adapter.url_to_dsn("postgresql://localhost/grip_test"),
   "postgres:dbname=grip_test host=localhost", "url_to_dsn: pg no creds")
eq(adapter.url_to_dsn("postgresql://localhost:5432/mydb"),
   "postgres:dbname=mydb host=localhost port=5432", "url_to_dsn: pg no creds with port")
eq(adapter.url_to_dsn("postgres://dbhost/analytics"),
   "postgres:dbname=analytics host=dbhost", "url_to_dsn: postgres:// no creds")

-- url_to_dsn: with credentials (regression)
eq(adapter.url_to_dsn("postgresql://user:pass@localhost:5432/mydb"),
   "postgres:dbname=mydb user=user password=pass host=localhost port=5432",
   "url_to_dsn: pg with creds")

-- url_to_dsn: passthrough for non-URL DSNs
eq(adapter.url_to_dsn("postgres:dbname=sales host=localhost"),
   "postgres:dbname=sales host=localhost", "url_to_dsn: already DSN passthrough")
eq(adapter.url_to_dsn("sqlite:local.db"),
   "sqlite:local.db", "url_to_dsn: sqlite passthrough")

-- different URLs are independent
local url3 = "duckdb:other.db"
adapter._attach_unchecked(url, "postgres:dbname=x", "x")
eq(#adapter.get_attachments(url3), 0, "different URL has no attachments")
adapter.detach(url, "x")

print(string.format("\nduckdb_attach_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
