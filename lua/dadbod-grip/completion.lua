-- completion.lua: native SQL completion for the query pad.
-- Implements omnifunc (<C-x><C-o>), auto-trigger (TextChangedI), and
-- a first-class nvim-cmp source ({ name = 'dadbod_grip' }).
-- Works for all adapters. Handles DuckDB cross-database federation.
-- Supports SQL alias tracking: FROM employees e → e. completes employees cols.

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

-- ── Alias extraction ───────────────────────────────────────────────────────────

-- SQL keywords that cannot be table aliases.
local _ALIAS_KEYWORDS = {
  WHERE=1, ON=1, SET=1, INNER=1, LEFT=1, RIGHT=1, FULL=1, OUTER=1, CROSS=1,
  HAVING=1, GROUP=1, ORDER=1, LIMIT=1, OFFSET=1, UNION=1, INTERSECT=1,
  EXCEPT=1, INTO=1, AS=1, AND=1, OR=1, NOT=1, NULL=1, IS=1, IN=1,
  LIKE=1, BETWEEN=1, WHEN=1, THEN=1, ELSE=1, END=1, CASE=1, WITH=1,
  SELECT=1, FROM=1, JOIN=1, BY=1,
}

--- Parse a SQL string and return a map of alias → table_name.
--- Recognises FROM/JOIN with optional AS keyword.
--- Aliases that match SQL keywords are skipped.
--- Returns { ["e"] = "employees", ["d"] = "departments", ... } (lowercase keys/values).
function M.extract_aliases(sql)
  if not sql or sql == "" then return {} end
  local up  = sql:upper()
  local aliases = {}

  -- Strip quotes from table name (handles "table", `table`, 'table').
  -- Use long-bracket literal to avoid Lua escape issues with backtick.
  local function strip_quotes(s)
    return (s:gsub([=[^["'`](.*)["'`]$]=], "%1"))
  end

  -- Pattern A/C: FROM/JOIN table AS alias
  for tbl, alias in up:gmatch("[%u][%u]*%s+([%w_%.\"'`]+)%s+AS%s+([%w_]+)") do
    local a_up = alias:upper()
    if not _ALIAS_KEYWORDS[a_up] then
      aliases[alias:lower()] = strip_quotes(tbl):lower()
    end
  end

  -- Pattern B/D: FROM/JOIN table alias (no AS)
  -- Match FROM or JOIN specifically to avoid false hits inside SELECT lists
  for kw, tbl, alias in up:gmatch("(FROM%s+)([%w_%.\"'`]+)%s+([%w_]+)") do
    _ = kw  -- unused, present to anchor the pattern
    local a_up = alias:upper()
    if not _ALIAS_KEYWORDS[a_up] then
      local key = alias:lower()
      if not aliases[key] then   -- AS-form wins if already set
        aliases[key] = strip_quotes(tbl):lower()
      end
    end
  end
  for kw, tbl, alias in up:gmatch("(JOIN%s+)([%w_%.\"'`]+)%s+([%w_]+)") do
    _ = kw
    local a_up = alias:upper()
    if not _ALIAS_KEYWORDS[a_up] then
      local key = alias:lower()
      if not aliases[key] then
        aliases[key] = strip_quotes(tbl):lower()
      end
    end
  end

  return aliases
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

--- SQL keywords returned when no schema context is detected (start of query).
local SQL_KEYWORDS = {
  "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN",
  "FULL OUTER JOIN", "ON", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET",
  "UNION", "UNION ALL", "INTERSECT", "EXCEPT", "WITH", "AS", "DISTINCT",
  "INSERT INTO", "UPDATE", "DELETE FROM", "SET", "VALUES",
  "AND", "OR", "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "NOT IN",
  "LIKE", "ILIKE", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
  "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST",
}

--- Return completion items for `before` (text before cursor) and the given URL.
--- Optional `aliases` table maps SQL alias -> table_name for dotted completion.
--- Returns array of { word, menu } items.
function M.complete(before, url, aliases)
  aliases = aliases or {}
  local ctx = M.parse_context_full(before)
  if not ctx then
    -- No SQL context yet: complete keywords by prefix (e.g. "SEL" -> "SELECT").
    local word = before:match("([%w_]*)$") or ""
    if word == "" then return {} end
    local up_word = word:upper()
    local kw_items = {}
    for _, kw in ipairs(SQL_KEYWORDS) do
      if kw:sub(1, #up_word) == up_word then
        table.insert(kw_items, item(kw, "[keyword]"))
      end
    end
    return kw_items
  end

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

  -- For table/column contexts, also append keyword matches for the typed word.
  -- This lets "SELECT col f" offer both column names AND "FROM".
  -- Skip dotted/fed_column: ctx.word is after the dot, keywords don't apply there.
  if ctx.type == "table" or ctx.type == "column" then
    local up_word = ctx.word:upper()
    if up_word ~= "" then
      for _, kw in ipairs(SQL_KEYWORDS) do
        if kw:sub(1, #up_word) == up_word then
          table.insert(items, item(kw, "[keyword]"))
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

    -- Extract aliases from the full buffer so dotted completion resolves
    -- e.g. "SELECT e." where "FROM employees e" appears elsewhere in the query.
    local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local aliases   = M.extract_aliases(table.concat(all_lines, "\n"))

    -- For dotted completion, we need the full context including qualifier.
    -- The `base` from Vim may strip the qualifier, so we use `before` directly.
    local raw_items = M.complete(before, url, aliases)
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
  -- Disable nvim-cmp for this specific buffer so it doesn't conflict with the
  -- native popup. BufEnter fires before insert mode, so the disable is in place
  -- before TextChangedI. No-op when nvim-cmp is not installed.
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    callback = function()
      pcall(function() require("cmp").setup.buffer({ enabled = false }) end)
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    callback = function()
      -- Defer past all TextChangedI handlers (blink, cmp, etc.) so their popups
      -- appear first. We only show our popup if nothing else is visible.
      vim.schedule(function()
        if vim.fn.pumvisible() == 1 then return end

        local url = url_fn()
        if not url or url == "" then return end

        local line = vim.api.nvim_get_current_line()
        local col  = vim.api.nvim_win_get_cursor(0)[2]
        local before = line:sub(1, col)

        -- Require ≥1 word char to avoid firing on space, comma, newline.
        local word = before:match("([%w_]*)$") or ""
        if word == "" then return end

        local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local aliases   = M.extract_aliases(table.concat(all_lines, "\n"))

        local raw = M.complete(before, url, aliases)
        if #raw == 0 then return end

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
      end)
    end,
  })
end

-- ── nvim-cmp source ────────────────────────────────────────────────────────────

--- Register dadbod-grip as a first-class nvim-cmp completion source.
--- Safe to call multiple times — nvim-cmp deduplicates by source name.
--- Users opt in by adding { name = 'dadbod_grip' } to their cmp sources:
---
---   require('cmp').setup({ sources = { { name = 'dadbod_grip' }, ... } })
---
--- Without nvim-cmp installed this is a no-op.
function M.register_cmp_source()
  local ok, cmp = pcall(require, "cmp")
  if not ok then return end

  local source = {}

  -- Only active when a database connection is configured for the buffer.
  function source:is_available()
    local url = vim.b.db or vim.g.db
    return url ~= nil and url ~= ""
  end

  function source:get_debug_name()
    return "dadbod_grip"
  end

  -- Fire automatically on "." (dotted context: alias.col, tbl.col, fed.tbl.col).
  -- Keyword context (FROM, WHERE) is handled by the TextChangedI autocmd.
  function source:get_trigger_characters()
    return { "." }
  end

  function source:complete(params, callback)
    local url = vim.b.db or vim.g.db
    if not url or url == "" then callback(nil) return end

    local before = params.context.cursor_before_line
    local bufnr  = params.context.bufnr

    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local aliases   = M.extract_aliases(table.concat(all_lines, "\n"))

    local raw = M.complete(before, url, aliases)
    if #raw == 0 then callback(nil) return end

    -- Map to LSP CompletionItem format that nvim-cmp expects.
    local cmp_types = require("cmp.types")
    local items = {}
    for _, it in ipairs(raw) do
      -- Choose kind: table entries get Module icon, columns get Field icon.
      local kind = cmp_types.lsp.CompletionItemKind.Field
      if it.menu == "[table]" then
        kind = cmp_types.lsp.CompletionItemKind.Module
      end
      table.insert(items, {
        label      = it.word,
        detail     = it.menu,
        kind       = kind,
        insertText = it.word,
      })
    end
    callback({ items = items, isIncomplete = false })
  end

  cmp.register_source("dadbod_grip", source)
end

return M
