-- connections.lua: connection profile management.
-- Reads from .grip/connections.json, g:dbs (DBUI compat), $DATABASE_URL.
-- All functions return (result, err). Never throw.

local paths = require("dadbod-grip.paths")
local ui = require("dadbod-grip.ui")
local secrets = require("dadbod-grip.secrets")

local M = {}

-- Session-scoped connection health state (never persisted).
-- Values: "ok" | "fail" | "unresolved" | "unknown" (default when absent).
-- "unresolved" is distinct from "fail": the connection was never attempted --
-- its ${VAR} placeholder(s) couldn't be expanded (missing .env, still
-- git-crypt-locked, renamed variable), so a scheme/network failure would be
-- a meaningless report.
local _health = {}

-- Session-scoped read/write mode overrides, keyed by connection URL as stored
-- (the template -- the same key entries live under on disk). Set only by
-- M.switch(url, ..., { mode = ... }), which the picker's r:ro/rw action uses
-- to connect once in the mode opposite to the entry's default.
--
-- Deliberately never written to connections.json: the entry's own `mode` is
-- the user's standing decision about that database, and a keypress in a
-- picker is not a request to rewrite their file. Every ordinary switch of a
-- connection clears its override again, so the override lasts exactly from
-- one connect to the next.
local _mode_override = {}

local function health_char(url)
  local s = _health[url] or "unknown"
  if s == "ok"         then return "*" end
  if s == "fail"       then return "x" end
  if s == "unresolved" then return "?" end
  return " "
end

local grip_dir = paths.grip_dir

local function configured_connections_path()
  local opts = require("dadbod-grip").get_opts()
  return opts.connections_path
end

local function connections_path()
  return configured_connections_path() or (grip_dir() .. "/connections.json")
end

local function global_connections_path()
  local home = vim.fn.expand("~")
  return home .. "/.grip/connections.json"
end

local function ensure_grip_dir()
  local custom = configured_connections_path()
  paths.ensure_dir(custom and vim.fn.fnamemodify(custom, ":h") or grip_dir())
end

local function ensure_global_grip_dir()
  paths.ensure_dir(vim.fn.expand("~") .. "/.grip")
end

-- Extensions that DuckDB can query directly (file-as-table).
local LOCAL_FILE_EXTS = {
  ".parquet", ".csv", ".tsv", ".json", ".ndjson", ".jsonl",
  ".xlsx", ".orc", ".arrow", ".ipc",
}

