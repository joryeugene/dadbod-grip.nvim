-- Bounded, non-executing projection/header planner for native MySQL reads.
-- No function is evaluated to discover columns. Unproven headers are never
-- invented, and legacy routing is decided before the first execution.
local profile = require("dadbod-grip.mysql_profile")
local admission = require("dadbod-grip.provenance")
local M = {}
-- Same MySQL semantic value exclusions as init.select_editable_table. Quoted
-- names and genuine qualified columns are identifiers; bare keywords are not.
local value_keywords = { CURRENT_DATE = true, CURRENT_TIME = true, CURRENT_TIMESTAMP = true, ["NULL"] = true,
  CURRENT_USER = true, CURRENT_ROLE = true, LOCALTIME = true, LOCALTIMESTAMP = true, UTC_DATE = true,
  UTC_TIME = true, UTC_TIMESTAMP = true, ["TRUE"] = true, ["FALSE"] = true }
local read_commands = { SHOW = true, DESCRIBE = true, DESC = true, EXPLAIN = true, PRAGMA = true }
local client_commands = { SOURCE = true, CONNECT = true, SYSTEM = true, TEE = true, NOTEE = true,
  PAGER = true, NOPAGER = true, EDIT = true, EGO = true, GO = true, QUIT = true, EXIT = true,
  RESETCONNECTION = true, CHARSET = true }
local function identifier(token, alias)
  if not token then return nil end
  if token.kind == "word" then return token.raw end
  if token.kind == "quoted" and (token.quote ~= "'" or alias) then
    local value = token.raw:sub(2, -2):gsub(token.quote .. token.quote, token.quote)
    -- Quoting carries spelling, including spaces, Unicode and doubled quotes.
    -- Control bytes/backslashes remain outside this bounded client profile.
    if value ~= "" and not value:find("[%c\\]") then return value end
  end
