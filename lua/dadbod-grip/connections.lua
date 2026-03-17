-- connections.lua: connection profile management.
-- Reads from .grip/connections.json, g:dbs (DBUI compat), $DATABASE_URL.
-- All functions return (result, err). Never throw.

local M = {}

-- Session-scoped connection health state (never persisted).
-- Values: "ok" | "fail" | "unknown" (default when absent)
local _health = {}

local function health_char(url)
  local s = _health[url] or "unknown"
  if s == "ok"   then return "*" end
  if s == "fail" then return "x" end
  return " "
end

--- Find project root by walking up from cwd looking for .git or .grip.
local function project_root()
  local dir = vim.fn.getcwd()
  while dir ~= "/" do
    if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.isdirectory(dir .. "/.grip") == 1 then
      return dir
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  return vim.fn.getcwd()
end

local function grip_dir()
  local root = project_root()
  return root .. "/.grip"
end

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
  local dir = custom and vim.fn.fnamemodify(custom, ":h") or grip_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

local function ensure_global_grip_dir()
  local dir = vim.fn.expand("~") .. "/.grip"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Detect if a URL or path points to a file DuckDB can query directly.
local function is_file_url(url)
  if not url or url == "" then return false end
  if url:match("^https?://") then return true end
  if url:match("^s3://") then return true end
  local lower = url:lower():gsub("[?#].*$", "")
  for _, ext in ipairs({ ".parquet", ".csv", ".tsv", ".json", ".ndjson", ".jsonl",
                          ".xlsx", ".orc", ".arrow", ".ipc" }) do
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

-- Extensions that DuckDB can query directly (local paths only).
local LOCAL_FILE_EXTS = {
  ".parquet", ".csv", ".tsv", ".json", ".ndjson", ".jsonl",
  ".xlsx", ".orc", ".arrow", ".ipc",
}

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

--- Mask the password in a DB URL for display. Returns URL unchanged if no password found.
local function mask_url(url)
  if not url or url == "" then return url end
  -- Match ://user:password@host: replace password with ***
  return (url:gsub("(://[^:@/]+:)([^@]+)(@)", function(pre, _, at)
    return pre .. "***" .. at
  end))
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

--- List all connections from all sources, deduplicated by URL and name.
function M.list()
  local all = {}
  local seen = {}  -- keyed by URL; URL is the canonical identifier

  -- File connections first (user-managed, sorted by last_used in pick())
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
    local has_duck = vim.fn.executable("duckdb") == 1
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

--- Return the current session health for a URL: "ok" | "fail" | "unknown".
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

--- Add (or rename) a connection in .grip/connections.json.
--- Upsert by URL: if the URL already exists, updates name and type in place,
--- preserving last_used and attachments. Prevents accumulation of duplicates
--- and correctly handles "rename on next switch" (e.g. vim.g.db → proper name).
function M.add(name, url)
  local clean_url = strip_flags(url)
  local conns = read_local_connections()
  for _, c in ipairs(conns) do
    if c.url == clean_url then
      c.name = name
      if is_file_url(clean_url) then c.type = "file" end
      write_file_connections(conns)
      return
    end
  end
  local conn_type = is_file_url(clean_url) and "file" or nil
  table.insert(conns, { name = name, url = clean_url, type = conn_type })
  write_file_connections(conns)
end

--- Update last_used timestamp for a saved connection (MRU tracking).
function M.touch(url)
  local clean = strip_flags(url)
  local conns = read_local_connections()
  local changed = false
  for _, c in ipairs(conns) do
    if c.url == clean then
      c.last_used = os.time()
      changed = true
      break
    end
  end
  if changed then write_file_connections(conns) end
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
--- opts: { write = bool, watch_ms = number }: session-only, never persisted.
function M.switch(url, name, conn_type, opts)
  -- Strip session-only flags: they must never reach the connection registry
  url = strip_flags(url)
  -- Resolve type: param > stored connections > auto-detect.
  -- Read local+global here (read-only: no write risk).
  local all_conns = read_file_connections()
  local resolved_type = conn_type
  if not resolved_type then
    for _, c in ipairs(all_conns) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and is_file_url(url) then
    resolved_type = "file"
  end

  -- Always upsert when a name is provided. M.add() handles both insert (new
  -- URL) and rename (existing URL with a stale generic name like "vim.g.db").
  -- Without this, already_saved=true would skip M.add and the rename never
  -- happens even when switching with the correct name.
  local local_conns = read_local_connections()
  if name and name ~= "" then
    M.add(name, url)
  end
  -- Touch AFTER upsert so first-time connections get last_used stamped
  M.touch(url)

  if resolved_type == "file" then
    vim.notify("Grip: opening " .. (name or url), vim.log.levels.INFO)
    M.set_health(url, "ok")
    -- Compute the DuckDB connection that will actually run queries against this file.
    -- Mirrors the logic in init.lua so the query pad is wired to the same connection.
    local active = vim.g.db
    local db_url = (active and active:match("^duckdb:")) and active or "duckdb::memory:"
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
    return
  end

  -- Regular DB connection: set vim.g.db and open full workspace
  vim.g.db = url

  -- Restore persisted attachments for DuckDB connections (local file only;
  -- attachments are always saved to local by M.save_attachments).
  if url:find("^duckdb:") then
    local stored_atts
    for _, c in ipairs(local_conns) do
      if c.url == url and c.attachments then
        stored_atts = c.attachments
        break
      end
    end
    if stored_atts then
      require("dadbod-grip.adapters.duckdb").load_attachments(url, stored_atts)
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
function M.save_attachments(url, attachments)
  local file_conns = read_local_connections()
  local found = false
  for _, c in ipairs(file_conns) do
    if c.url == url then
      c.attachments = attachments and #attachments > 0 and {} or nil
      if attachments then
        for _, a in ipairs(attachments) do
          table.insert(c.attachments, { dsn = a.dsn, alias = a.alias })
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
local function prompt_new_connection()
  local CANCEL = "\0"
  local ok, url = pcall(vim.fn.input, { prompt = "Connection URL, file path, or s3://: ", cancelreturn = CANCEL })
  if not ok or url == CANCEL or url == "" then
    require("dadbod-grip").open_welcome(); return
  end

  local ok2, name = pcall(vim.fn.input, { prompt = "Connection name: ", cancelreturn = CANCEL })
  if not ok2 or name == CANCEL or name == "" then
    require("dadbod-grip").open_welcome(); return
  end

  M.add(name, url)
  M.switch(url, name)
