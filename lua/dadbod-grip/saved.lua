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
  vim.schedule(function()
    vim.ui.input({ prompt = "Save query as: " }, function(name)
      if name and name ~= "" then
        M.save(name, content)
        vim.bo[bufnr].modified = false
      end
    end)
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

--- Telescope picker with SQL file preview.
local function telescope_pick(queries, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "Grip Saved Queries",
    finder = finders.new_table({
      results = queries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.name,
          ordinal = entry.name,
          path = entry.path,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "SQL Preview",
      define_preview = function(self, entry)
        local lines = vim.fn.readfile(entry.value.path)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "sql"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          local content = table.concat(vim.fn.readfile(entry.value.path), "\n")
          callback(content, entry.value.name)
        end
      end)
      return true
    end,
  }):find()
end

--- fzf-lua picker.
local function fzf_pick(queries, callback)
  local fzf = require("fzf-lua")
  local names = {}
  local by_name = {}
  for _, q in ipairs(queries) do
    table.insert(names, q.name)
    by_name[q.name] = q
  end

  fzf.fzf_exec(names, {
    prompt = "Grip Queries> ",
    previewer = false,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local q = by_name[selected[1]]
          if q then
            local content = table.concat(vim.fn.readfile(q.path), "\n")
            callback(content, q.name)
          end
        end
      end,
    },
  })
end

--- Native vim.ui.select fallback.
local function native_pick(queries, callback)
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

--- Open a picker to load a saved query. Calls callback(content, name).
--- Tries telescope -> fzf-lua -> vim.ui.select.
function M.pick(callback)
  local queries = M.list()
  if #queries == 0 then
    vim.notify("Grip: no saved queries", vim.log.levels.WARN)
    return
  end

  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    return telescope_pick(queries, callback)
  end

  local has_fzf = pcall(require, "fzf-lua")
  if has_fzf then
    return fzf_pick(queries, callback)
  end

  return native_pick(queries, callback)
end

return M