--- Detect if a URL or path points to a file DuckDB can query directly.
local function is_file_url(url)
  if not url or url == "" then return false end
  if url:match("^https?://") then return true end
  if url:match("^s3://") then return true end
  local lower = url:lower():gsub("[?#].*$", "")
  for _, ext in ipairs(LOCAL_FILE_EXTS) do
    if lower:sub(-#ext) == ext then return true end
  end
  return false
end

--- Returns true when a connection maps to a local file that filereadable() can test.
--- This includes DuckDB/SQLite file connections in addition to data-format files.
local function is_testable_locally(c)
  if not c then return false end
  if c._local_file or c.type == "file" then return true end
  if not c.url or c.url == "" then return false end
  if c._new or c._temp or c._section_header then return false end
  -- duckdb::memory: has no file to test
  if c.url == "duckdb::memory:" then return false end
  -- SQLite connections are always file-backed
  if c.url:match("^sqlite:") then return true end
  -- DuckDB file connections: duckdb:/path (double-colon = memory, already excluded)
  if c.url:match("^duckdb:[^:]") then return true end
  -- Data-format files (.csv, .parquet, etc.) accessed as local paths
  if is_file_url(c.url) and not c.url:match("^https?://") and not c.url:match("^s3://") then
    return true
  end
  return false
end

--- Strip scheme prefix from a connection URL to get the raw local filesystem path.
local function extract_local_path(url)
  if not url then return url end
  return (url:gsub("^sqlite://", ""):gsub("^sqlite:", "")
             :gsub("^duckdb://", ""):gsub("^duckdb:", ""))
end

--- Format a byte count for compact display (B / KB / MB / GB).
local function fmt_size(bytes)
  if not bytes or bytes < 0 then return "" end
  if bytes < 1024             then return tostring(bytes) .. " B"  end
  if bytes < 1048576          then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1073741824       then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.1f GB", bytes / 1073741824)
end

--- Scan cwd for supported data files and return them as picker-ready items.
--- Scans root of cwd and one level of subdirectories (data/, demo/, etc.).
--- Files are sorted alphabetically by display name.
local function scan_local_files()
  local cwd = vim.fn.getcwd()
  local result = {}
  local seen = {}
  for _, ext in ipairs(LOCAL_FILE_EXTS) do
    -- Root-level files: display as bare filename
    local root_files = vim.fn.glob(cwd .. "/*" .. ext, false, true)
    for _, path in ipairs(root_files) do
      if not seen[path] then
        seen[path] = true
        table.insert(result, {
          name        = vim.fn.fnamemodify(path, ":t"),
          url         = path,
          type        = "file",
          _local_file = true,
          size_bytes  = vim.fn.getfsize(path),
        })
      end
    end
    -- One level deep: display as "subdir/filename" so origin is clear
    local sub_files = vim.fn.glob(cwd .. "/*/*" .. ext, false, true)
    for _, path in ipairs(sub_files) do
      if not seen[path] then
        seen[path] = true
        local subdir = vim.fn.fnamemodify(path, ":h:t")
        local fname  = vim.fn.fnamemodify(path, ":t")
        table.insert(result, {
          name        = subdir .. "/" .. fname,
          url         = path,
          type        = "file",
          _local_file = true,
          size_bytes  = vim.fn.getfsize(path),
        })
      end
    end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

--- Short URL for display: strips credentials, keeps host/dbname or filename only.
local function short_url(url)
  if not url or url == "" then return url end
  -- duckdb::memory: stays as-is
  if url == "duckdb::memory:" then return "duckdb::memory:" end
  -- Strip credentials: scheme://user:pass@host → scheme://host
  local stripped = url:gsub("(://)[^:@/]*:[^@/]*@", "%1")
  stripped = stripped:gsub("(://)[^:@/]*@", "%1")
  -- For postgres/mysql: keep scheme://host/dbname only
  local pg = stripped:match("^(postgres[^:]*://[^/?]+/[^/?]+)")
    or stripped:match("^(mysql[^:]*://[^/?]+/[^/?]+)")
  if pg then
    local out = pg:gsub("^[^:]+://", "")  -- drop scheme
    if #out > 40 then out = out:sub(1, 39) .. "…" end
    return out
  end
  -- For sqlite/duckdb file paths: keep filename only
  local fname = stripped:match("([^/\\]+%.%a+)$")
  if fname then
    if #fname > 40 then fname = fname:sub(1, 39) .. "…" end
    return fname
  end
  -- Fallback: strip scheme, truncate
  local bare = stripped:gsub("^%a[%a%d+%-%.]*://", "")
  if bare == "" then bare = stripped end
  if #bare > 40 then bare = bare:sub(1, 39) .. "…" end
  return bare
end

--- Read connections from a JSON file.
local function read_json_connections(path, source)
  if vim.fn.filereadable(path) == 0 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  local result = {}
  for _, entry in ipairs(data) do
    if type(entry) == "table" and entry.name and entry.url then
      local c = { name = entry.name, url = entry.url,
                  type = entry.type, source = source or "file" }
      if entry.attachments then c.attachments = entry.attachments end
      if entry.last_used then c.last_used = entry.last_used end
      if entry.env_file then c.env_file = entry.env_file end
      if entry.mode then c.mode = entry.mode end
      if entry.color then c.color = entry.color end
      table.insert(result, c)
    end
  end
  return result
end

--- Read connections from the project-local file only.
--- Use this for all mutation paths (add, touch, remove, save_attachments).
--- Keeping mutation local-only prevents global connections from leaking into
--- the local file on every write.
local function read_local_connections()
  return read_json_connections(connections_path(), "file")
end

--- Read connections from project-local and global files (read-only paths only).
--- When connections_path is configured, reads ONLY that file (no global merge).
--- Do NOT pass this result to write_file_connections — use read_local_connections.
local function read_file_connections()
  if configured_connections_path() then
    return read_local_connections()
  end
  local result = {}
  for _, c in ipairs(read_local_connections()) do
    table.insert(result, c)
  end
  for _, c in ipairs(read_json_connections(global_connections_path(), "global")) do
    table.insert(result, c)
  end
  return result
end

-- ── secret expansion ──────────────────────────────────────────────────────

--- Find the saved entry for a connection URL, or nil when the URL is not a
--- saved connection (an ad-hoc :GripConnect URL, a g:dbs entry, ...).
---
--- Exists so db.lua can reach an entry's env_file without knowing where
--- connections are stored. Deliberately reads the JSON files directly rather
--- than going through M.list(): list() also runs Docker discovery, and this
--- sits on the query path -- db.resolve() calls it for every templated URL.
--- @param url string|nil
--- @return table|nil entry
function M.entry_for(url)
  if type(url) ~= "string" or url == "" then return nil end
  for _, c in ipairs(read_file_connections()) do
    if c.url == url then return c end
  end
  return nil
end

--- The read/write mode of a connection: "ro" or "rw", never nil.
---
--- "ro" only when the saved entry explicitly says `"mode": "ro"`. No entry
--- (an ad-hoc URL, a g:dbs entry), no `mode` field, or any other value all
--- mean "rw", so every connections.json written before this option existed
--- keeps behaving exactly as it did.
---
--- Called with no argument -- the adapters and the mode badge do -- it asks
--- about the connection currently in vim.b.db / vim.g.db, via the same
--- precedence db.get_url() uses. That is deliberately the *template* URL:
--- entries are keyed by the template on disk, so looking up an expanded
--- "${VAR}" URL would find nothing and silently downgrade a ro connection to
--- rw. Callers that already hold a stored URL (db.is_readonly) pass it in.
--- A session override set by the picker's r:ro/rw action wins over the stored
--- field, for that connection only and only until it is switched to again.
--- @param url string|nil  a stored (templated) URL; defaults to the current connection
--- @return string  "ro" or "rw"
function M.current_mode(url)
  -- Lazy require: db.lua reaches back into this module for expand_url.
  local conn = require("dadbod-grip.db").get_url(url)
  local override = conn and _mode_override[conn]
  if override then return override end
  local entry = M.entry_for(conn)
  return (entry and entry.mode == "ro") and "ro" or "rw"
end

--- Refuse a schema-modifying action on a connection saved with "mode": "ro".
--- Returns true when the caller must stop.
---
--- This is the layer that refuses *before* the prompt: every DDL path in the
--- plugin opens an interactive form or a typed confirmation first, and walking
--- a user through one only to have it fail at the end is a worse answer than
--- declining up front.
---
--- It is a guard, not a boundary, and the difference matters. The adapters do
--- put the CLI session itself in read-only mode, which usually means the
--- server would refuse the statement even if this returned false -- but not
--- always: a postgres URL that already carries its own `options=` overrides
--- PGOPTIONS (see psql_env), and sqlite/duckdb pointed at a not-yet-existing
--- file get no `-readonly` at all, by design. Treat this as the thing that
--- keeps a read-only connection honest in ordinary use, not as something a
--- caller may rely on to make a write impossible.
---
--- Lives here rather than in init.lua because the DDL entry points are spread
--- across the command layer, the schema sidebar, the properties float and the
--- grid's inspect keymaps; one wording for all of them is the point.
---
--- The message names the mode and never the URL -- it can carry a password.
--- @param label string  the command or action name to prefix the message with
--- @param url string|nil  defaults to the current connection
--- @return boolean
function M.deny_if_readonly(label, url)
  if M.current_mode(url) ~= "ro" then return false end
  vim.notify(label .. ": Connection is read-only (mode = ro)", vim.log.levels.WARN)
  return true
end

--- Resolve the ${VAR} placeholders in a connection URL against the env_file
--- of its saved entry (falling back to the process environment).
---
--- The expanded URL carries the live password, so it exists in exactly two
--- kinds of place: the argv/env of the database CLI, and the local variable
--- that got it there. vim.g.db, vim.b.db, connections.json and the query
--- history all keep the *template* -- db.resolve() calls this at the single
--- point where a URL is handed to an adapter, which is why no write path in
--- the plugin can spill a secret. Do not push the expansion outward.
---
--- A URL with no placeholder is returned unchanged without touching the
--- filesystem, so ordinary literal connections cost exactly what they did
--- before.
--- @param url string|nil
--- @return string|nil expanded  nil only when expansion failed
--- @return string|nil err
function M.expand_url(url)
  if type(url) ~= "string" or not secrets.has_template(url) then return url end
  return secrets.expand(url, M.entry_for(url))
end

--- Resolve the ${VAR} placeholders in a persisted DuckDB attachment DSN.
---
--- Attachment DSNs are stored templated (see M.save_attachments), so the
--- password of an attached postgres/mysql database never lands in
--- connections.json either. Variables resolve against the attached
--- connection's own entry when the stored string is itself a saved
--- connection URL -- how the `a:attach` picker action stores it -- and
--- otherwise against the entry of the DuckDB connection the attachment hangs
--- off, which is what a DSN typed straight into :GripAttach gets.
--- @param dsn string|nil
--- @param host_url string|nil the DuckDB connection URL, as stored (templated)
--- @return string|nil expanded
--- @return string|nil err
function M.expand_dsn(dsn, host_url)
  if type(dsn) ~= "string" or not secrets.has_template(dsn) then return dsn end
  return secrets.expand(dsn, M.entry_for(dsn) or M.entry_for(host_url))
end

--- Write connections to .grip/connections.json.
--- Deduplicates by URL before writing, keeping the entry with the highest
--- last_used timestamp. This self-heals files bloated by historical bugs.
local function write_file_connections(conns)
  ensure_grip_dir()
  -- Dedup by URL: keep highest last_used per URL
  local order = {}
  local by_url = {}
  for _, c in ipairs(conns) do
    if not by_url[c.url] then
      by_url[c.url] = c
      table.insert(order, c.url)
    elseif (c.last_used or 0) > (by_url[c.url].last_used or 0) then
      by_url[c.url] = c
    end
  end
  local data = {}
  for _, url in ipairs(order) do
    local c = by_url[url]
    local entry = { name = c.name, url = c.url }
    if c.type then entry.type = c.type end
    if c.attachments and #c.attachments > 0 then entry.attachments = c.attachments end
    if c.last_used then entry.last_used = c.last_used end
    if c.env_file then entry.env_file = c.env_file end
    if c.mode then entry.mode = c.mode end
    if c.color then entry.color = c.color end
    table.insert(data, entry)
  end
  local json = vim.fn.json_encode(data)
  vim.fn.writefile({ json }, connections_path())
end

--- Read g:dbs (DBUI-compatible: list or dict of connections).
--- Supports: {name, url} dicts, plain URL strings, and {name = url} dicts.
local function read_gdbs()
  local dbs = vim.g.dbs
  if type(dbs) ~= "table" then return {} end
  local result = {}
  for key, entry in pairs(dbs) do
    if type(entry) == "table" and entry.name and entry.url then
      -- Standard format: { name = "foo", url = "postgresql://..." }
      table.insert(result, { name = entry.name, url = entry.url, source = "g:dbs" })
    elseif type(entry) == "string" then
      -- Plain URL string in a list, or {name = "url"} dict
      if type(key) == "string" then
        -- Dict format: { customer_name = "postgresql://..." }
        table.insert(result, { name = key, url = entry, source = "g:dbs" })
      else
        -- List format: { "postgresql://host/db" }
        local name = entry:match("([^/]+)$") or entry
        table.insert(result, { name = name, url = entry, source = "g:dbs" })
      end
    end
  end
  return result
end

--- Read live local DB containers (Docker labels). Empty list when the
--- discovery option is disabled, docker is unavailable, or the daemon is
--- down. Never throws.
local function read_discovered_connections()
  local opts = require("dadbod-grip").get_opts()
  if opts.discovery == false then return {} end
  local ok, mod = pcall(require, "dadbod-grip.sources.docker_localdb")
  if not ok then return {} end
  local result = mod.fetch()
  return result and result.connections or {}
end

--- List all connections from all sources, deduplicated by URL and name.
function M.list()
  local all = {}
  local seen = {}  -- keyed by URL; URL is the canonical identifier

  -- Discovered connections first: live containers beat hand-edited static.
  -- A user spinning up `just up` expects to see that stack at the top.
  for _, c in ipairs(read_discovered_connections()) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
  end

  -- File connections second (user-managed, sorted by last_used in pick())
  for _, c in ipairs(read_file_connections()) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
  end

  -- g:dbs (DBUI compat): also persist globally for cross-project access
  local gdbs = read_gdbs()
  local new_global = false
  local global_existing = read_json_connections(global_connections_path(), "global")
  local global_seen = {}
  for _, gc in ipairs(global_existing) do global_seen[gc.url] = true end

  for _, c in ipairs(gdbs) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
    -- Persist to global if not already there
    if not global_seen[c.url] then
      table.insert(global_existing, { name = c.name, url = c.url })
      global_seen[c.url] = true
      new_global = true
    end
  end

  -- Write global file if new entries were added
  if new_global then
    ensure_global_grip_dir()
    local gdata = {}
    for _, gc in ipairs(global_existing) do
      local gentry = { name = gc.name, url = gc.url }
      if gc.type then gentry.type = gc.type end
      if gc.env_file then gentry.env_file = gc.env_file end
      if gc.mode then gentry.mode = gc.mode end
      if gc.color then gentry.color = gc.color end
      table.insert(gdata, gentry)
    end
    vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_connections_path())
  end

  -- Mark any connection whose URL is in the global file as source = "global".
  -- When a URL exists in both local and global files, the local entry wins the
  -- dedup above (local is read first), so its source stays "file". This pass
  -- corrects that: if a URL is in global, it gets the [g] badge regardless of
  -- which file was deduped first.
  for _, c in ipairs(all) do
    if global_seen[c.url] then
      c.source = "global"
    end
  end

  -- $DATABASE_URL
  local env_url = os.getenv("DATABASE_URL")
  if env_url and env_url ~= "" and not seen[env_url] then
    seen[env_url] = true
    table.insert(all, { name = "$DATABASE_URL", url = env_url, source = "env" })
  end

  -- Current vim.g.db (if set and not already listed by URL)
  local gdb = vim.g.db
  if type(gdb) == "string" and gdb ~= "" and not seen[gdb] then
    seen[gdb] = true
    table.insert(all, { name = "vim.g.db", url = gdb, source = "global" })
  end

  -- ── Starter connections: shown until dismissed or already present ──────
  local data_dir = vim.fn.stdpath("data") .. "/grip"
  local has_duck = vim.fn.executable("duckdb") == 1

  local starters = {
    {
      id   = "duckdb_memory",
      name = "DuckDB (memory)  · read files; no cross-query state",
      url  = "duckdb::memory:",
      cond = has_duck,
    },
    {
      id   = "duckdb_scratch",
      name = "DuckDB (scratch) · /tmp/grip_scratch.duckdb",
      url  = "duckdb:/tmp/grip_scratch.duckdb",
      cond = has_duck,
    },
    {
      id   = "sqlite_scratch",
      name = "SQLite  (scratch) · /tmp/grip_scratch.db",
      url  = "sqlite:/tmp/grip_scratch.db",
      cond = true,
    },
  }
  for _, s in ipairs(starters) do
    local hidden_f = data_dir .. "/" .. s.id .. ".hidden"
    if s.cond and not seen[s.url] and vim.fn.filereadable(hidden_f) == 0 then
      table.insert(all, { name = s.name, url = s.url, _builtin_id = s.id })
    end
  end

  -- Softrear Inc. Analyst Portal™: built-in demo, shown until dismissed or
  -- until the user switches to it (after which it's persisted as a regular
  -- file connection and `seen[demo_url]` suppresses this entry).
  local hidden = vim.fn.stdpath("data") .. "/grip/softrear.hidden"
  local sql_files = vim.api.nvim_get_runtime_file("demo/softrear.sql", false)
  if #sql_files > 0 and vim.fn.filereadable(hidden) == 0 then
    local ext      = has_duck and ".duckdb" or ".db"
    local db_path  = vim.fn.stdpath("data") .. "/grip/softrear" .. ext
    local demo_url = (has_duck and "duckdb:" or "sqlite:") .. db_path
    if not seen[demo_url] then  -- suppress once persisted as a real connection
      local seed = has_duck and sql_files[1]
        or (vim.api.nvim_get_runtime_file("demo/softrear_sqlite.sql", false)[1] or "")
      table.insert(all, {
        name      = "Softrear Inc. Analyst Portal\xe2\x84\xa2",
        url       = demo_url,
        _is_demo  = true,
        _demo_sql = seed,
      })
    end
  end

  return all
