-- history.lua -- query history with JSONL storage.
-- Stores in .grip/history.jsonl. Picker uses telescope -> fzf-lua -> vim.ui.select.

local M = {}

local MAX_ENTRIES = 500

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

local function history_path()
  return project_root() .. "/.grip/history.jsonl"
end

local function ensure_dir()
  local dir = project_root() .. "/.grip"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Redact password from connection URL. Mockable via M._redact_url.
function M._redact_url(url)
  if not url then return "" end
  return url:gsub("://([^:]+):[^@]+@", "://%1:***@")
end

--- Read all history entries from disk. Mockable via M._read_all.
function M._read_all()
  local path = history_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local lines = vim.fn.readfile(path)
  local entries = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, entry = pcall(vim.fn.json_decode, line)
      if ok and type(entry) == "table" then
        table.insert(entries, entry)
      end
    end
  end
  return entries
end

--- Write all history entries to disk. Mockable via M._write_all.
function M._write_all(entries)
  ensure_dir()
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, vim.fn.json_encode(e))
  end
  vim.fn.writefile(lines, history_path())
end

-- ── public API ──────────────────────────────────────────────────────────

--- Record a query in history. Consecutive identical queries update timestamp.
--- opts: { sql, url, table_name, type }
function M.record(opts)
  local sql_str = opts.sql
  if not sql_str or sql_str:match("^%s*$") then return end

  local redacted = M._redact_url(opts.url)
  local entry = {
    sql = sql_str,
    url = redacted,
    ["table"] = opts.table_name,
    ts = os.time(),
    type = opts.type or "query",
  }

  local all = M._read_all()

  -- Consecutive dedup: same SQL + URL just updates timestamp
  if #all > 0 then
    local last = all[#all]
    if last.sql == entry.sql and last.url == entry.url then
      all[#all].ts = entry.ts
      M._write_all(all)
      return
    end
  end

  -- Append
  table.insert(all, entry)

  -- Trim oldest if over cap
  if #all > MAX_ENTRIES then
    local trimmed = {}
    for i = #all - MAX_ENTRIES + 1, #all do
      table.insert(trimmed, all[i])
    end
    all = trimmed
  end

  M._write_all(all)
end

--- List recent history entries, newest first.
function M.list(limit)
  local all = M._read_all()
  local result = {}
  local start = limit and math.max(1, #all - limit + 1) or 1
  for i = #all, start, -1 do
    table.insert(result, all[i])
  end
  return result
end

--- Clear all history.
function M.clear()
  M._write_all({})
end

-- ── pickers ─────────────────────────────────────────────────────────────

local function telescope_pick(entries, callback)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "Grip Query History",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        local time_str = os.date("%Y-%m-%d %H:%M", entry.ts)
        local short_sql = entry.sql:sub(1, 60):gsub("\n", " ")
        return {
          value = entry,
          display = time_str .. "  " .. short_sql,
          ordinal = entry.sql .. " " .. (entry["table"] or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "SQL",
      define_preview = function(self, entry_obj)
        local e = entry_obj.value
        local lines = {
          "-- " .. os.date("%Y-%m-%d %H:%M:%S", e.ts),
          "-- " .. (e.url or ""),
          "",
        }
        for _, l in ipairs(vim.split(e.sql, "\n")) do
          table.insert(lines, l)
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "sql"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry_obj = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry_obj then callback(entry_obj.value.sql, entry_obj.value) end
      end)
      return true
    end,
  }):find()
end

local function fzf_pick(entries, callback)
  local fzf = require("fzf-lua")
  local labels = {}
  local by_idx = {}
  for i, e in ipairs(entries) do
    local time_str = os.date("%Y-%m-%d %H:%M", e.ts)
    local label = time_str .. "  " .. e.sql:sub(1, 60):gsub("\n", " ")
    table.insert(labels, label)
    by_idx[label] = e
  end

  fzf.fzf_exec(labels, {
    prompt = "Grip History> ",
    previewer = false,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local e = by_idx[selected[1]]
          if e then callback(e.sql, e) end
        end
      end,
    },
  })
end

local function native_pick(entries, callback)
  local labels = {}
  for _, e in ipairs(entries) do
    local time_str = os.date("%Y-%m-%d %H:%M", e.ts)
    table.insert(labels, time_str .. "  " .. e.sql:sub(1, 50):gsub("\n", " "))
  end

  vim.ui.select(labels, { prompt = "Query History:" }, function(_, idx)
    if not idx then return end
    callback(entries[idx].sql, entries[idx])
  end)
end

--- Open a picker to select a history entry. Calls callback(sql, entry).
function M.pick(callback)
  local entries = M.list(100)
  if #entries == 0 then
    vim.notify("Grip: no query history", vim.log.levels.INFO)
    return
  end

  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    return telescope_pick(entries, callback)
  end

  local has_fzf = pcall(require, "fzf-lua")
  if has_fzf then
    return fzf_pick(entries, callback)
  end

  return native_pick(entries, callback)
end

return M
