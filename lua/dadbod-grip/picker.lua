-- picker.lua — table picker with column preview.
-- Tries telescope → fzf-lua → vim.ui.select.
-- All functions return (result, err). Never throw.

local db = require("dadbod-grip.db")

local M = {}

--- Format column info for preview display.
local function format_preview(table_name, url)
  local lines = { table_name, string.rep("─", #table_name) }
  local cols = db.get_column_info(table_name, url)
  if not cols then return lines end

  local pks = db.get_primary_keys(table_name, url)
  local pk_set = {}
  for _, pk in ipairs(pks or {}) do pk_set[pk] = true end

  local fks = db.get_foreign_keys(table_name, url)
  local fk_map = {}
  for _, fk in ipairs(fks or {}) do
    fk_map[fk.column] = fk.ref_table .. "." .. fk.ref_column
  end

  for _, col in ipairs(cols) do
    local prefix = "   "
    if pk_set[col.column_name] and fk_map[col.column_name] then
      prefix = "🔑🔗"
    elseif pk_set[col.column_name] then
      prefix = "🔑 "
    elseif fk_map[col.column_name] then
      prefix = "🔗 "
    end
    local line = prefix .. " " .. col.column_name .. "  " .. col.data_type
    if fk_map[col.column_name] then
      line = line .. "  → " .. fk_map[col.column_name]
    end
    table.insert(lines, line)
  end

  if #pks > 0 then
    table.insert(lines, "")
    table.insert(lines, "PKs: " .. table.concat(pks, ", "))
  end
  if #fks > 0 then
    table.insert(lines, "FKs: " .. table.concat(
      vim.tbl_map(function(fk) return fk.column .. " → " .. fk.ref_table end, fks), ", "))
  end

  return lines
end

--- Telescope picker with async column preview.
local function telescope_pick(tables, url, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "Grip Tables",
    finder = finders.new_table({
      results = tables,
      entry_maker = function(entry)
        local icon = entry.type == "view" and "○" or "●"
        return {
          value = entry,
          display = icon .. " " .. entry.name,
          ordinal = entry.name,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Column Info",
      define_preview = function(self, entry)
        local lines = format_preview(entry.value.name, url)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then callback(entry.value.name) end
      end)
      return true
    end,
  }):find()
end

--- fzf-lua picker.
local function fzf_pick(tables, url, callback)
  local fzf = require("fzf-lua")
  local items = {}
  for _, t in ipairs(tables) do
    local icon = t.type == "view" and "○" or "●"
    table.insert(items, icon .. " " .. t.name)
  end

  fzf.fzf_exec(items, {
    prompt = "Grip Tables> ",
    previewer = false,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local name = selected[1]:gsub("^[○●] ", "")
          callback(name)
        end
      end,
    },
  })
end

--- Native vim.ui.select fallback.
local function native_pick(tables, callback)
  local labels = {}
  for _, t in ipairs(tables) do
    local icon = t.type == "view" and "○" or "●"
    table.insert(labels, icon .. " " .. t.name)
  end

  vim.ui.select(labels, { prompt = "Grip Tables:" }, function(_, idx)
    if idx then callback(tables[idx].name) end
  end)
end

--- Open table picker. Calls callback(table_name) on selection.
function M.pick_table(url, callback)
  local tables, err = db.list_tables(url)
  if not tables then
    vim.notify("Grip: " .. (err or "Failed to list tables"), vim.log.levels.ERROR)
    return
  end
  if #tables == 0 then
    vim.notify("Grip: no tables found", vim.log.levels.WARN)
    return
  end

  -- Try telescope → fzf-lua → vim.ui.select
  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    return telescope_pick(tables, url, callback)
  end

  local has_fzf = pcall(require, "fzf-lua")
  if has_fzf then
    return fzf_pick(tables, url, callback)
  end

  return native_pick(tables, callback)
end

--- Format column preview lines (exposed for schema.lua reuse).
M.format_preview = format_preview

return M
