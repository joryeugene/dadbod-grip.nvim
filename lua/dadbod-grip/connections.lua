-- connections.lua — connection profile management.
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

--- Read connections from a JSON file.
local function read_json_connections(path, source)
  if vim.fn.filereadable(path) == 0 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  local result = {}
  for _, entry in ipairs(data) do
    if type(entry) == "table" and entry.name and entry.url then
      table.insert(result, { name = entry.name, url = entry.url, source = source or "file" })
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
    table.insert(data, { name = c.name, url = c.url })
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

--- List all connections from all sources, deduplicated by URL.
function M.list()
  local all = {}
  local seen = {}

  -- File connections first (user-managed)
  for _, c in ipairs(read_file_connections()) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
  end

  -- g:dbs (DBUI compat) — also persist globally for cross-project access
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
      table.insert(gdata, { name = gc.name, url = gc.url })
    end
    vim.fn.writefile({ vim.fn.json_encode(gdata) }, global_connections_path())
  end

  -- $DATABASE_URL
  local env_url = os.getenv("DATABASE_URL")
  if env_url and env_url ~= "" and not seen[env_url] then
    table.insert(all, { name = "$DATABASE_URL", url = env_url, source = "env" })
  end

  -- Current vim.g.db (if set and not already listed)
  local gdb = vim.g.db
  if type(gdb) == "string" and gdb ~= "" and not seen[gdb] then
    table.insert(all, { name = "vim.g.db", url = gdb, source = "global" })
  end

  return all
end

--- Add a connection to .grip/connections.json.
function M.add(name, url)
  local conns = read_file_connections()
  table.insert(conns, { name = name, url = url })
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

--- Switch active connection. Sets vim.g.db and opens the full workspace.
--- Auto-saves to .grip/connections.json if not already persisted.
function M.switch(url, name)
  vim.g.db = url

  -- Auto-persist if not already in file connections
  local file_conns = read_file_connections()
  local already_saved = false
  for _, c in ipairs(file_conns) do
    if c.url == url then
      already_saved = true
      break
    end
  end
  if not already_saved and name and name ~= "" then
    M.add(name, url)
  end

  vim.notify("Grip: connected to " .. (name or url), vim.log.levels.INFO)

  -- Open the full workspace: schema sidebar + query pad
  vim.schedule(function()
    local schema = require("dadbod-grip.schema")
    if not schema.is_open() then
      schema.toggle(url)
    else
      schema.refresh(url)
    end

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

--- Open a picker to select and switch connection.
function M.pick()
  local conns = M.list()
  if #conns == 0 then
    vim.ui.input({ prompt = "Connection URL: " }, function(url)
      if url and url ~= "" then
        vim.ui.input({ prompt = "Connection name: " }, function(name)
          if name and name ~= "" then
            M.add(name, url)
          end
          M.switch(url, name)
        end)
      end
    end)
    return
  end

  local labels = {}
  for _, c in ipairs(conns) do
    table.insert(labels, c.name .. "  " .. c.url)
  end
  table.insert(labels, "+ New connection...")

  vim.ui.select(labels, { prompt = "Grip Connect:" }, function(_, idx)
    if not idx then return end
    if idx == #labels then
      -- New connection
      vim.ui.input({ prompt = "Connection URL: " }, function(url)
        if url and url ~= "" then
          vim.ui.input({ prompt = "Connection name: " }, function(name)
            if name and name ~= "" then
              M.add(name, url)
            end
            M.switch(url, name)
          end)
        end
      end)
    else
      local c = conns[idx]
      M.switch(c.url, c.name)
    end
  end)
end

return M
