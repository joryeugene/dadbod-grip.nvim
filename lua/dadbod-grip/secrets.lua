-- secrets.lua: resolves ${VAR} placeholders in connection URLs against a
-- project-local .env file, so a connection entry can reference its
-- password without it ever being written into ~/.grip/connections.json.
--
-- Zero dependencies on the rest of dadbod-grip: must be requireable in
-- isolation (see Task 5 of the connection-secrets-mode-color plan).

local M = {}

-- git-crypt's own magic header: https://github.com/AGWA/git-crypt --
-- an encrypted-at-rest file starts with these exact 10 bytes.
local GITCRYPT_MAGIC = "\0GITCRYPT\0"

-- path -> { mtime = <getftime() at last read>, vars = <table<string,string>> }
local cache = {}

--- Discard all cached .env contents.
--- Test seam, and the escape hatch for anyone who unlocks git-crypt (or
--- otherwise replaces an env_file) without restarting Neovim.
function M.clear_cache()
  cache = {}
end

--- Strip one matching pair of surrounding quotes from a raw assignment
--- value. Unquoted values are returned unchanged.
--- @param raw string
--- @return string
local function unquote(raw)
  local double = raw:match('^"(.*)"$')
  if double then
    return double
  end
  local single = raw:match("^'(.*)'$")
  if single then
    return single
  end
  return raw
end

--- Parse one line of a .env file. Returns nil for comments, blank lines,
--- and anything that isn't a recognizable `[export ]KEY=value` assignment.
--- @param line string
--- @return string|nil key
--- @return string|nil value
local function parse_line(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  if trimmed == "" or trimmed:sub(1, 1) == "#" then
    return nil
  end
  trimmed = trimmed:match("^export%s+(.+)$") or trimmed
  local key, raw = trimmed:match("^([%w_]+)=(.*)$")
  if not key then
    return nil
  end
  return key, unquote(raw)
end

--- Detect a git-crypt-locked file from its leading bytes.
---
--- Deliberately reads with plain Lua io, not vim.fn.readfile(): Neovim's
--- List<->String bridge always maps a file's NUL bytes onto NL (this is
--- true even with the "b" binary flag -- it affects line-splitting, not
--- the NUL/NL swap), so git-crypt's leading "\0GITCRYPT\0" would arrive
--- here as "\nGITCRYPT\n" and never match. io.open in "rb" mode returns
--- the exact bytes.
--- @param path string
--- @return boolean
local function is_git_crypt_locked(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local head = f:read(#GITCRYPT_MAGIC) or ""
  f:close()
  return head == GITCRYPT_MAGIC
end

--- Read and parse a .env file, bypassing the cache.
--- @param path string
--- @return table<string,string>|nil vars
--- @return string|nil err
local function read_and_parse(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "secrets: .env file not found: " .. path
  end
  if is_git_crypt_locked(path) then
    return nil,
      "secrets: " .. path .. " is git-crypt encrypted; run `git-crypt unlock` in the repo and retry"
  end
  local vars = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local key, value = parse_line(line)
    if key then
      vars[key] = value
    end
  end
  return vars
end

--- Parse a .env file into a table of assignments.
---
--- Memoized per (expanded) path and invalidated when the file's mtime
--- changes, so a password rotated by a teammate mid-session is picked up
--- on the next query rather than requiring a restart.
---
--- Failed reads (missing file, still git-crypt-locked) are deliberately
--- never cached -- see the write site below -- so `git-crypt unlock`
--- takes effect on the very next call, with no clear_cache() needed.
---
--- The gap runs the other way: vim.fn.getftime() only has 1-second
--- resolution, so replacing a file's *contents* within the same second as
--- a prior successful read is invisible to this cache. A cached plaintext
--- read stays cached -- including past a same-second git-crypt lock, i.e.
--- the module keeps serving decrypted values for a file that has since
--- been re-encrypted -- until an unrelated later write bumps the mtime,
--- clear_cache() is called, or the process restarts. Accepted: a
--- hand-edited local secrets file is not realistically rewritten twice
--- inside one wall-clock second, and closing the gap would mean hashing
--- the whole file on every call, defeating the point of caching.
--- @param path string
--- @return table<string,string>|nil vars
--- @return string|nil err
function M.parse_env_file(path)
  path = vim.fn.expand(path)
  local mtime = vim.fn.getftime(path)
  local cached = cache[path]
  if cached and cached.mtime == mtime then
    return cached.vars
  end
  local vars, err = read_and_parse(path)
  if not vars then
    return nil, err
  end
  -- Only successful reads are cached: a failure here (missing file,
  -- still git-crypt-locked) must retry from scratch next call, so an
  -- unlock is picked up immediately. See the doc comment above.
  cache[path] = { mtime = mtime, vars = vars }
  return vars
end

--- True when `url` contains at least one ${NAME} placeholder.
--- @param url string
--- @return boolean
function M.has_template(url)
  return url:find("%${[%w_]+}") ~= nil
end

--- Resolve every ${NAME} placeholder in `url`.
---
--- Values come from `entry.env_file` (if set) first, falling back to the
--- process environment. An unresolved placeholder is always an error --
--- never an empty substitution, since a URL quietly missing its password
--- either connects somewhere unintended or hangs on a prompt.
--- @param url string
--- @param entry table connection entry; may carry `env_file`
--- @return string|nil resolved
--- @return string|nil err
function M.expand(url, entry)
  entry = entry or {}

  local vars
  if entry.env_file then
    local err
    vars, err = M.parse_env_file(entry.env_file)
    if not vars then
      return nil, err
    end
  end

  local first_err
  local resolved = url:gsub("%${([%w_]+)}", function(name)
    if first_err then
      return ""
    end
    local value = vars and vars[name]
    if value == nil then
      local env_value = vim.fn.getenv(name)
      if env_value ~= vim.NIL then
        value = env_value
      end
    end
    if value == nil then
      first_err = "secrets: unresolved variable ${"
        .. name
        .. "} (checked"
        .. (entry.env_file and (" " .. entry.env_file .. " and") or "")
        .. " the process environment)"
      return ""
    end
    return value
  end)

  if first_err then
    return nil, first_err
  end
  return resolved
end

return M