end

--- Mark a connection URL as healthy or failed for the current session.
--- Called by M.switch() on success/failure and by the T retest action in the picker.
function M.set_health(url, status)
  _health[url] = status
end

--- Return the current session health for a URL: "ok" | "fail" | "unresolved" | "unknown".
function M.get_health(url)
  return _health[url] or "unknown"
end

--- Strip session-only flags from a URL before persisting.
--- --write / --watch / --watch=Ns must never reach connections.json.
local function strip_flags(url)
  if not url then return url end
  url = url:gsub("%s*%-%-write%s*", " ")
  url = url:gsub("%s*%-%-watch=%d+s?%s*", " ")
  url = url:gsub("%s*%-%-watch%s*", " ")
  return vim.trim(url)
end

--- Upsert a connection by URL into an in-memory list: renames in place if the
--- URL is already present, otherwise inserts a new entry. Pure (no I/O) so it
--- can be shared by M.add() and M.switch()'s single-read/single-write path.
local function upsert_conn(conns, name, url)
  for _, c in ipairs(conns) do
    if c.url == url then
      c.name = name
      if is_file_url(url) then c.type = "file" end
      return
    end
  end
  local conn_type = is_file_url(url) and "file" or nil
  table.insert(conns, { name = name, url = url, type = conn_type })
