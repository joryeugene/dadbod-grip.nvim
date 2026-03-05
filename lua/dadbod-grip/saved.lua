-- saved.lua: save/load SQL queries in .grip/queries/.
-- Project-local storage; uses grip_picker (zero external deps).

local M = {}

--- Find project root by walking up from cwd for .git or .grip.
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

local function queries_dir()
  return project_root() .. "/.grip/queries"
end

local function ensure_dir()
  local dir = queries_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Sanitize name for filename (alphanumeric, hyphens, underscores).
local function sanitize(name)
  return name:gsub("[^%w%-_]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
end

--- Save query content to a named .sql file.
--- Optional url stored as first-line comment: -- grip:url=URL
function M.save(name, content, url)
  ensure_dir()
  local fname = sanitize(name)
  if fname == "" then
    vim.notify("Grip: invalid query name", vim.log.levels.ERROR)
    return
  end
  local path = queries_dir() .. "/" .. fname .. ".sql"
  local body = content
  if url and url ~= "" then
    -- Strip any existing grip:url header before prepending new one
    body = body:gsub("^%-%- grip:url=[^\n]*\n?", "")
    body = "-- grip:url=" .. url .. "\n" .. body
  end
  vim.fn.writefile(vim.split(body, "\n"), path)
  vim.notify("Grip: saved query → " .. fname .. ".sql  (gq to browse)", vim.log.levels.INFO)
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
    local CANCEL = "\0"
    local ok, name = pcall(vim.fn.input, { prompt = "Save query as: ", cancelreturn = CANCEL })
    if not ok or name == CANCEL or name == "" then return end
    -- Prefer buffer-local db (set by DBUI), then global
    local url = vim.b[bufnr].db or vim.g.db or ""
    M.save(name, content, url)
    vim.bo[bufnr].modified = false
  end)
end

--- Extract URL from saved query content (reads the grip:url header comment).
--- Returns (clean_content, url_or_nil).
local function extract_url(content)
  local url = content:match("^%-%- grip:url=([^\n]+)\n?")
  if url then
    local clean = content:gsub("^%-%- grip:url=[^\n]*\n?", "")
    return clean, url
  end
  return content, nil
end

--- Load a named query. Returns content string or nil.
function M.load(name)
  local fname = sanitize(name)
  local path = queries_dir() .. "/" .. fname .. ".sql"
  if vim.fn.filereadable(path) == 0 then
    vim.notify("Grip: query not found: " .. fname, vim.log.levels.ERROR)
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
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
      local content = extract_url(raw)  -- strip "-- grip:url=..." header
      local out = {}
      for _, ln in ipairs(vim.split(content:match("^%s*(.-)%s*$"), "\n", { plain = true })) do
        table.insert(out, ln)
      end
      return #out > 0 and out or { "(empty)" }
    end,
    on_select = function(q)
      local raw = table.concat(vim.fn.readfile(q.path), "\n")
      local content, url = extract_url(raw)
      if url and url ~= "" and url ~= vim.g.db then
        require("dadbod-grip.connections").switch(url, q.name .. " (saved)")
      end
      callback(content, q.name)
    end,
    on_delete = function(q, refresh_fn)
      local CANCEL = "\0"
      local ok, ans = pcall(vim.fn.input, { prompt = "Delete '" .. q.name .. "'? (y/N): ", cancelreturn = CANCEL })
      if ok and (ans == "y" or ans == "yes") then
        M.delete(q.name)
        refresh_fn(M.list())
      end
    end,
  })
end

return M
