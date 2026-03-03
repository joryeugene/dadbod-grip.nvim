-- filters.lua -- saved filter presets per table.
-- Stored in .grip/filters.json keyed by table name.
-- Picker uses grip_picker (zero external deps).

local M = {}

-- ── storage helpers ─────────────────────────────────────────────────────

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

local function filters_path()
  return project_root() .. "/.grip/filters.json"
end

local function ensure_dir()
  local dir = project_root() .. "/.grip"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Read all filter presets from disk. Mockable via M._read_all.
function M._read_all()
  local path = filters_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local raw = table.concat(vim.fn.readfile(path), "\n")
  local ok, data = pcall(vim.fn.json_decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

--- Write all filter presets to disk. Mockable via M._write_all.
function M._write_all(data)
  ensure_dir()
  local json = vim.fn.json_encode(data)
  vim.fn.writefile({ json }, filters_path())
end

-- ── public API ──────────────────────────────────────────────────────────

--- List presets for a table. Returns { {name, clause}, ... }.
function M.list(table_name)
  local all = M._read_all()
  local entries = all[table_name]
  if type(entries) ~= "table" then return {} end
  local result = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and e.name and e.clause then
      table.insert(result, { name = e.name, clause = e.clause })
    end
  end
  return result
end

--- Save a filter preset for a table.
function M.save(table_name, name, clause)
  if not table_name or table_name == "" then
    vim.notify("Grip: no table context for filter preset", vim.log.levels.ERROR)
    return
  end
  if not name or name == "" then
    vim.notify("Grip: preset name required", vim.log.levels.ERROR)
    return
  end
  local all = M._read_all()
  if type(all[table_name]) ~= "table" then all[table_name] = {} end
  -- Replace existing preset with same name, or append
  local found = false
  for i, e in ipairs(all[table_name]) do
    if e.name == name then
      all[table_name][i] = { name = name, clause = clause }
      found = true
      break
    end
  end
  if not found then
    table.insert(all[table_name], { name = name, clause = clause })
  end
  M._write_all(all)
  vim.notify("Grip: saved filter preset \"" .. name .. "\" for " .. table_name, vim.log.levels.INFO)
end

--- Delete a preset by name.
function M.delete(table_name, name)
  local all = M._read_all()
  if type(all[table_name]) ~= "table" then return end
  local filtered = {}
  for _, e in ipairs(all[table_name]) do
    if e.name ~= name then table.insert(filtered, e) end
  end
  all[table_name] = #filtered > 0 and filtered or nil
  M._write_all(all)
  vim.notify("Grip: deleted filter preset \"" .. name .. "\"", vim.log.levels.INFO)
end

--- Open a picker to select a filter preset. Calls callback({name, clause}).
function M.pick(table_name, callback)
  local presets = M.list(table_name)
  if #presets == 0 then
    vim.notify("Grip: no filter presets for " .. (table_name or "this table"), vim.log.levels.INFO)
    return
  end

  require("dadbod-grip.grip_picker").open({
    title = "Filter Presets",
    items = presets,
    display = function(p)
      return p.name .. "  (" .. p.clause:sub(1, 40) .. ")"
    end,
    on_select = function(p)
      callback(p)
    end,
    on_delete = function(p, refresh_fn)
      vim.ui.input({ prompt = "Delete preset '" .. p.name .. "'? (y/N): " }, function(ans)
        if ans == "y" or ans == "yes" then
          M.delete(table_name, p.name)
          refresh_fn(M.list(table_name))
        end
      end)
    end,
  })
end

return M
