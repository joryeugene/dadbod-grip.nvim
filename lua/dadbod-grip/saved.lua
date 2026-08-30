-- saved.lua: save/load SQL queries in .grip/queries/.
-- Project-local storage; uses grip_picker (zero external deps).

local ui    = require("dadbod-grip.ui")
local paths = require("dadbod-grip.paths")
local secrets = require("dadbod-grip.secrets")
local sql_util = require("dadbod-grip.sql")

local M = {}

local function queries_dir()
  return paths.grip_dir() .. "/queries"
end

local function ensure_dir()
  paths.ensure_dir(queries_dir())
end

--- Sanitize name for filename (alphanumeric, hyphens, underscores).
local function sanitize(name)
  return name:gsub("[^%w%-_]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
end

--- Remove and return leading Grip metadata without exposing it to the editor.
local function extract_metadata(content)
  local connection_id, legacy_url
  while true do
    local id = content:match("^%-%- grip:connection=([^\n]+)\n?")
    if id then
      connection_id = connection_id or id
      content = content:gsub("^%-%- grip:connection=[^\n]*\n?", "", 1)
    else
      local url = content:match("^%-%- grip:url=([^\n]+)\n?")
      if not url then break end
      legacy_url = legacy_url or url
      content = content:gsub("^%-%- grip:url=[^\n]*\n?", "", 1)
    end
  end
  return content, connection_id, legacy_url
end

local SECRET_KEYS = {
  password = true, passwd = true, pwd = true, token = true,
  motherduck_token = true, access_token = true, auth_token = true,
  session_token = true, api_key = true, apikey = true,
  secret = true, secret_access_key = true,
}

local function has_literal_credential(url)
  local password = sql_util.url_password(url)
  if password and not secrets.has_template(password) then return true end
  for key, value in url:gmatch("[?&]([^=&]+)=([^&]*)") do
    if SECRET_KEYS[key:lower()] and value ~= "" and not secrets.has_template(value) then
      return true
    end
  end
  for key in pairs(SECRET_KEYS) do
    local value = url:match(key .. "%s*=%s*([^%s]+)")
    if value and not secrets.has_template(value) then return true end
  end
  return false
end

local function apply_metadata(content)
  local clean, connection_id, legacy_url = extract_metadata(content)
  local connections = require("dadbod-grip.connections")

  if connection_id then
    local conn, reason = connections.find_by_id(connection_id)
    if conn then
      if conn.url ~= vim.g.db then connections.switch(conn.url, nil, conn.type) end
    elseif reason == "ambiguous" then
      vim.notify("Grip: saved query connection ID is ambiguous; kept the current connection",
        vim.log.levels.WARN)
    else
      vim.notify("Grip: saved query connection no longer exists; kept the current connection",
        vim.log.levels.WARN)
    end
  elseif legacy_url then
    if has_literal_credential(legacy_url) then
      vim.notify(
        "Grip: legacy saved query contains credentials; it was not auto-connected. Resave it to remove them.",
        vim.log.levels.WARN)
    else
      if legacy_url ~= vim.g.db then connections.switch(legacy_url, nil) end
      vim.notify("Grip: legacy saved-query metadata will migrate when you next save it",
        vim.log.levels.WARN)
    end
  end
  return clean
end

--- Save query content to a named .sql file.
--- Persisted connections are referenced by opaque ID; URLs never enter SQL.
function M.save(name, content, url)
  ensure_dir()
  local fname = sanitize(name)
  if fname == "" then
    vim.notify("Grip: invalid query name", vim.log.levels.ERROR)
    return
  end
  local path = queries_dir() .. "/" .. fname .. ".sql"
  local body = extract_metadata(content)
  local connection_id = url and url ~= ""
      and require("dadbod-grip.connections").ensure_id(url) or nil
  if connection_id then body = "-- grip:connection=" .. connection_id .. "\n" .. body end
  vim.fn.writefile(vim.split(body, "\n"), path)
  if url and url ~= "" and not connection_id then
    vim.notify("Grip: saved query without a connection; save the connection first to bind it",
      vim.log.levels.WARN)
  else
    vim.notify("Grip: saved query → " .. fname .. ".sql  (gq to browse)", vim.log.levels.INFO)
  end
end

--- Prompt for name and save buffer content.
function M.save_prompt(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  if content:match("^%s*$") then
    vim.notify("Grip: nothing to save", vim.log.levels.WARN)
    return
  end
  vim.schedule(function()
    local name = ui.input({ prompt = "Save query as: " })
    if not name then return end
    -- Prefer buffer-local db (set by DBUI), then global
    local url = vim.b[bufnr].db or vim.g.db or ""
    M.save(name, content, url)
    vim.bo[bufnr].modified = false
  end)
end

--- Load a named query. Returns content string or nil.
function M.load(name)
  local fname = sanitize(name)
  local path = queries_dir() .. "/" .. fname .. ".sql"
  if vim.fn.filereadable(path) == 0 then
    vim.notify("Grip: query not found: " .. fname, vim.log.levels.ERROR)
    return nil
  end
  return apply_metadata(table.concat(vim.fn.readfile(path), "\n"))
end

--- List all saved queries. Returns { {name, path, mtime}, ... }.
function M.list()
  local dir = queries_dir()
  if vim.fn.isdirectory(dir) == 0 then return {} end
  local files = vim.fn.glob(dir .. "/*.sql", false, true)
  local result = {}
  for _, path in ipairs(files) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    table.insert(result, { name = name, path = path })
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

--- Delete a saved query.
function M.delete(name)
  local fname = sanitize(name)
  local path = queries_dir() .. "/" .. fname .. ".sql"
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
    vim.notify("Grip: deleted query " .. fname, vim.log.levels.INFO)
  end
end

--- Open a picker to load a saved query. Calls callback(content, name).
function M.pick(callback)
  local queries = M.list()
  if #queries == 0 then
    vim.notify("Grip: no saved queries", vim.log.levels.WARN)
    return
  end

  require("dadbod-grip.grip_picker").open({
    title = "Saved Queries",
    items = queries,
    display = function(q) return q.name end,
    preview = function(q)
      local ok, raw_lines = pcall(vim.fn.readfile, q.path)
      if not ok then return { "(file not readable)" } end
      local raw = table.concat(raw_lines, "\n")
      local content = extract_metadata(raw)
      local out = {}
      for _, ln in ipairs(vim.split(content:match("^%s*(.-)%s*$"), "\n", { plain = true })) do
        table.insert(out, ln)
      end
      return #out > 0 and out or { "(empty)" }
    end,
    on_select = function(q)
      local raw = table.concat(vim.fn.readfile(q.path), "\n")
      local content = apply_metadata(raw)
      callback(content, q.name)
    end,
    on_delete = function(q, refresh_fn)
      if ui.confirm("Delete '" .. q.name .. "'? (y/N): ") then
        M.delete(q.name)
        refresh_fn(M.list())
      end
    end,
  })
end

M._extract_metadata = extract_metadata
M._has_literal_credential = has_literal_credential

return M