end

--- Update last_used on a matching entry in an in-memory list (MRU tracking).
--- Pure (no I/O). Returns true when a match was found and updated.
local function touch_conn(conns, url)
  for _, c in ipairs(conns) do
    if c.url == url then
      c.last_used = os.time()
      return true
    end
  end
  return false
end

--- Add (or rename) a connection in .grip/connections.json.
--- Upsert by URL: if the URL already exists, updates name and type in place,
--- preserving last_used and attachments. Prevents accumulation of duplicates
--- and correctly handles "rename on next switch" (e.g. vim.g.db → proper name).
function M.add(name, url)
  local clean_url = strip_flags(url)
  local conns = read_local_connections()
  upsert_conn(conns, name, clean_url)
  write_file_connections(conns)
end

--- Update last_used timestamp for a saved connection (MRU tracking).
function M.touch(url)
  local clean = strip_flags(url)
  local conns = read_local_connections()
  if touch_conn(conns, clean) then
    write_file_connections(conns)
  end
end

--- Remove a connection from .grip/connections.json by name.
function M.remove(name)
  local conns = read_local_connections()
  local filtered = {}
  for _, c in ipairs(conns) do
    if c.name ~= name then
      table.insert(filtered, c)
    end
  end
  write_file_connections(filtered)
end

