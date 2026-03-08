-- ai.lua -- AI SQL generation from natural language.
-- Multi-provider: Anthropic, OpenAI, Gemini, Ollama.
-- Schema context auto-assembled from grip metadata.

local db      = require("dadbod-grip.db")
local sql_mod = require("dadbod-grip.sql")
local ui      = require("dadbod-grip.ui")

local M = {}

local _opts    = {}
local _enabled = true  -- set to false via setup({ ai = false }) or setup({ ai = { enabled = false } })

-- ── providers ─────────────────────────────────────────────────────────────────

local PROVIDERS = {
  anthropic = {
    name = "Anthropic",
    default_model = "claude-haiku-4-5-20251001",
    env_var = "ANTHROPIC_API_KEY",
    build_request = function(system_prompt, question, model, api_key, base_url)
      local url = (base_url or "https://api.anthropic.com") .. "/v1/messages"
      return {
        url = url,
        headers = {
          "x-api-key: " .. api_key,
          "anthropic-version: 2023-06-01",
          "Content-Type: application/json",
        },
        body = {
          model = model,
          max_tokens = 1024,
          system = system_prompt,
          messages = {{ role = "user", content = question }},
        },
      }
    end,
    parse_response = function(body)
      if body.content and body.content[1] then
        return body.content[1].text
      end
      return nil, "Unexpected Anthropic response format"
    end,
  },
  openai = {
    name = "OpenAI",
    default_model = "gpt-4.1-mini",
    env_var = "OPENAI_API_KEY",
    build_request = function(system_prompt, question, model, api_key, base_url)
      local url = (base_url or "https://api.openai.com") .. "/v1/chat/completions"
      return {
        url = url,
        headers = {
          "Authorization: Bearer " .. api_key,
          "Content-Type: application/json",
        },
        body = {
          model = model,
          messages = {
            { role = "system", content = system_prompt },
            { role = "user", content = question },
          },
          temperature = 0,
        },
      }
    end,
    parse_response = function(body)
      if body.choices and body.choices[1] and body.choices[1].message then
        return body.choices[1].message.content
      end
      return nil, "Unexpected OpenAI response format"
    end,
  },
  gemini = {
    name = "Gemini",
    default_model = "gemini-2.5-flash",
    env_var = "GEMINI_API_KEY",
    build_request = function(system_prompt, question, model, api_key, base_url)
      local url = (base_url or "https://generativelanguage.googleapis.com")
        .. "/v1beta/models/" .. model .. ":generateContent?key=" .. api_key
      return {
        url = url,
        headers = { "Content-Type: application/json" },
        body = {
          system_instruction = { parts = {{ text = system_prompt }} },
          contents = {{ parts = {{ text = question }} }},
        },
      }
    end,
    parse_response = function(body)
      if body.candidates and body.candidates[1]
        and body.candidates[1].content and body.candidates[1].content.parts then
        return body.candidates[1].content.parts[1].text
      end
      return nil, "Unexpected Gemini response format"
    end,
  },
  ollama = {
    name = "Ollama",
    default_model = "codellama",
    env_var = nil,
    build_request = function(system_prompt, question, model, _, base_url)
      local url = (base_url or "http://localhost:11434") .. "/api/chat"
      return {
        url = url,
        headers = { "Content-Type: application/json" },
        body = {
          model = model,
          stream = false,
          messages = {
            { role = "system", content = system_prompt },
            { role = "user", content = question },
          },
        },
      }
    end,
    parse_response = function(body)
      if body.message and body.message.content then
        return body.message.content
      end
      return nil, "Unexpected Ollama response format"
    end,
  },
}

-- ── configuration ─────────────────────────────────────────────────────────────

function M.setup(opts)
  if opts == false then
    _enabled = false
    return
  end
  _enabled = (opts == nil) or (opts.enabled ~= false)
  _opts = vim.tbl_extend("force", {
    provider = nil,
    model = nil,
    api_key = nil,
    base_url = nil,
  }, opts or {})
end

--- Returns false when the user has disabled AI via setup({ ai = false }).
function M.is_enabled()
  return _enabled
end

-- ── key resolution ────────────────────────────────────────────────────────────