end

--- Connect once without saving to connections.json.
--- Passes nil name so M.switch() skips the auto-persist path.
local function prompt_temp_connection()
  local CANCEL = "\0"
  local ok, url = pcall(vim.fn.input, { prompt = "Connect once (URL, not saved): ", cancelreturn = CANCEL })
  if not ok or url == CANCEL or url == "" then
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
      return dot .. " " .. c.name .. pad .. "  " .. url_display
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
      local CANCEL = "\0"
      -- Starter built-in: write a hidden flag so it never appears again
      if c._builtin_id then
        local ok, ans = pcall(vim.fn.input, { prompt = "Remove '" .. c.name .. "'? (y/N): ", cancelreturn = CANCEL })
        if ok and (ans == "y" or ans == "yes") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/" .. c._builtin_id .. ".hidden")
          refresh_fn(build_picker_items())
        end
        return
      end
      -- Portal deletion: write a flag file so it never appears again
      if c._is_demo then
        local ok, ans = pcall(vim.fn.input, { prompt = "Remove Softrear Portal? (y/N): ", cancelreturn = CANCEL })
        if ok and (ans == "y" or ans == "yes") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/softrear.hidden")
          refresh_fn(build_picker_items())
        end
        return
      end
      local ok, ans = pcall(vim.fn.input, { prompt = "Remove '" .. c.name .. "'? (y/N): ", cancelreturn = CANCEL })
      if ok and (ans == "y" or ans == "yes") then
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
          -- Show on non-DuckDB connections when current connection is DuckDB
          local cur = vim.g.db
          return cur and cur:find("^duckdb:") and not c.url:find("^duckdb:")
        end,
        fn             = function(c)
          if c._new or c._temp or c._section_header or c._local_file then return end
          -- Guard: grip_picker fires fn regardless of `when` predicate label
          local url = vim.g.db
          if not url or not url:find("^duckdb:") then
            vim.notify(
              "Attach requires an active DuckDB connection. Switch to DuckDB with gc first.",
              vim.log.levels.WARN)
            return
          end
          local CANCEL = "\0"
          local default_alias = c.name:lower():gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
          local ok, alias = pcall(vim.fn.input, {
            prompt = "Attach as alias: ",
            default = default_alias,
            cancelreturn = CANCEL,
          })
          if not ok or alias == CANCEL or alias == "" then return end
          local duckdb_adapter = require("dadbod-grip.adapters.duckdb")
          local schema_mod = require("dadbod-grip.schema")
          local url = vim.g.db
          local dsn = duckdb_adapter.url_to_dsn(c.url)
          local err = duckdb_adapter.attach(url, dsn, alias)
          if err then
            vim.notify("Attach failed: " .. err, vim.log.levels.ERROR)
            return
          end
          M.save_attachments(url, duckdb_adapter.get_attachments(url))
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
          if is_testable_locally(c) then
            local path = extract_local_path(c.url)
            M.set_health(c.url, vim.fn.filereadable(path) == 1 and "ok" or "fail")
          else
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
          table.insert(global_conns, { name = c.name, url = c.url })
          local gdata = {}
          for _, gc in ipairs(global_conns) do
            local entry = { name = gc.name, url = gc.url }
            if gc.type then entry.type = gc.type end
            table.insert(gdata, entry)
          end
          vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_path)
          vim.notify("'" .. c.name .. "' saved to ~/.grip/connections.json", vim.log.levels.INFO)
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
          local CANCEL = "\0"
          local default_name = vim.fn.fnamemodify(c.url, ":t:r")
          local ok, name = pcall(vim.fn.input, {
            prompt = "Save as: ", default = default_name, cancelreturn = CANCEL,
          })
          if not ok or name == CANCEL or name == "" then return end
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
