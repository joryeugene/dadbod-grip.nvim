-- saved.lua — save/load SQL queries in .grip/queries/.
-- Project-local storage with telescope/fzf/native picker.

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
function M.save(name, content)
  ensure_dir()
  local fname = sanitize(name)
  if fname == "" then
    vim.notify("Grip: invalid query name", vim.log.levels.ERROR)
    return
  end
  local path = queries_dir() .. "/" .. fname .. ".sql"
  vim.fn.writefile(vim.split(content, "\n"), path)
  vim.notify("Grip: saved query → " .. fname .. ".sql", vim.log.levels.INFO)
end

--- Prompt for name and save buffer content.
function M.save_prompt(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  if content:match("^%s*$") then
    vim.notify("Grip: nothing to save", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Save query as: " }, function(name)
    if name and name ~= "" then
      M.save(name, content)
      vim.bo[bufnr].modified = false
    end
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

  local labels = {}
  for _, q in ipairs(queries) do
    table.insert(labels, q.name)
  end

  vim.ui.select(labels, { prompt = "Load Query:" }, function(_, idx)
    if not idx then return end
    local q = queries[idx]
    local content = table.concat(vim.fn.readfile(q.path), "\n")
    callback(content, q.name)
  end)
end

return M
