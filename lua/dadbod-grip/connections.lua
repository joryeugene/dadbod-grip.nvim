-- connections.lua: connection profile management.
-- Reads from .grip/connections.json, g:dbs (DBUI compat), $DATABASE_URL.
-- All functions return (result, err). Never throw.

local M = {}

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

local function connections_path()
  return grip_dir() .. "/connections.json"
end

local function global_connections_path()
  local home = vim.fn.expand("~")
  return home .. "/.grip/connections.json"
end

local function ensure_grip_dir()
  local dir = grip_dir()
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
      table.insert(result, c)
    end
  end
  return result
end

--- Read connections from project-local and global files.
local function read_file_connections()
  local result = {}
  -- Project-local first
  for _, c in ipairs(read_json_connections(connections_path(), "file")) do
    table.insert(result, c)
  end
  -- Global connections (persisted from other projects)
  for _, c in ipairs(read_json_connections(global_connections_path(), "global")) do
    table.insert(result, c)
  end
  return result
end

--- Write connections to .grip/connections.json.
local function write_file_connections(conns)
  ensure_grip_dir()
  local data = {}
  for _, c in ipairs(conns) do
    local entry = { name = c.name, url = c.url }
    if c.type then entry.type = c.type end
    if c.attachments and #c.attachments > 0 then entry.attachments = c.attachments end
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
  local seen = {}       -- keyed by URL
  local seen_names = {} -- keyed by name (secondary dedup across sources)

  -- File connections first (user-managed)
  for _, c in ipairs(read_file_connections()) do
    if not seen[c.url] and not seen_names[c.name] then
      seen[c.url] = true
      seen_names[c.name] = true
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
    if not seen[c.url] and not seen_names[c.name] then
      seen[c.url] = true
      seen_names[c.name] = true
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

  -- $DATABASE_URL
  local env_url = os.getenv("DATABASE_URL")
  if env_url and env_url ~= "" and not seen[env_url] and not seen_names["$DATABASE_URL"] then
    seen_names["$DATABASE_URL"] = true
    table.insert(all, { name = "$DATABASE_URL", url = env_url, source = "env" })
  end

  -- Current vim.g.db (if set and not already listed)
  local gdb = vim.g.db
  if type(gdb) == "string" and gdb ~= "" and not seen[gdb] and not seen_names["vim.g.db"] then
    seen_names["vim.g.db"] = true
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

  -- Softrear Inc. Analyst Portal™: built-in, always at the bottom
  local hidden = vim.fn.stdpath("data") .. "/grip/softrear.hidden"
  local sql_files = vim.api.nvim_get_runtime_file("demo/softrear.sql", false)
  if #sql_files > 0 and vim.fn.filereadable(hidden) == 0 then
    local has_duck = vim.fn.executable("duckdb") == 1
    local ext      = has_duck and ".duckdb" or ".db"
    local db_path  = vim.fn.stdpath("data") .. "/grip/softrear" .. ext
    local seed     = has_duck and sql_files[1]
      or (vim.api.nvim_get_runtime_file("demo/softrear_sqlite.sql", false)[1] or "")
    table.insert(all, {
      name      = "Softrear Inc. Analyst Portal\xe2\x84\xa2",
      url       = (has_duck and "duckdb:" or "sqlite:") .. db_path,
      _is_demo  = true,
      _demo_sql = seed,
    })
  end

  return all
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

--- Add a connection to .grip/connections.json.
function M.add(name, url)
  local clean_url = strip_flags(url)
  local conns = read_file_connections()
  local conn_type = is_file_url(clean_url) and "file" or nil
  table.insert(conns, { name = name, url = clean_url, type = conn_type })
  write_file_connections(conns)
end

