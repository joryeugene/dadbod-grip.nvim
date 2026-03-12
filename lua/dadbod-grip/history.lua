-- history.lua -- query history with JSONL storage.
-- Stores in .grip/history.jsonl. Picker uses grip_picker (zero external deps).

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
    elapsed_ms = opts.elapsed_ms,
  }

  local all = M._read_all()

  -- Consecutive dedup: same SQL + URL just updates timestamp
  if #all > 0 then
    local last = all[#all]
    if last.sql == entry.sql and last.url == entry.url then
      all[#all].ts = entry.ts
      all[#all].elapsed_ms = entry.elapsed_ms
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

--- List recent history entries filtered to a specific table, newest first.
--- Matches entries where entry.table == table_name OR sql contains the table name.
function M.get_for_table(table_name, limit)
  if not table_name or table_name == "" then return {} end
  local all = M._read_all()
  local result = {}
  for i = #all, 1, -1 do
    local e = all[i]
    if (e["table"] and e["table"] == table_name)
      or (e.sql and e.sql:lower():find(table_name:lower(), 1, true)) then
      table.insert(result, e)
      if limit and #result >= limit then break end
    end
  end
  return result
end

--- Open a history picker filtered to a specific table. Calls callback(sql, entry).
function M.pick_for_table(table_name, callback)
  local entries = M.get_for_table(table_name, 100)
  if #entries == 0 then
    vim.notify("Grip: no history for " .. (table_name or "this table"), vim.log.levels.INFO)
    return
  end
  require("dadbod-grip.grip_picker").pick({
    title = "History: " .. (table_name or ""),
    items = entries,
    display = function(e)
      local time_str = os.date("%Y-%m-%d %H:%M", e.ts)
      local ms_str = e.elapsed_ms and (e.elapsed_ms .. "ms  ") or ""
      return time_str .. "  " .. ms_str .. e.sql:sub(1, 60):gsub("\n", " ")
    end,
    preview = function(e)
      if not e.sql or e.sql == "" then return { "(no SQL)" } end
      return vim.split(e.sql, "\n", { plain = true })
    end,
    on_select = function(e)
      callback(e.sql, e)
    end,
  })
end

--- Open a picker to select a history entry. Calls callback(sql, entry).
function M.pick(callback)
  local entries = M.list(100)
  if #entries == 0 then
    vim.notify("Grip: no query history", vim.log.levels.INFO)
    return
  end

  require("dadbod-grip.grip_picker").pick({
    title = "Query History",
    items = entries,
    display = function(e)
      local time_str = os.date("%Y-%m-%d %H:%M", e.ts)
      local ms_str = e.elapsed_ms and (e.elapsed_ms .. "ms  ") or ""
      return time_str .. "  " .. ms_str .. e.sql:sub(1, 60):gsub("\n", " ")
    end,
    preview = function(e)
      if not e.sql or e.sql == "" then return { "(no SQL)" } end
      return vim.split(e.sql, "\n", { plain = true })
    end,
    on_select = function(e)
      callback(e.sql, e)
    end,
  })
end

return M
