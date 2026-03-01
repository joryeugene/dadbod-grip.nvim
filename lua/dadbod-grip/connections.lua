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

local function ensure_grip_dir()
  local dir = grip_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Read connections from .grip/connections.json.
local function read_file_connections()
  local path = connections_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  local result = {}
  for _, entry in ipairs(data) do
    if type(entry) == "table" and entry.name and entry.url then
      table.insert(result, { name = entry.name, url = entry.url, source = "file" })
    end
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

--- Read g:dbs (DBUI format: list of {name, url} dicts).
local function read_gdbs()
  local dbs = vim.g.dbs
  if type(dbs) ~= "table" then return {} end
  local result = {}
  for _, entry in ipairs(dbs) do
    if type(entry) == "table" and entry.name and entry.url then
      table.insert(result, { name = entry.name, url = entry.url, source = "g:dbs" })
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

  -- g:dbs (DBUI compat)
  for _, c in ipairs(read_gdbs()) do
    if not seen[c.url] then
      seen[c.url] = true
      table.insert(all, c)
    end
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

--- Switch active connection. Sets vim.g.db and notifies.
function M.switch(url, name)
  vim.g.db = url
  vim.notify("Grip: connected to " .. (name or url), vim.log.levels.INFO)
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