--- Remove a connection from .grip/connections.json by name.
function M.remove(name)
  local conns = read_file_connections()
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
  -- Resolve type: param > stored connections > auto-detect
  local file_conns = read_file_connections()
  local resolved_type = conn_type
  if not resolved_type then
    for _, c in ipairs(file_conns) do
      if c.url == url and c.type then
        resolved_type = c.type
        break
      end
    end
  end
  if not resolved_type and is_file_url(url) then
    resolved_type = "file"
  end

  -- Auto-persist if not already saved
  local already_saved = false
  for _, c in ipairs(file_conns) do
    if c.url == url then already_saved = true; break end
  end
  if not already_saved and name and name ~= "" then
    M.add(name, url)
  end

  if resolved_type == "file" then
    vim.notify("Grip: opening " .. (name or url), vim.log.levels.INFO)
    -- Capture current window so the grid replaces it (e.g. dashboard)
    local cur_win = vim.api.nvim_get_current_win()
    vim.schedule(function()
      local open_opts = { reuse_win = cur_win }
      if opts and opts.write    then open_opts.write    = true       end
      if opts and opts.watch_ms then open_opts.watch_ms = opts.watch_ms end
      require("dadbod-grip").open(url, nil, open_opts)
      -- Open sidebar with file schema after the grid is placed
      vim.schedule(function()
        local schema = require("dadbod-grip.schema")
        if not schema.is_open() then
          schema.toggle(url)
        else
          schema.refresh(url)
        end
      end)
    end)
    return
  end

  -- Regular DB connection: set vim.g.db and open full workspace
  vim.g.db = url

  -- Restore persisted attachments for DuckDB connections
  if url:find("^duckdb:") then
    local stored_atts
    for _, c in ipairs(file_conns) do
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

    -- Pre-warm AI schema cache in background (avoids freeze on first AI call)
    vim.schedule(function()
      pcall(function()
        require("dadbod-grip.ai").build_schema_context(url)
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
  local file_conns = read_file_connections()
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

  local max_name = 0
  for _, c in ipairs(conns) do
    max_name = math.max(max_name, vim.fn.strdisplaywidth(c.name))
  end

  -- Sentinel items at bottom of list
  local new_sentinel  = { name = "+ New connection...",          url = "", _new  = true }
  local temp_sentinel = { name = "~ Connect once (no save)...", url = "", _temp = true }
  local picker_items = {}
  for _, c in ipairs(conns) do
    table.insert(picker_items, c)
  end
  table.insert(picker_items, new_sentinel)
  table.insert(picker_items, temp_sentinel)

  -- Track which connection URLs have password reveal active
  local show_pass = {}

  require("dadbod-grip.grip_picker").open({
    title = "Connections",
    items = picker_items,
    on_cancel = on_cancel,
    display = function(c)
      if c._new or c._temp then return c.name end
      local pad = string.rep(" ", max_name - vim.fn.strdisplaywidth(c.name))
      local url_display = show_pass[c.url] and c.url or short_url(c.url)
      return c.name .. pad .. "  " .. url_display
    end,
    on_select = function(c)
      if c._new then
        prompt_new_connection()
      elseif c._temp then
        prompt_temp_connection()
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
          -- Open portal without persisting to connections.json (no name arg)
          M.switch(c.url)
        else
          M.switch(c.url, c.name, c.type)
        end
      end
    end,
    on_delete = function(c, refresh_fn)
      if c._new or c._temp then return end
      local CANCEL = "\0"
      -- Starter built-in: write a hidden flag so it never appears again
      if c._builtin_id then
        local ok, ans = pcall(vim.fn.input, { prompt = "Remove '" .. c.name .. "'? (y/N): ", cancelreturn = CANCEL })
        if ok and (ans == "y" or ans == "yes") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/" .. c._builtin_id .. ".hidden")
          local new_items = {}
          for _, nc in ipairs(M.list()) do table.insert(new_items, nc) end
          table.insert(new_items, new_sentinel)
          table.insert(new_items, temp_sentinel)
          refresh_fn(new_items)
        end
        return
      end
      -- Portal deletion: write a flag file so it never appears again
      if c._is_demo then
        local ok, ans = pcall(vim.fn.input, { prompt = "Remove Softrear Portal? (y/N): ", cancelreturn = CANCEL })
        if ok and (ans == "y" or ans == "yes") then
          vim.fn.mkdir(vim.fn.stdpath("data") .. "/grip", "p")
          vim.fn.writefile({}, vim.fn.stdpath("data") .. "/grip/softrear.hidden")
          local new_conns = M.list()
          local new_items = {}
          for _, nc in ipairs(new_conns) do
            table.insert(new_items, nc)
          end
          table.insert(new_items, new_sentinel)
          table.insert(new_items, temp_sentinel)
          refresh_fn(new_items)
        end
        return
      end
      local ok, ans = pcall(vim.fn.input, { prompt = "Remove '" .. c.name .. "'? (y/N): ", cancelreturn = CANCEL })
      if ok and (ans == "y" or ans == "yes") then
        M.remove(c.name)
        -- Rebuild list with updated sentinels at end
        local new_conns = M.list()
        local new_items = {}
        for _, nc in ipairs(new_conns) do
          table.insert(new_items, nc)
        end
        table.insert(new_items, new_sentinel)
        table.insert(new_items, temp_sentinel)
        refresh_fn(new_items)
      end
    end,
    actions = {
      {
        key            = "!",
        label          = "!:write",
        close_on_select = true,
        when           = function(c)
          return not c._new and not c._temp
              and (c.type == "file" or (not c.type and is_file_url(c.url)))
        end,
        fn             = function(c)
          if c._new or c._temp then return end
          M.switch(c.url, c.name, c.type, { write = true })
        end,
      },
      {
        key            = "W",
        label          = "W:watch",
        close_on_select = true,
        when           = function(c) return not c._new and not c._temp end,
        fn             = function(c)
          if c._new or c._temp then return end
          M.switch(c.url, c.name, c.type, { watch_ms = 5000 })
        end,
      },
      {
        key   = "M",
        label = "M:mask",
        when  = function(c) return not c._new and not c._temp end,
        fn    = function(c)
          if c._new or c._temp then return end
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
          if c._new or c._temp then return false end
          -- Show on non-DuckDB connections when current connection is DuckDB
          local cur = vim.g.db
          return cur and cur:find("^duckdb:") and not c.url:find("^duckdb:")
        end,
        fn             = function(c)
          if c._new or c._temp then return end
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
    },
  })
end

--- Expose the .grip/ directory path for other modules (schema catalog, etc.).
function M.grip_dir_path()
  return grip_dir()
end

return M