--- Switch active connection. Routes file connections through grip.open(),
--- DB connections through vim.g.db + workspace open.
--- Auto-saves to .grip/connections.json if not already persisted.
--- opts: { write = bool, watch_ms = number, mode = "ro"|"rw" }: session-only,
--- never persisted.
--- @return boolean committed  false when the switch aborted and nothing changed
function M.switch(url, name, conn_type, opts)
  -- Strip session-only flags: they must never reach the connection registry
  url = strip_flags(url)

  -- Resolve ${VAR} placeholders up front, before anything is mutated or
  -- written: a connection whose .env is missing or still git-crypt-locked
  -- must fail cleanly instead of leaving a half-switched session behind.
  -- `url` itself stays the template -- that is what gets persisted, what
  -- vim.g.db holds, and what every later lookup keys on. conn_url is only
  -- needed by the DuckDB attachment paths below, which bypass db.resolve().
  local conn_url, secret_err = M.expand_url(url)
  if not conn_url then
    -- Same distinct marker T:test sets, for the same reason: the picker has
    -- to say "this one could not resolve its secret" rather than the generic
    -- "x" of a database that is genuinely unreachable. Connecting is how most
    -- people meet this failure, so the attempt has to record it too --
    -- otherwise the user presses <CR>, reads an error, reopens the picker and
    -- finds nothing to show for it.
    M.set_health(url, "unresolved")
    vim.notify("Grip: " .. (secret_err or "could not resolve connection secrets"),
      vim.log.levels.ERROR)
    return false
  end

  -- Single read of the local file; everything below (type resolution,
  -- rename/insert, MRU touch) mutates this same in-memory list, and it is
  -- written back at most once at the end instead of once per mutation.
  local local_conns = read_local_connections()

  -- Resolve type: param > local connections > global connections > auto-detect.
  -- The global file is only read when actually needed for the lookup, since
  -- most callers already pass conn_type or have a locally-known type.
  local resolved_type = conn_type
  if not resolved_type then
    for _, c in ipairs(local_conns) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and not configured_connections_path() then
    for _, c in ipairs(read_json_connections(global_connections_path(), "global")) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and is_file_url(url) then
    resolved_type = "file"
  end

  -- Always upsert when a name is provided. This handles both insert (new
  -- URL) and rename (existing URL with a stale generic name like "vim.g.db").
  -- Without this, an already-saved URL would keep a stale name forever even
  -- when switching with the correct one.
  local changed = false
  if name and name ~= "" then
    upsert_conn(local_conns, name, url)
    changed = true
  end
  -- Touch AFTER upsert so first-time connections get last_used stamped.
  if touch_conn(local_conns, url) then
    changed = true
  end
  if changed then
    write_file_connections(local_conns)
  end

  -- The one place a mode override is set or cleared. Connecting the ordinary
  -- way always returns a connection to the mode its entry asks for, so an
  -- override taken by mistake is undone by reconnecting rather than by
  -- editing connections.json.
  --
  -- Below the expansion check above, deliberately: a switch that aborted did
  -- not happen, and must leave the mode of that URL exactly as it found it.
  -- Set any earlier and an `r` on an entry whose ${VAR} does not resolve
  -- would flip a read-only connection the user is still on to writable, with
  -- only a "could not resolve secrets" message to go on.
  _mode_override[url] = nil
  if opts and (opts.mode == "ro" or opts.mode == "rw") then
    _mode_override[url] = opts.mode
  end

  -- Say so, once per connect, when this particular connection cannot keep the
  -- read-only promise the rest of the UI is about to make for it. Everything
  -- downstream -- the RO badge, the DDL refusals -- reads the entry rather
  -- than what the server was actually told, so silence here leaves the one
  -- connection with a writable session looking the most protected of all.
  --
  -- Below the override, so an `r`-toggle to ro warns and a toggle to rw does
  -- not. Asked of conn_url, not the template: the `options=` can arrive inside
  -- a ${VAR}. Lazy require -- adapters reaches back into this module.
  if M.current_mode(url) == "ro" then
    local caveat = require("dadbod-grip.adapters").readonly_caveat(conn_url)
    if caveat then
      vim.notify("Grip: read-only is not enforced on this connection -- " .. caveat,
        vim.log.levels.WARN)
    end
  end

  -- Re-tint the accent groups for the connection being switched to. Read
  -- after the write above so a just-added entry is found, and passed
  -- unconditionally: an entry with no `color` (or no entry at all) has to
  -- restore the default look, not inherit the previous connection's.
  local view = require("dadbod-grip.view")
  local switched_entry = M.entry_for(url)
  view.set_connection_accent(switched_entry and switched_entry.color)
  -- A switch changes what current_mode() answers, so every grid still open
  -- has to ask again. Their badges are cached per session precisely because
  -- the winbar is rebuilt on every cursor move; a switch is the one other
  -- moment the cached answer can be wrong.
  view.invalidate_mode_cache()

  if resolved_type == "file" then
    vim.notify("Grip: opening " .. (name or url), vim.log.levels.INFO)
    M.set_health(url, "ok")
    -- Compute the DuckDB connection that will actually run queries against this file.
    -- Mirrors the logic in init.lua so the query pad is wired to the same connection.
    -- The scheme test needs the resolved URL (a whole-URL template hides it);
    -- the pad is still bound to the template, which db.resolve() expands.
    local active = vim.g.db
    local active_resolved = active and (M.expand_url(active) or active)
    local db_url = (active_resolved and active_resolved:match("^duckdb:")) and active
      or "duckdb::memory:"
    vim.schedule(function()
      -- No reuse_win: let find_content_win() place the grid correctly.
      -- Passing cur_win risks putting the grid in the sidebar if that window was focused.
      local open_opts = {}
      if opts and opts.write    then open_opts.write    = true       end
      if opts and opts.watch_ms then open_opts.watch_ms = opts.watch_ms end
      require("dadbod-grip").open(url, nil, open_opts)
      -- Open sidebar and query pad after the grid is placed
      vim.schedule(function()
        local schema = require("dadbod-grip.schema")
        if not schema.is_open() then
          schema.toggle(url)
        else
          schema.refresh(url)
        end
        require("dadbod-grip.query_pad").open(db_url)
      end)
    end)
    return true
  end

  -- Regular DB connection: set vim.g.db and open full workspace
  vim.g.db = url

  -- Restore persisted attachments for DuckDB connections (local file only;
  -- attachments are always saved to local by M.save_attachments).
  --
  -- One of the four paths that bypass db.resolve(), so it expands by hand:
  -- the adapter's attachment registry is keyed by the URL the adapter is
  -- called with, which is the *expanded* one on every query, and the stored
  -- DSNs are templates that only become connectable here.
  if conn_url:find("^duckdb:") then
    local stored_atts
    for _, c in ipairs(local_conns) do
      if c.url == url and c.attachments then
        stored_atts = c.attachments
        break
      end
    end
    if stored_atts then
      local live_atts = {}
      for _, a in ipairs(stored_atts) do
        local stored_dsn = type(a) == "table" and a.dsn or nil
        if type(stored_dsn) ~= "string" then
          -- Nothing to expand: hand the record on exactly as it was read and
          -- let load_attachments deal with whatever shape it is, as before.
          table.insert(live_atts, a)
        else
          local dsn, dsn_err = M.expand_dsn(stored_dsn, url)
          if dsn then
            -- template is carried through so the next save_attachments()
            -- writes the placeholder back, not what it resolved to.
            table.insert(live_atts, {
              dsn = dsn, alias = a.alias, template = dsn ~= stored_dsn and stored_dsn or nil,
            })
          else
            vim.notify(string.format("Skipped attachment '%s': %s", a.alias, dsn_err),
              vim.log.levels.WARN)
          end
        end
      end
      require("dadbod-grip.adapters.duckdb").load_attachments(conn_url, live_atts)
    end
  end

  vim.notify("Grip: connected to " .. (name or url), vim.log.levels.INFO)
  M.set_health(url, "ok")
  -- Invalidate completion cache so the new connection's schema is fetched fresh.
  require("dadbod-grip.completion").invalidate(url)

  vim.schedule(function()
    local schema = require("dadbod-grip.schema")
    if not schema.is_open() then
      schema.toggle(url)
    else
      schema.refresh(url)
    end

    -- Show welcome screen in the main content area
    require("dadbod-grip").open_welcome()

    local query_pad = require("dadbod-grip.query_pad")
    query_pad.open(url)

    -- Focus sidebar so user can immediately browse tables
    if schema.is_open() and schema.get_winid() then
      vim.api.nvim_set_current_win(schema.get_winid())
    end

    -- Pre-warm completion schema cache in background (avoids freeze on first keypress)
    vim.schedule(function()
      pcall(function()
        require("dadbod-grip.completion").warm_schema(url)
      end)
    end)

  end)
  return true
