-- secrets_spec.lua -- characterization + regression tests for secrets.lua,
-- the standalone ${VAR} resolver that lets a connection entry point at a
-- project .env file instead of carrying a password in connections.json.
local secrets = require("dadbod-grip.secrets")

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

local function with_env_file(contents, fn)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(contents, "\n"), path)
  secrets.clear_cache()
  local ok, err = pcall(fn, path)
  vim.fn.delete(path)
  secrets.clear_cache()
  if not ok then error(err) end
end

--- Write raw bytes to `path` via plain Lua io, not vim.fn.writefile().
--- Needed for the git-crypt fixture below: vim.fn.writefile() auto-promotes
--- a Lua string with an embedded NUL byte to a Blob and then rejects it
--- inside a list ("E974: Expected a Number or a String, Blob found"), and
--- even in "b" binary mode vim.fn.readfile() maps a file's NUL bytes onto
--- NL when it hands them back as a List<String>. Neither survives a
--- literal "\0GITCRYPT\0" round-trip, so the fixture and the production
--- code (see secrets.lua's is_git_crypt_locked) both go around vim.fn.
local function write_bytes(path, bytes)
  local f = io.open(path, "wb")
  f:write(bytes)
  f:close()
end

test("parses plain, exported, and quoted assignments", function()
  with_env_file([[
# a comment
PLAIN=value1
export EXPORTED=value2
DQ="double quoted"
SQ='single quoted'

HASH="has # inside"
]], function(path)
    local vars = secrets.parse_env_file(path)
    eq(vars.PLAIN, "value1", "plain")
    eq(vars.EXPORTED, "value2", "export prefix stripped")
    eq(vars.DQ, "double quoted", "double quotes stripped")
    eq(vars.SQ, "single quoted", "single quotes stripped")
    eq(vars.HASH, "has # inside", "# inside quotes is not a comment")
  end)
end)

test("expands a full-URL template", function()
  with_env_file("DB_URL=postgresql://u:p@h:5432/db", function(path)
    local url, err = secrets.expand("${DB_URL}", { env_file = path })
    eq(err, nil, "no error")
    eq(url, "postgresql://u:p@h:5432/db", "expanded")
  end)
end)

test("expands a password embedded in a URL", function()
  with_env_file("PW=s3cr3t", function(path)
    local url = secrets.expand("postgresql://u:${PW}@h:5432/db", { env_file = path })
    eq(url, "postgresql://u:s3cr3t@h:5432/db", "inline substitution")
  end)
end)

test("an unresolved variable is an error, not an empty string", function()
  with_env_file("OTHER=x", function(path)
    local url, err = secrets.expand("${MISSING}", { env_file = path })
    eq(url, nil, "no URL returned")
    assert(err and err:find("MISSING", 1, true), "error names the variable: " .. tostring(err))
  end)
end)

test("falls back to the process environment", function()
  vim.fn.setenv("GRIP_SPEC_FALLBACK", "from-env")
  local url = secrets.expand("${GRIP_SPEC_FALLBACK}", {})
  eq(url, "from-env", "process env used when no env_file")
  vim.fn.setenv("GRIP_SPEC_FALLBACK", vim.NIL)
end)

test("a git-crypt encrypted file produces an actionable error", function()
  local path = vim.fn.tempname()
  write_bytes(path, "\0GITCRYPT\0binary-garbage")
  secrets.clear_cache()
  local _, err = secrets.expand("${ANY}", { env_file = path })
  assert(err and err:lower():find("git%-crypt"), "mentions git-crypt: " .. tostring(err))
  assert(err:find(path, 1, true), "names the file: " .. tostring(err))
  vim.fn.delete(path)
  secrets.clear_cache()
end)

test("cache is invalidated when the file changes", function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "V=first" }, path)
  secrets.clear_cache()
  eq(secrets.expand("${V}", { env_file = path }), "first", "first read")
  vim.fn.writefile({ "V=second" }, path)
  vim.fn.system({ "touch", "-t", "203001010000", path })
  eq(secrets.expand("${V}", { env_file = path }), "second", "re-read after mtime change")
  vim.fn.delete(path)
end)

test("a failed read is never cached, so an unlock takes effect on the next call", function()
  local path = vim.fn.tempname()
  write_bytes(path, "\0GITCRYPT\0binary-garbage")
  -- Pin both writes below to the identical mtime (second resolution),
  -- so this reproduces the case the mtime cache key cannot distinguish
  -- on its own: the interesting assertion is that the *error* branch
  -- never wrote a cache entry in the first place, not that the mtime
  -- changed.
  vim.fn.system({ "touch", "-t", "202001010000", path })
  secrets.clear_cache()

  local _, err = secrets.expand("${V}", { env_file = path })
  assert(err and err:lower():find("git%-crypt"), "first read is the git-crypt error: " .. tostring(err))

  -- "Unlock" in place, at the same mtime, without calling clear_cache().
  -- If the failed read above had been cached, this would return the
  -- stale failure (or a silently cached nil) instead of re-parsing.
  vim.fn.writefile({ "V=unlocked" }, path)
  vim.fn.system({ "touch", "-t", "202001010000", path })

  local url = secrets.expand("${V}", { env_file = path })
  eq(url, "unlocked", "retried and picked up the unlocked content with no clear_cache()")

  vim.fn.delete(path)
  secrets.clear_cache()
end)

test("has_template detects placeholders", function()
  eq(secrets.has_template("${X}"), true, "placeholder")
  eq(secrets.has_template("postgresql://u:p@h/db"), false, "literal")
end)

test("a missing env_file is an error naming the path", function()
  local _, err = secrets.expand("${X}", { env_file = "/nonexistent/path/.env" })
  assert(err and err:find("/nonexistent/path/.env", 1, true), "names the path")
end)

print(string.format("\nsecrets_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
