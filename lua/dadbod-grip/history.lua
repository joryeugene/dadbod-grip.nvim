-- history.lua -- query history with JSONL storage.
-- Stores in .grip/history.jsonl. Picker uses grip_picker (zero external deps).

local paths = require("dadbod-grip.paths")
local sql_util = require("dadbod-grip.sql")

local M = {}

local MAX_ENTRIES = 500
-- Amortized trim: only rewrite the whole file once it has grown to 1.5x the
-- cap, instead of re-trimming on every single record(). The file can exceed
-- MAX_ENTRIES between compactions, but readers always cap at MAX_ENTRIES
-- (see M._read_all), so nobody observes more history than the limit promises.
local TRIM_THRESHOLD = math.floor(MAX_ENTRIES * 1.5)

-- ── storage helpers ─────────────────────────────────────────────────────

local function history_path()
  return paths.grip_dir() .. "/history.jsonl"
end

local function ensure_dir()
  paths.ensure_dir(paths.grip_dir())
end

--- Redact password from connection URL. Mockable via M._redact_url.
--- Delegates to sql.redact_url, the single copy of this pattern shared with
--- the adapters' error messages.
function M._redact_url(url)
  return sql_util.redact_url(url)
end

--- Read all history entries from disk. Mockable via M._read_all.
--- A malformed or partial line (e.g. left by a torn append) is silently
--- skipped rather than raising, so a half-written last line never breaks
--- reads of everything recorded before it.
--- Always caps the result at MAX_ENTRIES: M.record() only compacts the file
--- amortized (see TRIM_THRESHOLD), so the file can briefly hold more lines
--- than the limit. Enforcing the cap here means every reader (M.list,
--- M.get_for_table) sees at most MAX_ENTRIES regardless of on-disk overshoot.
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
  if #entries > MAX_ENTRIES then
    local capped = {}
    for i = #entries - MAX_ENTRIES + 1, #entries do
      table.insert(capped, entries[i])
    end
    entries = capped
  end
  return entries
end

--- Write all history entries to disk, replacing the file. Mockable via
--- M._write_all. Used by M.clear() and by M.record()'s amortized compaction
--- (both dedup-update and over-threshold trim need to rewrite, since they
--- change something other than "append one line at the end").
function M._write_all(entries)
  ensure_dir()
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, vim.fn.json_encode(e))
  end
  vim.fn.writefile(lines, history_path())
end

--- Read just the last stored entry without loading the whole file. Used by
--- M.record() to check for consecutive-dedup cheaply. Mockable via
--- M._read_last. Returns nil on a missing file or an unparsable last line.
function M._read_last()
  local path = history_path()
  if vim.fn.filereadable(path) == 0 then return nil end
  local lines = vim.fn.readfile(path, "", -1)
  if #lines == 0 or lines[1] == "" then return nil end
  local ok, entry = pcall(vim.fn.json_decode, lines[1])
  if ok and type(entry) == "table" then return entry end
  return nil
end

--- Append a single entry as one JSONL line, without touching existing
--- content. Mockable via M._append_one. This is the hot path for M.record():
--- one small write instead of a full read-modify-write of the whole file.
function M._append_one(entry)
  ensure_dir()
  vim.fn.writefile({ vim.fn.json_encode(entry) }, history_path(), "a")
end

--- Number of lines currently on disk, without decoding them. Used by
--- M.record() to decide whether the amortized trim is due. Mockable via
--- M._count_lines.
function M._count_lines()
  local path = history_path()
  if vim.fn.filereadable(path) == 0 then return 0 end
  return #vim.fn.readfile(path)
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

  -- Consecutive dedup: same SQL + URL just updates the existing last line's
  -- timestamp. Checked via M._read_last() (last line only) so the common
  -- case below doesn't need to read the whole file just to compare.
  local last = M._read_last()
  if last and last.sql == entry.sql and last.url == entry.url then
    -- Updating an existing line (not appending a new one) requires a full
    -- rewrite; this only happens on repeats of the same query, not on
    -- every record().
    local all = M._read_all()
    if #all > 0 then
      all[#all].ts = entry.ts
      all[#all].elapsed_ms = entry.elapsed_ms
    end
    M._write_all(all)
    return
  end

  -- Common case: append one line, no read of the existing file needed.
  M._append_one(entry)

  -- Amortized trim: only rewrite the whole file once it has overshot the
  -- cap by a comfortable margin, instead of re-trimming on every append.
  -- M._read_all() already caps at MAX_ENTRIES, so rewriting its result is
  -- both the trim and the compaction in one step.
  if M._count_lines() > TRIM_THRESHOLD then
    M._write_all(M._read_all())
  end
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