end
local function lex(sql)
  local tokens, i, depth, terminal, custom, delimiter = {}, 1, 0, nil, false, ";"
  local n, part = #sql, "[%w_$\128-\255]"
  while i <= n do
    local ch, pair = sql:sub(i, i), sql:sub(i, i + 1)
    if ch:match("%s") then i = i + 1
    elseif ch == "#" or (pair == "--" and sql:sub(i + 2, i + 2):match("[%s%c]")) then
      local nl = sql:find("[\r\n]", i + 1)
      if nl and sql:sub(nl, nl) == "\r" and sql:sub(nl + 1, nl + 1) ~= "\n" then
        return nil, "ambiguous line-comment delimiter"
      end
      i = nl and nl + 1 or n + 1
    elseif pair == "/*" then
      local finish, nested = sql:find("*/", i + 2, true), sql:find("/*", i + 2, true)
      if not finish or (nested and nested < finish) then return nil, "unsupported block comment" end
      local mark = sql:sub(i + 2, i + 3):upper()
      if mark:sub(1, 1) == "!" or mark == "M!" then return nil, "executable comments are unsupported" end
      local command = mark:sub(1, 1) == "+" and sql:find("\\", i + 3, true)
      if command and command < finish then return nil, "client command in optimizer hint" end
      i = finish + 2
    else
      if terminal then return nil, "multiple statements are unsupported for SELECT routing" end
      local first, kind, quote = i, "other", nil
      if ch == "'" or ch == '"' or ch == "`" then
        quote, kind, i = ch, "quoted", i + 1
        local closed = false
        while i <= n do
          ch = sql:sub(i, i)
          if ch == "\\" then
            local start = i
            while sql:sub(i, i) == "\\" do i = i + 1 end
            if (i - start) % 2 == 1 and sql:sub(i, i) == quote then return nil, "ambiguous quote escape" end
          elseif ch == quote then
            if sql:sub(i + 1, i + 1) == quote then i = i + 2
            else i = i + 1; closed = true; break end
          else i = i + 1 end
        end
        if not closed then return nil, "unterminated quoted SQL" end
      elseif ch:match(part) then
        repeat i = i + 1 until i > n or not sql:sub(i, i):match(part)
        kind = ch:match("%d") and "number" or "word"
      else
        if ch == "\\" then return nil, "mysql client commands are unsupported" end
        if ch == "(" then depth = depth + 1
        elseif ch == ")" then depth = depth - 1; if depth < 0 then return nil, "unbalanced SQL" end
        elseif ch == ";" and not custom then
          if depth ~= 0 then return nil, "unsupported delimiter" end
          terminal = i
        end
        i = i + 1
      end
      if not terminal then
        local raw = sql:sub(first, i - 1)
        tokens[#tokens + 1] = { raw = raw, upper = raw:upper(), kind = kind, quote = quote,
          first = first, last = i - 1, depth = depth }
        if #tokens == 1 and kind == "word" and raw:upper() ~= "SELECT" and raw:upper() ~= "WITH" then
          if raw:upper() == "VALUES" or raw:upper() == "TABLE" then
            return nil, "unsupported read statement shape"
          end
          if read_commands[raw:upper()] then tokens.read_command = true
          else custom, tokens.custom = true, true end
        end
        if kind == "word" and (client_commands[raw:upper()] or raw:upper():match("^DELIMITER")) then
          local previous = tokens[#tokens - 1]
          local gap = sql:sub(previous and previous.last + 1 or 1, first - 1)
          local after_delimiter = previous and sql:sub(previous.last - #delimiter + 1, previous.last) == delimiter
          if not previous or gap:find("[\r\n]") or after_delimiter then
            if raw:upper() ~= "DELIMITER" or not custom then return nil, "unsupported mysql client command" end
            local newline = sql:find("[\r\n]", i) or n + 1
            local target = sql:sub(i, newline - 1):match("^%s+(%S+)%s*$")
            if target ~= ";" and target ~= "//" and target ~= "$$" then
              return nil, "unsupported routine DELIMITER spelling"
            end
            delimiter = target
            i = newline
          end
        end
      end
    end
  end
  if depth ~= 0 then return nil, "unbalanced SQL" end
  return tokens, nil, terminal
end
local clauses = { WHERE = true, GROUP = true, HAVING = true, WINDOW = true, ORDER = true,
  LIMIT = true, PROCEDURE = true, INTO = true, FOR = true, LOCK = true }
local function parts(tokens, first, last, star)
  local values, i = {}, first
  while i <= last do
    local name = identifier(tokens[i])
    if star and i == last and tokens[i].raw == "*" then name = "*" end
    if not name then return nil end
    values[#values + 1], i = name, i + 1
    if i <= last then if tokens[i].raw ~= "." or i == last then return nil end; i = i + 1 end
  end
  return values
end
local function slot(tokens, first, last, depth)
  local label, provenance, expression_last
  if last - first >= 2 and tokens[last - 1].depth == (depth or 0) and tokens[last - 1].upper == "AS" then
    label, expression_last = identifier(tokens[last], true), last - 2
    if not label then return { kind = "unknown" } end
    provenance = "explicit_as"
  else expression_last = last end
  local path = parts(tokens, first, expression_last, true)
  if path and #path == 1 and tokens[first].kind == "word" and value_keywords[tokens[first].upper] then path = nil end
  if path and #path <= 3 then
    local column = path[#path]
    if column == "*" then
      if label then return { kind = "unknown" } end
      return { kind = "star", path = path }
    end
    return { kind = "direct", path = path, column = column, label = label or column,
      header_provenance = provenance or "direct_projection_spelling", aliased = label ~= nil }
  end
  return { kind = label and "computed" or "unknown", label = label, header_provenance = provenance }
end
local function duplicates(columns)
  local seen = {}
  for _, name in ipairs(columns) do
    if seen[name:lower()] then return "duplicate result label: " .. name end
    seen[name:lower()] = true
  end
end

-- This recognizes only the read statement's prefix/boundary, not expression
-- types or output headers. CTE bodies are structurally delimited; final DML
-- can never enter the safe single-read passthrough route.
local function close_paren(tokens, at, last)
  local target = tokens[at].depth - 1
  for i = at + 1, last do
    if tokens[i].raw == ")" and tokens[i].depth == target then return i end
  end
end
local read_head
read_head = function(tokens, first, last)
  local head = tokens[first]
  if not head then return nil, "missing SELECT statement" end
  if head.raw == "(" then
    local finish = close_paren(tokens, first, last)
    if not finish then return nil, "unbalanced parenthesized read" end
    local inner, err = read_head(tokens, first + 1, finish - 1)
    if not inner then return nil, err end
    if finish < last then
      local op = tokens[finish + 1].upper
      if op ~= "UNION" and op ~= "INTERSECT" and op ~= "EXCEPT" and op ~= "ORDER" and op ~= "LIMIT" then
        return nil, "unproved parenthesized statement boundary"
      end
    end
    return inner
  end
  if head.upper == "SELECT" then return first end
  if head.upper ~= "WITH" then return nil, "WITH/read must end in a SELECT" end
  local i = first + 1
  if tokens[i] and tokens[i].upper == "RECURSIVE" then i = i + 1 end
  while i <= last do
    if not identifier(tokens[i]) then return nil, "unproved WITH name" end
    i = i + 1
    if tokens[i] and tokens[i].raw == "(" then
      local finish = close_paren(tokens, i, last)
      if not finish then return nil, "unproved WITH column list" end
      i = finish + 1
    end
    if not tokens[i] or tokens[i].upper ~= "AS" or not tokens[i + 1] or tokens[i + 1].raw ~= "(" then
      return nil, "unproved WITH query boundary"
    end
    i = i + 1
    local finish = close_paren(tokens, i, last)
    if not finish then return nil, "unproved WITH query body" end
    local body, err = read_head(tokens, i + 1, finish - 1)
    if not body then return nil, err end
    i = finish + 1
    if tokens[i] and tokens[i].raw == "," then i = i + 1
    else return read_head(tokens, i, last) end
  end
  return nil, "WITH/read must end in a SELECT"
end

function M.plan(sql)
  if type(sql) ~= "string" then return nil, "SQL must be a string" end
  local tokens, err, terminal = lex(sql)
  if not tokens then return nil, err end
  if tokens.custom or not tokens[1] then return { route = "custom", sql = sql } end
  if tokens.read_command then
    for _, token in ipairs(tokens) do
      if token.kind == "word" and token.upper == "INTO" then return nil, "unsupported read command INTO" end
    end
    return { route = "legacy", sql = sql }
  end
  local select_at, head_error = read_head(tokens, 1, #tokens)
  if not select_at then return nil, head_error end
  local base_depth = tokens[select_at].depth
  local force_legacy = select_at ~= 1
  local boundary, from, has_limit, sensitive, unsupported = #tokens + 1, nil, false, false, false
  for i, token in ipairs(tokens) do
    local word = token.kind == "word" and token.upper or nil
    local qualified = tokens[i - 1] and tokens[i - 1].raw == "."
    if not qualified and (word == "INTO" or word == "DELIMITER" or word == "FOR" or word == "LOCK" or word == "PROCEDURE") then
      return nil, "unsupported SELECT command boundary: " .. word
    end
    if token.raw == "@" or word == "SQL_CALC_FOUND_ROWS"
        or ((word == "ROW_COUNT" or word == "FOUND_ROWS" or word == "LAST_INSERT_ID")
          and tokens[i + 1] and tokens[i + 1].raw == "(") then sensitive = true end
    if i > select_at and token.depth == base_depth then
      if word == "FROM" and not from then from = i; boundary = math.min(boundary, i) end
      if clauses[word] then boundary = math.min(boundary, i) end
      if word == "LIMIT" then has_limit = true end
      if word == "UNION" or word == "INTERSECT" or word == "EXCEPT" then
        force_legacy, boundary = true, math.min(boundary, i)
      end
    end
    if i > select_at and token.raw == ")" and token.depth < base_depth then boundary = math.min(boundary, i) end
  end
  local first = select_at + 1
  if tokens[first] and (tokens[first].upper == "DISTINCT" or tokens[first].upper == "DISTINCTROW"
      or tokens[first].upper == "ALL") then first = first + 1 end
  if first >= boundary then return nil, "empty or unproved SELECT projection" end
  local slots, start = {}, first
  for i = first, boundary do
    if i == boundary or (tokens[i].depth == base_depth and tokens[i].raw == ",") then
      if i == start then return nil, "empty SELECT projection item" end
      slots[#slots + 1] = slot(tokens, start, i - 1, base_depth); start = i + 1
    end
  end
  local source
  if from then
    local stop = #tokens + 1
    for i = from + 1, #tokens do
      if tokens[i].depth == 0 and tokens[i].kind == "word" and clauses[tokens[i].upper] then stop = i; break end
    end
    local last, alias = stop - 1, nil
    if last > from + 1 and tokens[last] and identifier(tokens[last]) then
      if tokens[last - 1] and tokens[last - 1].upper == "AS" then alias, last = identifier(tokens[last]), last - 2
      elseif tokens[last - 1] and identifier(tokens[last - 1]) then alias, last = identifier(tokens[last]), last - 1 end
    end
    local path = parts(tokens, from + 1, last)
    if path and #path >= 1 and #path <= 2 then
      source = { table = path[#path], schema = #path == 2 and path[1] or nil, alias = alias }
    else unsupported = true end
  end
  local columns, provenance, unknown, wildcard = {}, {}, false, false
  for _, value in ipairs(slots) do
    if value.label then columns[#columns + 1], provenance[#provenance + 1] = value.label, value.header_provenance end
    if value.kind == "unknown" then unknown = true end
    if value.kind == "star" then wildcard = true end
    if value.path and #value.path > 1 then
      local qualifier = value.path[#value.path - 1]
      if not source or (qualifier:lower() ~= (source.alias or source.table):lower()
          and qualifier:lower() ~= source.table:lower()) then unsupported = true end
    end
  end
  local duplicate = duplicates(columns)
  if duplicate then return nil, duplicate end
  if wildcard and (not source or unsupported or sensitive) then force_legacy = true end
  local last = tokens[#tokens].last
  local body = terminal and (sql:sub(1, terminal - 1) .. sql:sub(terminal + 1)) or sql
  local plan = { route = (force_legacy or unknown or sensitive or unsupported) and "legacy" or "derived",
    sql = body, slots = slots, source = source, columns = not wildcard and not unknown and columns or nil,
    header_provenance = not wildcard and not unknown and provenance or nil, needs_schema = wildcard,
    has_limit = has_limit, fence_at = last + 1 }
  return plan
end

local text = { char = true, varchar = true, tinytext = true, text = true, mediumtext = true, longtext = true,
  enum = true, set = true, json = true }
local binary = { binary = true, varbinary = true, tinyblob = true, blob = true, mediumblob = true,
  longblob = true, bit = true, geometry = true, point = true, linestring = true, polygon = true,
  multipoint = true, multilinestring = true, multipolygon = true, geometrycollection = true }
local number = { tinyint = true, smallint = true, mediumint = true, int = true, integer = true,
  bigint = true, decimal = true, numeric = true, float = true, double = true, real = true }
local temporal = { date = true, datetime = true, timestamp = true, time = true, year = true }
local function physical(meta)
  local kind = (meta.data_type or ""):lower():match("^(%a+)")
  local _, err = profile.enum_set(meta.data_type)
  if err then return nil, err end
  return text[kind] and "text" or binary[kind] and "blob" or number[kind] and "number" or temporal[kind] and "other"
end

function M.resolve(plan, descriptor)
  local result = vim.deepcopy(plan)
  local fields = descriptor and descriptor.columns or {}
  local proof = descriptor and vim.deepcopy(descriptor.source_schema_proof)
  if proof and not proof.columns then proof.columns = vim.deepcopy(fields) end
  local lookup = {}
  for index, meta in ipairs(fields) do
    if type(meta.column_name) ~= "string" or lookup[meta.column_name:lower()] then return nil, "invalid source metadata labels" end
    if meta.ordinal ~= index then return nil, "unproved source ordinal metadata" end
    lookup[meta.column_name:lower()] = meta
  end
  result.columns, result.header_provenance, result.source_columns, result.column_info = {}, {}, {}, {}
  result.readonly = true
  local function add(label, provenance, source, aliased)
    result.columns[#result.columns + 1], result.header_provenance[#result.header_provenance + 1] = label, provenance
    result.source_columns[#result.columns] = source and vim.deepcopy(source) or false
    local info = source and vim.deepcopy(source) or {}
    info.kind, info.restorable, info.encoding_proven = "raw_unknown", false, false
    info.aliased = aliased == true
    result.column_info[#result.columns] = info
    return true
  end
  for _, value in ipairs(plan.slots) do
    if value.kind == "star" then
      if #fields == 0 then return nil, "source metadata is required for wildcard headers" end
      for _, meta in ipairs(fields) do
        if type(meta.visible) ~= "boolean" then return nil, "source visibility metadata is unproved" end
        if meta.visible then local ok, err = add(meta.column_name, "source_schema_visible_ordinal", meta); if not ok then return nil, err end end
      end
    else
      if not value.label then return nil, "result header is unproved" end
      local source = value.kind == "direct" and plan.source and lookup[value.column:lower()] or nil
      if value.kind == "direct" and plan.source and #fields > 0 and not source then return nil, "projected column missing from source metadata" end
      local ok, err = add(value.label, value.header_provenance, source, value.aliased)
      if not ok then return nil, err end
    end
  end
  local duplicate = duplicates(result.columns)
  if duplicate then return nil, duplicate end
  result.source_schema_proof = proof
  -- Plain flags are not an attestation. A missing shared contract or provider
  -- leaves physical types unknown, including on empty/all-NULL results.
  local bound = admission.validate_source(proof, result.source_columns, "held") == true
  if bound then
    result.readonly = proof.editable ~= true
    for ci, source in ipairs(result.source_columns) do
      local info = result.column_info[ci]
      if source then
        local kind, err = physical(source)
        if not kind then return nil, err or "unsupported bound source type" end
        info.kind, info.restorable, info.metadata_source = kind, true, "source_schema"
        info.binary = kind == "blob"
        info.encoding_proven = true -- known binary encoding is proof too; it is not UTF8
        if info.aliased then result.readonly = true end
      else result.readonly = true end
    end
  end
  result.source_bound = bound == true
  return result
end

function M.sql(plan)
  local count = #(plan.columns or {})
  assert(count > 0, "derived projection count is unproved")
  local expressions = {}
  local function quoted(value) return "`" .. value:gsub("`", "``") .. "`" end
  for i = 1, count do
    local column = "raw." .. quoted(plan.columns[i])
    expressions[i] = "CASE WHEN " .. column .. " IS NULL THEN 'N' WHEN CHARSET(" .. column
      .. ")='binary' THEN CONCAT('X',HEX(CAST(" .. column .. " AS BINARY))) ELSE CONCAT('T',HEX(CONVERT("
      .. column .. " USING utf8mb4))) END AS " .. quoted(plan.columns[i])
  end
  local original = plan.sql
  if not plan.has_limit then
    original = original:sub(1, plan.fence_at - 1) .. "\nLIMIT 18446744073709551615\n" .. original:sub(plan.fence_at)
  end
  return "SELECT " .. table.concat(expressions, ",") .. " FROM (" .. original .. "\n) AS raw;"
end
return M