--- Resolve API key. Supports direct string, "env:VAR", "cmd:command".
function M.resolve_api_key(provider_name)
  local provider = PROVIDERS[provider_name]
  if not provider then return nil, "Unknown provider: " .. tostring(provider_name) end

  -- 1. Explicit config
  local key = _opts.api_key
  if key then
    if key:match("^env:") then
      local var = key:sub(5)
      local val = os.getenv(var)
      if val and val ~= "" then return val end
      return nil, "Environment variable " .. var .. " is not set"
    elseif key:match("^cmd:") then
      local cmd = key:sub(5)
      local result = vim.system({"sh", "-c", cmd}, { text = true }):wait()
      if result.code == 0 and result.stdout ~= "" then
        return vim.trim(result.stdout)
      end
      return nil, "Command failed: " .. cmd
    else
      return key
    end
  end

  -- 2. Provider's default env var
  if provider.env_var then
    local val = os.getenv(provider.env_var)
    if val and val ~= "" then return val end
  end

  -- 3. Ollama needs no key
  if provider_name == "ollama" then return "" end

  return nil, "No API key found. Set " .. (provider.env_var or "api_key in setup()") .. " or configure ai.api_key"
end

--- Auto-detect provider from available env vars.
function M.resolve_provider()
  -- 1. Explicit config always wins
  if _opts.provider then return _opts.provider end

  -- 2. Auto-detect: Anthropic > OpenAI > Gemini > Ollama
  if os.getenv("ANTHROPIC_API_KEY") and os.getenv("ANTHROPIC_API_KEY") ~= "" then return "anthropic" end
  if os.getenv("OPENAI_API_KEY") and os.getenv("OPENAI_API_KEY") ~= "" then return "openai" end
  if os.getenv("GEMINI_API_KEY") and os.getenv("GEMINI_API_KEY") ~= "" then return "gemini" end
  return "ollama"
end

-- ── schema context ────────────────────────────────────────────────────────────

--- Format one table as compact DDL. Exposed for testing.
function M._format_ddl_line(table_name, columns, pks, fks)
  local pk_set = {}
  for _, pk in ipairs(pks or {}) do pk_set[pk] = true end

  local fk_map = {}
  for _, fk in ipairs(fks or {}) do
    -- Adapters return { column, ref_table, ref_column }; tests use { column_name, foreign_table_name, foreign_column_name }
    local col = fk.column_name or fk.column
    local ref = fk.foreign_table_name or fk.ref_table
    local ref_col = fk.foreign_column_name or fk.ref_column
    if col and ref then
      fk_map[col] = ref .. "." .. (ref_col or "id")
    end
  end

  local parts = {}
  for _, col in ipairs(columns or {}) do
    local name = col.column_name or ""
    local dtype = (col.data_type or ""):gsub("%s+", " ")
    local s = name .. " " .. dtype
    if pk_set[name] then s = s .. " PK" end
    if col.is_nullable == "NO" and not pk_set[name] then s = s .. " NOT NULL" end
    if fk_map[name] then s = s .. " FK->" .. fk_map[name] end
    table.insert(parts, s)
  end

  return "CREATE TABLE " .. table_name .. " (" .. table.concat(parts, ", ") .. ");"
end

--- Schema context cache per URL (avoids re-fetching for every AI call).
local _schema_cache = {}
local SCHEMA_CACHE_TTL = 300  -- 5 minutes