end

--- Get current connection info.
function M.current()
  local url = vim.g.db
  if type(url) ~= "string" or url == "" then
    url = os.getenv("DATABASE_URL")
  end
  if not url or url == "" then return nil end

  -- Try to find name from known connections
  for _, c in ipairs(M.list()) do
    if c.url == url then
      return { name = c.name, url = c.url }
    end
  end
  return { name = nil, url = url }
end

--- Persist attachments for a DuckDB connection URL.
--- Called after attach/detach to update .grip/connections.json.
---
--- `url` is the connection URL as stored (templated), since that is the key
--- the entry lives under on disk; the live adapter registry is keyed by the
--- expanded URL, so callers pass the two separately.
---
--- Each record is persisted as `a.template or a.dsn`: a live attachment
--- record carries the expanded, password-bearing DSN, and writing that here
--- would put the password on disk through a field nothing else covers. The
--- template is resolved again on replay by M.switch/expand_dsn. Records with
--- no template (a literal DSN) round-trip byte-identically, as before.
function M.save_attachments(url, attachments)
  local file_conns = read_local_connections()
  local found = false
  for _, c in ipairs(file_conns) do
    if c.url == url then
      c.attachments = attachments and #attachments > 0 and {} or nil
      if attachments then
        for _, a in ipairs(attachments) do
          table.insert(c.attachments, { dsn = a.template or a.dsn, alias = a.alias })
        end
      end
      found = true
      break
    end
  end
  if found then
    write_file_connections(file_conns)
  end
end

--- Prompt user to enter a new connection URL + name, then switch to it.
--- True when the picker's `r` (ro/rw) action applies to this row.
---
--- Shared by the action's `when` and its `fn`: grip_picker fires `fn`
--- regardless of `when`, so both need the same answer, and a second
--- hand-written copy of these conditions is how the two drift apart.
--- @param c table picker item
--- @return boolean
local function ro_toggle_applies(c)
  if c._new or c._temp or c._section_header or c._local_file then return false end
  -- A file connection has no server session to put in read-only mode;
  -- !:write is the flag that matters there.
  if c.type == "file" or (not c.type and is_file_url(c.url)) then return false end
  -- SQL Server is read-only at the adapter (adapters/sqlserver.lua:9), so
  -- offering to toggle its mode would promise a write path that does not
  -- exist. Resolved first: a whole-URL template hides the scheme, and an
  -- unresolvable one falls back to the template, which simply does not match.
  local target = M.expand_url(c.url) or c.url
  return not target:find("^sqlserver:")
end

local function prompt_new_connection()
  local url = ui.input({ prompt = "Connection URL, file path, or s3://: " })
  if not url then
    require("dadbod-grip").open_welcome(); return
  end

  local name = ui.input({ prompt = "Connection name: " })
  if not name then
    require("dadbod-grip").open_welcome(); return
  end

  M.add(name, url)
  M.switch(url, name)
end

--- Connect once without saving to connections.json.
--- Passes nil name so M.switch() skips the auto-persist path.
local function prompt_temp_connection()
  local url = ui.input({ prompt = "Connect once (URL, not saved): " })
  if not url then
    require("dadbod-grip").open_welcome(); return
  end
  -- nil name → M.switch() won't auto-persist (see "if not already_saved and name" guard)
  M.switch(url, nil, nil, nil)
end

