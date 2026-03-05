-- completion.lua: native SQL completion for the query pad.
-- Implements omnifunc for <C-x><C-o> and M.complete() for testing.
-- Works for all adapters. Handles DuckDB cross-database federation.

local M = {}

local CACHE_TTL = 300  -- 5 minutes

-- _cache[url] = { tables = { name -> [{column_name, data_type, is_nullable}] }, time }
local _cache = {}

-- ── Schema fetching ────────────────────────────────────────────────────────────

--- Fetch and cache schema for a database URL.
--- Returns { [table_name] = columns[] } where columns have column_name/data_type/is_nullable.
function M.get_schema(url)
  local now = os.time()
  local cached = _cache[url]
  if cached and (now - cached.time) < CACHE_TTL then
    return cached.tables
  end

  local db = require("dadbod-grip.db")
  local result, err = db.list_tables(url)
  if err or not result then return {} end

  local tables = {}
  for _, t in ipairs(result) do
    local name = type(t) == "table" and (t.name or (t.rows and t.rows[1] and t.rows[1][1])) or t
    if name and name ~= "" then
      local cols, _ = db.get_column_info(name, url)
      tables[name] = cols or {}
    end
  end

  _cache[url] = { tables = tables, time = now }
  return tables
end

--- Invalidate the cache for a given URL (call on connection switch or GripAttach/Detach).
function M.invalidate(url)
  _cache[url] = nil
  -- Also invalidate any federated entries keyed as "url::alias"
  local prefix = url .. "::"
  for k in pairs(_cache) do
    if k:sub(1, #prefix) == prefix then
      _cache[k] = nil
    end
  end
end

-- ── Context parsing ────────────────────────────────────────────────────────────

--- Classify the SQL text before the cursor.
--- Returns one of: "table", "column", "dotted", "fed_column", or nil.
--- (Simple string result for the most common cases.)
function M.parse_context(before)
  if not before or before == "" then return nil end
  -- Strip trailing comment
  if before:match("^%-%-") then return nil end

  local up = before:upper()

  -- fed_column: alias.table.word (three-part, check first)
  if before:match("[%w_]+%.[%w_]+%.[%w_]*$") then
    return "fed_column"
  end

  -- dotted: qualifier.word (two-part)
  if before:match("[%w_]+%.[%w_]*$") then
    return "dotted"
  end

  -- Table context: after FROM / JOIN / UPDATE / INSERT INTO
  if up:match("FROM%s+[%w_]*$")
    or up:match("JOIN%s+[%w_]*$")
    or up:match("UPDATE%s+[%w_]*$")
    or up:match("INTO%s+[%w_]*$") then
    return "table"
  end

  -- Column context: after SELECT / WHERE / ORDER BY / GROUP BY / HAVING
  if up:match("SELECT%s+.*$")
    or up:match("WHERE%s+.*$")
    or up:match("ORDER%s+BY%s+.*$")
    or up:match("GROUP%s+BY%s+.*$")
    or up:match("HAVING%s+.*$") then
    return "column"
  end

  return nil
end

--- Full context parse: returns structured table with type, word, qualifier, alias, table fields.
--- Used by omnifunc and by tests that need the full detail.
function M.parse_context_full(before)
  if not before or before == "" then return nil end
  if before:match("^%-%-") then return nil end

  -- fed_column: alias.table.word
  local alias, tbl, word = before:match("([%w_]+)%.([%w_]+)%.([%w_]*)$")
  if alias then
    return { type = "fed_column", alias = alias, table = tbl, word = word }
  end

  -- dotted: qualifier.word
  local qualifier, qword = before:match("([%w_]+)%.([%w_]*)$")
  if qualifier then
    return { type = "dotted", qualifier = qualifier, word = qword }
  end

  local up = before:upper()

  -- Table context
  if up:match("FROM%s+[%w_]*$")
    or up:match("JOIN%s+[%w_]*$")
    or up:match("UPDATE%s+[%w_]*$")
    or up:match("INTO%s+[%w_]*$") then
    local word2 = before:match("([%w_]*)$") or ""
    return { type = "table", word = word2 }
  end

  -- Column context
  if up:match("SELECT%s+.*$")
    or up:match("WHERE%s+.*$")
    or up:match("ORDER%s+BY%s+.*$")
    or up:match("GROUP%s+BY%s+.*$")
    or up:match("HAVING%s+.*$") then
    local word2 = before:match("([%w_]*)$") or ""
    return { type = "column", word = word2 }
  end

  return nil
end

-- ── Completion items ───────────────────────────────────────────────────────────

--- Build a completion item from a string name and optional menu annotation.
local function item(word, menu)
  return { word = word, menu = menu or "" }
end

--- Return completion items for `before` (text before cursor) and the given URL.
--- Optional `aliases` table maps SQL alias -> table_name for dotted completion.
--- Returns array of { word, menu } items.
function M.complete(before, url, aliases)
  aliases = aliases or {}
  local ctx = M.parse_context_full(before)
  if not ctx then return {} end

  local schema = M.get_schema(url)
  local items = {}

  if ctx.type == "table" then
    -- Complete table names
    for name, _ in pairs(schema) do
      if name:sub(1, #ctx.word) == ctx.word then
        table.insert(items, item(name, "[table]"))
      end
    end

  elseif ctx.type == "column" then
    -- Complete column names from all tables
    local seen = {}
    for _, cols in pairs(schema) do
      for _, col in ipairs(cols) do
        local cname = col.column_name
        if cname and not seen[cname] and cname:sub(1, #ctx.word) == ctx.word then
          seen[cname] = true
          table.insert(items, item(cname, "[" .. (col.data_type or "?") .. "]"))
        end
      end
    end

  elseif ctx.type == "dotted" then
    local q = ctx.qualifier
    -- Check if qualifier is a known table alias
    local resolved = aliases[q] or q
    local cols = schema[resolved]
    if cols then
      -- qualifier is a table name (or aliased table): complete its columns
      for _, col in ipairs(cols) do
        local cname = col.column_name
        if cname and cname:sub(1, #ctx.word) == ctx.word then
          table.insert(items, item(cname, "[" .. (col.data_type or "?") .. "]"))
        end
      end
    else
      -- qualifier might be a DuckDB attachment alias: try to get its tables
      local ok, duckdb = pcall(require, "dadbod-grip.adapters.duckdb")
      if ok then
        local atts = duckdb.get_attachments(url)
        for _, att in ipairs(atts) do
          if att.alias == q then
            -- Query attachment tables via DuckDB information_schema
            local db = require("dadbod-grip.db")
            local sql = string.format(
              "SELECT table_name FROM %s.information_schema.tables WHERE table_schema = 'main'",
              q
            )
            local result, _ = db.query(sql, url)
            if result and result.rows then
              for _, row in ipairs(result.rows) do
                local tname = row[1]
                if tname and tname:sub(1, #ctx.word) == ctx.word then
                  table.insert(items, item(tname, "[table]"))
                end
              end
            end
            break
          end
        end
      end
    end

  elseif ctx.type == "fed_column" then
    -- Three-part: alias.table.word
    -- Fetch columns from the attachment table
    local db = require("dadbod-grip.db")
    local sql = string.format(
      "SELECT column_name, data_type FROM %s.information_schema.columns WHERE table_name = '%s' AND table_schema = 'main'",
      ctx.alias, ctx.table
    )
    local result, _ = db.query(sql, url)
    if result and result.rows then
      for _, row in ipairs(result.rows) do
        local cname, dtype = row[1], row[2]
        if cname and cname:sub(1, #ctx.word) == ctx.word then
          table.insert(items, item(cname, "[" .. (dtype or "?") .. "]"))
        end
      end
    end
  end

  return items
end

-- ── Omnifunc ───────────────────────────────────────────────────────────────────

--- Standard Vim omnifunc. Set as vim.bo.omnifunc in query_pad.
--- Triggered by <C-x><C-o> in insert mode.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    -- Return the column where the current completion word starts.
    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte position
    local start = col
    -- Walk back over word chars only (alnum + underscore).
    -- Stop at dot, space, comma, etc. so dotted completions like
    -- "supplier.sh" replace only "sh" and leave "supplier." intact.
    while start > 0 do
      local ch = line:sub(start, start)
      if ch:match("[%w_]") then
        start = start - 1
      else
        break
      end
    end
    return start
  else
    -- Return completion items.
    local url = vim.b.db
    if not url or url == "" then return {} end

    local line = vim.api.nvim_get_current_line()
    local col  = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)

    -- For dotted completion, we need the full context including qualifier.
    -- The `base` from Vim may strip the qualifier, so we use `before` directly.
    local raw_items = M.complete(before, url)
    local vim_items = {}
    for _, it in ipairs(raw_items) do
      table.insert(vim_items, {
        word = it.word,
        menu = it.menu,
        icase = 1,
      })
    end
    return vim_items
  end
end

-- ── Auto-complete (as-you-type) ────────────────────────────────────────────────

--- Install a TextChangedI autocmd that fires vim.fn.complete() in insert mode.
--- Completions appear automatically without any keypress.
--- url_fn() returns the current connection URL (re-read live on each keystroke).
--- Kept separate from omnifunc so nvim-cmp users who add { name = 'omni' } also work.
function M.setup_auto_complete(bufnr, url_fn)
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    callback = function()
      local url = url_fn()
      if not url or url == "" then return end

      local line = vim.api.nvim_get_current_line()
      local col  = vim.api.nvim_win_get_cursor(0)[2]
      local before = line:sub(1, col)

      local ctx = M.parse_context_full(before)
      if not ctx then return end

      -- Keyword contexts (table/column): require ≥1 char to avoid firing on bare keyword
      if (ctx.type == "table" or ctx.type == "column") and #ctx.word == 0 then return end

      local raw = M.complete(before, url)
      if #raw == 0 then return end

      -- Compute start column (same walk-back as omnifunc findstart)
      local start = col
      while start > 0 do
        local ch = line:sub(start, start)
        if ch:match("[%w_]") then start = start - 1 else break end
      end

      local vim_items = {}
      for _, it in ipairs(raw) do
        table.insert(vim_items, { word = it.word, menu = it.menu, icase = 1 })
      end
      if vim.fn.pumvisible() == 0 then
        vim.fn.complete(start + 1, vim_items)
      end
    end,
  })
end

return M