--- Build schema context DDL from database metadata.
function M.build_schema_context(url, question)
  -- Return cached if fresh
  local cached = _schema_cache[url]
  if cached and (os.time() - cached.time) < SCHEMA_CACHE_TTL then
    return cached.ddl, cached.adapter
  end

  vim.notify("Fetching schema...", vim.log.levels.INFO)
  local tables, err = db.list_tables(url)
  if not tables then return "", "unknown" end

  -- Detect adapter name
  local adapter_name = "SQL"
  local u = (url or ""):lower()
  if u:match("^postgres") then adapter_name = "PostgreSQL"
  elseif u:match("^mysql") or u:match("^mariadb") then adapter_name = "MySQL"
  elseif u:match("^sqlite") then adapter_name = "SQLite"
  elseif u:match("^duckdb") then adapter_name = "DuckDB"
  end

  -- Extract table names (adapters return different formats)
  local table_names = {}
  if type(tables) == "table" then
    if tables.rows then
      -- Legacy format: { rows = { {"name"}, ... }, columns = {...} }
      for _, row in ipairs(tables.rows) do
        if row[1] then table.insert(table_names, row[1]) end
      end
    else
      -- Standard format: { {name="tbl", type="table"}, ... }
      for _, t in ipairs(tables) do
        if type(t) == "table" and t.name then
          table.insert(table_names, t.name)
        elseif type(t) == "string" then
          table.insert(table_names, t)
        end
      end
    end
  end
  if #table_names > 30 then
    -- Prioritize tables mentioned in question
    local q = (question or ""):lower()
    local mentioned = {}
    local others = {}
    for _, t in ipairs(table_names) do
      if q:find(t:lower(), 1, true) then
        table.insert(mentioned, t)
      else
        table.insert(others, t)
      end
    end
    table_names = mentioned
    for i = 1, math.min(30 - #table_names, #others) do
      table.insert(table_names, others[i])
    end
  end

  -- Build DDL for each table
  local ddl_lines = {}
  for _, tbl in ipairs(table_names) do
    local cols = db.get_column_info(tbl, url)
    local pks = db.get_primary_keys(tbl, url)
    local fks_ok, fks = pcall(db.get_foreign_keys, tbl, url)
    if not fks_ok then fks = {} end
    if cols and #cols > 0 then
      table.insert(ddl_lines, M._format_ddl_line(tbl, cols, pks, fks))
    end
  end

  local ddl = table.concat(ddl_lines, "\n")
  _schema_cache[url] = { ddl = ddl, adapter = adapter_name, time = os.time() }
  return ddl, adapter_name
end

-- ── SQL cleanup ───────────────────────────────────────────────────────────────

--- Strip markdown code fences and conversational prose from LLM response.
--- Extracts the SQL statement even when wrapped in explanatory text.
function M._strip_fences(text)
  if not text then return "" end
  local s = text

  -- Extract from ```sql ... ``` code block if present
  local fenced = s:match("```%w*%s*\n(.-)```")
  if fenced then return vim.trim(fenced) end

  -- Remove any remaining code fences
  s = s:gsub("^%s*```%w*%s*\n?", "")
  s = s:gsub("\n?%s*```%s*$", "")

  -- SQL keywords that can start or continue a statement
  local sql_kw = "^%s*(" .. table.concat({
    "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP",
    "FROM", "WHERE", "AND", "OR", "ORDER", "GROUP", "HAVING", "LIMIT", "OFFSET",
    "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "ON", "AS", "SET",
    "INTO", "VALUES", "UNION", "INTERSECT", "EXCEPT", "CASE", "WHEN", "THEN",
    "ELSE", "END", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "IS", "NULL",
    "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME", "COALESCE",
  }, "[%s,]|") .. "[%s,])"

  -- If response contains prose + SQL, extract the SQL statement
  local sql_start = s:match("\n(SELECT%s.+)") or s:match("\n(WITH%s.+)")
    or s:match("\n(INSERT%s.+)") or s:match("\n(UPDATE%s.+)")
    or s:match("\n(DELETE%s.+)") or s:match("\n(CREATE%s.+)")
  if sql_start then
    local sql_lines = {}
    for line in sql_start:gmatch("[^\n]+") do
      -- SQL line: starts with a SQL keyword or is indented continuation
      local upper_line = line:upper()
      local is_sql = line:match("^%s+%S") -- indented continuation
      if not is_sql then
        for _, kw in ipairs({"SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "CREATE",
          "FROM", "WHERE", "AND", "OR", "ORDER", "GROUP", "HAVING", "LIMIT", "OFFSET",
          "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "SET", "INTO", "VALUES",
          "UNION", "CASE", "NOT", "COALESCE"}) do
          if upper_line:match("^%s*" .. kw .. "[%s,%(]") or upper_line:match("^%s*" .. kw .. "$") or upper_line:match("^%s*" .. kw .. ";") then
            is_sql = true
            break
          end
        end
      end
      if is_sql then
        table.insert(sql_lines, line)
      elseif #sql_lines > 0 then
        break -- hit prose after SQL, stop
      end
    end
    if #sql_lines > 0 then
      return vim.trim(table.concat(sql_lines, "\n"))
    end
  end

  return vim.trim(s)
end

-- ── generation ────────────────────────────────────────────────────────────────

--- Generate SQL from natural language. Async via curl.
function M.generate_sql(question, url, callback, existing_sql)
  local provider_name = M.resolve_provider()
  local provider = PROVIDERS[provider_name]
  if not provider then
    callback(nil, "Unknown provider: " .. provider_name)
    return
  end

  local api_key, key_err = M.resolve_api_key(provider_name)
  if not api_key then
    callback(nil, key_err)
    return
  end

  local ddl, adapter_name = M.build_schema_context(url, question)
  local system_prompt = "You are a SQL query generator. "
    .. "Output ONLY the raw SQL query. No explanations, no comments, no markdown, no prose, no questions. "
    .. "Do not ask for more information. The complete schema is provided below. "
    .. "Use " .. adapter_name .. "-compatible SQL.\n\n"
    .. "Rules:\n"
    .. "- ONLY use column names that appear in the schema below. Never invent or guess column names.\n"
    .. "- When asked about a column that doesn't exist, pick the closest match from the schema.\n"
    .. "- 'oldest' or 'earliest' = ORDER BY column ASC. 'newest' or 'latest' = ORDER BY column DESC.\n"
    .. "- Filter out NULLs when using ORDER BY, MIN, MAX, or aggregates on nullable columns.\n"
    .. "- Use IS NOT NULL in WHERE clauses when sorting to find extremes.\n"
    .. "- Use LIMIT for 'top N' or 'oldest/newest' queries.\n"
    .. "- Include column aliases for computed columns.\n"
    .. "\nComplete database schema:\n" .. ddl

  if existing_sql and existing_sql ~= "" then
    system_prompt = system_prompt
      .. "\n\nThe user has this existing query in their editor:\n"
      .. existing_sql
      .. "\n\nIf the user's request relates to modifying this query, "
      .. "return the modified version. Otherwise generate a new query."
  end

  local model = _opts.model or provider.default_model
  local req = provider.build_request(system_prompt, question, model, api_key, _opts.base_url)

  -- Build curl args
  local curl_args = { "curl", "-s", "-X", "POST" }
  for _, h in ipairs(req.headers) do
    table.insert(curl_args, "-H")
    table.insert(curl_args, h)
  end
  table.insert(curl_args, "-d")
  table.insert(curl_args, vim.fn.json_encode(req.body))
  table.insert(curl_args, req.url)

  vim.system(curl_args, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, "curl failed: " .. (result.stderr or "unknown error"))
        return
      end

      local ok, body = pcall(vim.fn.json_decode, result.stdout)
      if not ok then
        callback(nil, "Failed to parse response JSON")
        return
      end

      -- Check for API error
      if body.error then
        local err_msg = type(body.error) == "table" and (body.error.message or "API error") or tostring(body.error)
        callback(nil, err_msg)
        return
      end

      local sql_text, parse_err = provider.parse_response(body)
      if not sql_text then
        callback(nil, parse_err or "Failed to extract SQL from response")
        return
      end

      callback(M._strip_fences(sql_text))
    end)
  end)
end

--- Open the AI ask UI: input -> generate SQL -> insert into query pad.
function M.ask(url)
  local query_pad = require("dadbod-grip.query_pad")
  local existing_sql = query_pad.get_content()
  local caller_win = vim.api.nvim_get_current_win()  -- capture before async

  local CANCEL = "\0"
  local ok, question = pcall(vim.fn.input, { prompt = "Ask about your data: ", cancelreturn = CANCEL })
  if not ok or question == CANCEL or question == "" then return end
  ui.blocking("Generating SQL...", function()
    local done = false
    local result_sql, gen_err
    M.generate_sql(question, url, function(sql, err)
      result_sql, gen_err = sql, err
      done = true
    end, existing_sql)
    -- Block until the async curl callback fires.  The event loop pumps every
    -- 50ms so the spinner animates and curl completes naturally.
    vim.wait(30000, function() return done end, 50)
    if gen_err then
      vim.notify("AI: " .. gen_err, vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_win_is_valid(caller_win) then
      vim.api.nvim_set_current_win(caller_win)
    end
    query_pad.open(url)
    query_pad.append_sql(result_sql, existing_sql and { replace = true } or nil)
  end)
end

return M
