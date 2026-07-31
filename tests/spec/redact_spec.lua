-- redact_spec.lua -- unit tests for sql.redact_url, the single password-masking
-- pattern shared by history.lua and the adapters' error messages.
local sql = require("dadbod-grip.sql")

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

-- ── basic cases ──────────────────────────────────────────────────────────

test("redacts the password in a postgres URL", function()
  eq(sql.redact_url("postgresql://user:hunter2@host:5432/db"),
     "postgresql://user:***@host:5432/db", "password masked")
end)

test("leaves a password-less URL alone", function()
  eq(sql.redact_url("postgresql://user@host:5432/db"),
     "postgresql://user@host:5432/db", "nothing to mask")
end)

test("leaves a file URL alone", function()
  eq(sql.redact_url("duckdb:/tmp/x.duckdb"), "duckdb:/tmp/x.duckdb", "no auth part")
end)

test("handles nil", function()
  eq(sql.redact_url(nil), "", "nil becomes empty string")
end)

test("mysql errors do not leak the password", function()
  local mysql = require("dadbod-grip.adapters.mysql")
  local _, err = mysql.get_primary_keys("t", "not-a-valid-url-with:hunter2@host")
  assert(err == nil or not tostring(err):find("hunter2", 1, true),
    "password must not appear in the error, got: " .. tostring(err))
end)

test("sqlserver errors do not leak the password", function()
  local sqlserver = require("dadbod-grip.adapters.sqlserver")
  local _, err = sqlserver.query("SELECT 1", "not-a-valid-url-with:hunter2@host")
  assert(err == nil or not tostring(err):find("hunter2", 1, true),
    "password must not appear in the error, got: " .. tostring(err))
end)

-- ── pattern decision ─────────────────────────────────────────────────────
-- history.lua's original pattern captured the user as `[^:]+` (any run of
-- non-colon characters), which does not stop at a "/". That lets the match
-- span past the authority component into the path whenever the path itself
-- contains a colon followed later by an "@" (e.g. a schema-qualified name
-- that happens to precede an email-like string). This adapter's pattern
-- (`[^:/@]+` for the user, so it can never cross a "/") stays scoped to
-- "scheme://user:pass@host" and leaves everything after the first "/" alone.
test("does not falsely redact across a path separator (no real credentials)", function()
  local url = "postgresql://host/schema:name@2024/db"
  eq(sql.redact_url(url), url, "no '://user:pass@' right after the scheme, so no rewrite")
end)

-- Fix round 1, finding 1: the first cut split on the FIRST "@", so a password
-- containing "@" was only partly masked — "mysql://user:p@ss@host/db" came
-- out as "mysql://user:***@ss@host/db", leaking "ss" right next to the mask.
-- parse_dadbod_url (below) already splits on the LAST "@" for exactly this
-- reason; redact_url now mirrors that rule. The old assertion here only
-- checked that "***@" appeared *somewhere*, which is true even while "ss"
-- leaks — tightened to assert the full, exact output instead.
test("fully masks a password that itself contains '@' (splits on the LAST '@')", function()
  local result = sql.redact_url("mysql://user:p@ss@host/db")
  eq(result, "mysql://user:***@host/db", "no leftover password fragment next to the mask")
  assert(not result:find("ss", 1, true), "'ss' (part of the password) must not survive, got: " .. result)
end)

-- Fix round 1, finding 1 (boundary): widening the match to the last "@"
-- must still stop at the authority boundary — it must not reach past the
-- host into the path or query, where an unrelated "@" is not a password.
test("does not swallow an '@' that appears later in the path", function()
  local url = "postgresql://user:pass@host/db@2024"
  eq(sql.redact_url(url), "postgresql://user:***@host/db@2024",
     "the path's '@' is outside the authority and must survive untouched")
end)

-- Fix round 1, finding 2: the no-"://" fallback did a blind global scan with
-- no whitespace boundary, so it could reach across an entire sentence, e.g.
-- "Error at line 12: expected token foo:bar@baz" collapsed to
-- "Error at line 12:***@baz" — losing "expected token foo" along the way.
-- Tightened so neither side of the match may contain whitespace (a real URL
-- never does), which keeps the damage scoped to the one credential-shaped
-- token and off the surrounding prose. It is still a heuristic, not
-- authority-aware: "foo:bar@" itself is genuinely indistinguishable from a
-- real "user:pass@" chunk with no scheme, so it is still masked — this
-- fallback is for a URL argument, not a full free-form message (see the
-- doc comment on M.redact_url).
test("fallback (no '://') is scoped to whitespace-free credential-shaped tokens", function()
  local msg = "Error at line 12: expected token foo:bar@baz"
  eq(sql.redact_url(msg),
     "Error at line 12: expected token foo:***@baz",
     "only the whitespace-free 'foo:bar@' token is masked; surrounding prose is untouched")
end)

print(string.format("\nredact_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