--- Open a picker to select and switch connection. Uses grip_picker (zero external deps).
--- @param opts? { on_cancel?: function }  optional overrides; default on_cancel = open_welcome
function M.pick(opts)
  opts = opts or {}
  local on_cancel = opts.on_cancel or function() require("dadbod-grip").open_welcome() end
  local conns = M.list()
  if #conns == 0 then
    prompt_new_connection()
    return
  end

  -- Sort file-backed connections (file + global) by most recently used first,
  -- with non-file-backed sources (e.g. vim.g.db env var) sorted last.
  local function is_file_backed(c)
    return c.source == "file" or c.source == "global"
  end
  table.sort(conns, function(a, b)
    local af, bf = is_file_backed(a), is_file_backed(b)
    if af ~= bf then return af end
    if af and bf then
      return (a.last_used or 0) > (b.last_used or 0)
    end
    return false
  end)

  -- Scan cwd for local data files (CSV, Parquet, JSON, etc.)
  local local_files = scan_local_files()

  local max_name = 0
  for _, c in ipairs(conns) do
    max_name = math.max(max_name, vim.fn.strdisplaywidth(c.name))
  end
  for _, f in ipairs(local_files) do
    max_name = math.max(max_name, vim.fn.strdisplaywidth(f.name))
  end

  -- Sentinel items at bottom of list
  local new_sentinel  = { name = "+ New connection...",          url = "", _new  = true }
  local temp_sentinel = { name = "~ Connect once (no save)...", url = "", _temp = true }

  -- Does any listed entry default to read-only? Set by build_picker_items and
  -- read by display: the RO column only exists when something is in it, so a
  -- picker with no ro entry renders byte-identically to how it always has.
  local any_ro = false

  -- Build the full item list with scope sections.
  -- When at least one global connection exists and connections_path is not set,
  -- connections are grouped under "global" and "project" section headers so the
  -- user can immediately see which connections are shared across projects.
  -- Called at open time and from on_delete to refresh after a deletion.
  local function build_picker_items()
    local fresh = M.list()
    local use_sections = not configured_connections_path()

    local global_conns, project_conns, other_conns = {}, {}, {}
    for _, c in ipairs(fresh) do
      if c._builtin_id or c._is_demo then
        table.insert(other_conns, c)
      elseif c.source == "global" then
        table.insert(global_conns, c)
      elseif c.source == "file" then
        table.insert(project_conns, c)
      else
        table.insert(other_conns, c)
      end
    end

    local function sort_mru(t)
      table.sort(t, function(a, b) return (a.last_used or 0) > (b.last_used or 0) end)
    end
    sort_mru(global_conns)
    sort_mru(project_conns)

    local out = {}
    local show_headers = use_sections and #global_conns > 0

    if show_headers then
      table.insert(out, { name = "global", url = "", _section_header = true })
      for _, c in ipairs(global_conns) do table.insert(out, c) end
      table.insert(out, { name = "project", url = "", _section_header = true })
      for _, c in ipairs(project_conns) do table.insert(out, c) end
    else
      -- Flat list: file-backed MRU first, then others
      local flat = {}
      for _, c in ipairs(global_conns)  do table.insert(flat, c) end
      for _, c in ipairs(project_conns) do table.insert(flat, c) end
      sort_mru(flat)
      for _, c in ipairs(flat) do table.insert(out, c) end
    end

    for _, c in ipairs(other_conns) do table.insert(out, c) end

    local fresh_files = scan_local_files()
    if #fresh_files > 0 then
      table.insert(out, { name = "Local Files (cwd)", url = "", _section_header = true })
      for _, f in ipairs(fresh_files) do table.insert(out, f) end
    end
    table.insert(out, new_sentinel)
    table.insert(out, temp_sentinel)
    any_ro = false
    for _, c in ipairs(out) do
      if c.mode == "ro" then any_ro = true; break end
    end
    return out
  end

  local picker_items = build_picker_items()

  -- Track which connection URLs have password reveal active
  local show_pass = {}

  require("dadbod-grip.grip_picker").open({
    title = "Connections",
    items = picker_items,
    on_cancel = on_cancel,
    display = function(c)
      if c._section_header then
        return "  " .. c.name
      end
      if c._new or c._temp then
        return "  " .. c.name
      end
      if c._local_file then
        local pad = string.rep(" ", max_name - vim.fn.strdisplaywidth(c.name))
        return "  " .. c.name .. pad .. "  " .. fmt_size(c.size_bytes)
      end
      local dot = health_char(c.url)
      local pad = string.rep(" ", max_name - vim.fn.strdisplaywidth(c.name))
      local url_display = show_pass[c.url] and c.url or short_url(c.url)
      -- The entry's stored default, not what r:ro/rw may have overridden for
      -- this session: this row answers "how does this connection open", and
      -- the winbar answers "how is it open right now".
      --
      -- Its own column, ahead of the URL, because it is a property of the
      -- entry like the health dot -- and because grip_picker truncates a row
      -- that overruns the float, which ate the marker outright when it
      -- trailed the URL: long production names and long hosts are exactly the
      -- rows most likely to be read-only, and M:mask lengthens them further.
      local ro = any_ro and (c.mode == "ro" and "RO " or "   ") or ""
      return dot .. " " .. c.name .. pad .. "  " .. ro .. url_display
    end,
    on_select = function(c)
      if c._section_header then return end
      if c._new then
        prompt_new_connection()
      elseif c._temp then
        prompt_temp_connection()
      elseif c._local_file then
        M.switch(c.url, nil, "file", { write = true })
      else
        -- Lazy-seed the portal DB on first selection
        if c._is_demo and c._demo_sql and c._demo_sql ~= "" then
          local db_path = c.url:gsub("^duckdb:", ""):gsub("^sqlite:", "")
          if vim.fn.filereadable(db_path) == 0 then
            vim.fn.mkdir(vim.fn.fnamemodify(db_path, ":h"), "p")
            local bin = db_path:match("%.duckdb$") and "duckdb" or "sqlite3"
            vim.fn.system(bin .. " " .. vim.fn.shellescape(db_path)
              .. " < " .. vim.fn.shellescape(c._demo_sql))
          end
          -- Persist with name so MRU tracking works on every future selection
          M.switch(c.url, c.name)
        else
          M.switch(c.url, c.name, c.type)
        end
      end
    end,
    on_delete = function(c, refresh_fn)
      if c._new or c._temp or c._section_header or c._local_file then return end
      -- Starter built-in: write a hidden flag so it never appears again
      if c._builtin_id then
        if ui.confirm("Remove '" .. c.name .. "'? (y/N): ") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/" .. c._builtin_id .. ".hidden")
          refresh_fn(build_picker_items())
        end
        return
      end
      -- Portal deletion: write a flag file so it never appears again
      if c._is_demo then
        if ui.confirm("Remove Softrear Portal? (y/N): ") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/softrear.hidden")
          refresh_fn(build_picker_items())
        end
        return
      end
      if ui.confirm("Remove '" .. c.name .. "'? (y/N): ") then
        M.remove(c.name)
        refresh_fn(build_picker_items())
      end
    end,
    actions = {
      {
        key            = "!",
        label          = "!:write",
        close_on_select = true,
        when           = function(c)
          return not c._new and not c._temp and not c._section_header and not c._local_file
              and (c.type == "file" or (not c.type and is_file_url(c.url)))
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          M.switch(c.url, c.name, c.type, { write = true })
        end,
      },
      {
        key            = "W",
        label          = "W:watch",
        close_on_select = true,
        when           = function(c)
          return not c._new and not c._temp and not c._section_header and not c._local_file
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          M.switch(c.url, c.name, c.type, { watch_ms = 5000 })
        end,
      },
      {
        key   = "M",
        label = "M:mask",
        when  = function(c)
          return not c._new and not c._temp and not c._section_header and not c._local_file
        end,
        fn    = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          if show_pass[c.url] then
            show_pass[c.url] = nil
          else
            show_pass[c.url] = true
          end
        end,
      },
      {
        key            = "a",
        label          = "a:attach",
        close_on_select = true,
        when           = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return false end
          -- Show on non-DuckDB connections when current connection is DuckDB.
          -- Both URLs are resolved first: a whole-URL template hides the
          -- scheme, and without this the action is hidden on a templated
          -- DuckDB connection even though its fn below handles one.
          local cur = vim.g.db
          cur = cur and (M.expand_url(cur) or cur)
          local target = M.expand_url(c.url) or c.url
          if not (cur and cur:find("^duckdb:")) or target:find("^duckdb:") then return false end
          -- Hide it outright for databases DuckDB has no scanner for (SQL
          -- Server, Oracle, ...) rather than offering an action that can only
          -- fail. M.attach refuses those too, for the :GripAttach path.
          local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
          return duckdb_adapter._unsupported_attach_scheme(duckdb_adapter.url_to_dsn(target)) == nil
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          -- Guard: grip_picker fires fn regardless of `when` predicate label
          -- url is the active connection as stored (templated: the key on
          -- disk); conn_url is what the adapter registry is keyed by. One of
          -- the four paths that bypass db.resolve(), so both the DuckDB URL
          -- and the target's URL are expanded by hand here.
          local url = vim.g.db
          local conn_url = M.expand_url(url)
          if not conn_url or not conn_url:find("^duckdb:") then
            vim.notify(
              "Attach requires an active DuckDB connection. Switch to DuckDB with gc first.",
              vim.log.levels.WARN)
            return
          end
          local target_url, target_err = M.expand_url(c.url)
          if not target_url then
            vim.notify("Attach failed: " .. (target_err or "unresolved connection secrets"),
              vim.log.levels.ERROR)
            return
          end
          local default_alias = c.name:lower():gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
          local alias = ui.input({ prompt = "Attach as alias: ", default = default_alias })
          if not alias then return end
          local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
          local schema_mod = require("dadbod-grip.schema")
          local dsn = duckdb_adapter.url_to_dsn(target_url)
          -- Persist the connection's own URL template, not the DSN derived
          -- from it: M.expand_dsn() finds this entry's env_file by that URL,
          -- and load_attachments() runs url_to_dsn() again on replay.
          local template = target_url ~= c.url and c.url or nil
          local err = duckdb_adapter.attach(conn_url, dsn, alias, template)
          if err then
            vim.notify("Attach failed: " .. err, vim.log.levels.ERROR)
            return
          end
          M.save_attachments(url, duckdb_adapter.get_attachments(conn_url))
          schema_mod.refresh(url)
          vim.notify(string.format("Attached '%s' as %s", c.name, alias), vim.log.levels.INFO)
        end,
      },
      {
        -- T: retest connection health. File-backed connections use filereadable()
        -- for instant feedback; network DBs run SELECT 1 via db.ping() with a 5s timeout.
        key   = "T",
        label = "T:test",
        when  = function(c) return not (c._new or c._temp or c._section_header) end,
        fn    = function(c)
          if c._new or c._temp or c._section_header then return end
          -- A templated entry must report *why* it can't be tested, not a
          -- meaningless "Unsupported database scheme: ${VAR}" from handing
          -- the literal placeholder to the adapter.
          local conn_url, secret_err = M.expand_url(c.url)
          if not conn_url then
            M.set_health(c.url, "unresolved")
            vim.notify("Grip: " .. (secret_err or "could not resolve connection secrets"),
              vim.log.levels.ERROR)
            return
          end
          -- Scheme detection (is_testable_locally) needs the resolved URL for
          -- a whole-URL template, same reasoning as a:attach above.
          local test_target = conn_url == c.url and c
            or vim.tbl_extend("force", {}, c, { url = conn_url })
          if is_testable_locally(test_target) then
            local path = extract_local_path(conn_url)
            M.set_health(c.url, vim.fn.filereadable(path) == 1 and "ok" or "fail")
          else
            -- db.ping is given the URL *as stored*, not the expansion above:
            -- it resolves internally, and everything else it consults keys on
            -- the template. Handing it the expanded URL made
            -- current_mode(expanded) find no entry and report "rw", so a
            -- connection saved "mode": "ro" got pinged with a writable
            -- session -- the one place in this feature that looked a
            -- connection up by anything but the template.
            local ok = require("dadbod-grip.db").ping(c.url)
            M.set_health(c.url, ok and "ok" or "fail")
          end
        end,
      },
      {
        -- G: promote a project-local connection to the global file (~/.grip/connections.json)
        -- so it appears in every project's picker without re-adding it each time.
        key   = "G",
        label = "G:global",
        when  = function(c)
          -- No global concept when connections_path override is active (single-file mode)
          if configured_connections_path() then return false end
          return not (c._new or c._temp or c._section_header or c._local_file
                      or c._builtin_id or c._is_demo)
              and c.source == "file"
        end,
        fn    = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          ensure_global_grip_dir()
          local global_path  = global_connections_path()
          local global_conns = read_json_connections(global_path, "global")
          for _, gc in ipairs(global_conns) do
            if gc.url == c.url then
              vim.notify("'" .. c.name .. "' is already in global connections", vim.log.levels.INFO)
              return
            end
          end
          local promoted = { name = c.name, url = c.url, type = c.type,
                              env_file = c.env_file, mode = c.mode, color = c.color }
          table.insert(global_conns, promoted)
          local gdata = {}
          for _, gc in ipairs(global_conns) do
            local entry = { name = gc.name, url = gc.url }
            if gc.type then entry.type = gc.type end
            if gc.env_file then entry.env_file = gc.env_file end
            if gc.mode then entry.mode = gc.mode end
            if gc.color then entry.color = gc.color end
            table.insert(gdata, entry)
          end
          vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_path)
          vim.notify("'" .. c.name .. "' saved to ~/.grip/connections.json", vim.log.levels.INFO)
        end,
      },
      {
        -- r: connect in the mode opposite to the entry's default -- a ro entry
        -- opened writable for one fix, a rw entry opened read-only before
        -- poking at production. Session-only: nothing is written to
        -- connections.json, and selecting the connection normally afterwards
        -- puts it back on its own mode (see _mode_override).
        key            = "r",
        label          = "r:ro/rw",
        close_on_select = true,
        when           = function(c)
          return ro_toggle_applies(c)
        end,
        fn             = function(c)
          -- grip_picker fires fn regardless of the `when` predicate (see the
          -- same guard on a:attach), so this is the check that actually
          -- prevents an override being set on an entry the action was hidden
          -- for -- not a restatement of the line above.
          if not ro_toggle_applies(c) then return end
          local mode = c.mode == "ro" and "rw" or "ro"
          -- Only claim the override on a switch that committed: one that
          -- aborted (unresolvable ${VAR}) leaves the connection exactly as it
          -- was, and has already said why.
          if M.switch(c.url, c.name, c.type, { mode = mode }) then
            vim.notify("Grip: connected " .. (mode == "ro" and "read-only" or "writable")
              .. " for this session (mode = " .. mode .. ")", vim.log.levels.INFO)
          end
        end,
      },
      {
        -- s: save a local file as a named connection in .grip/connections.json.
        key            = "s",
        label          = "s:save",
        close_on_select = true,
        when           = function(c) return c._local_file == true end,
        fn             = function(c)
          if not c._local_file then return end
          local default_name = vim.fn.fnamemodify(c.url, ":t:r")
          local name = ui.input({ prompt = "Save as: ", default = default_name })
          if not name then return end
          M.switch(c.url, name, "file")
        end,
      },
    },
  })
end

--- Expose the .grip/ directory path for other modules (schema catalog, etc.).
function M.grip_dir_path()
  return grip_dir()
end

return M
