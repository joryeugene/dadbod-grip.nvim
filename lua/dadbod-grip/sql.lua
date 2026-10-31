-- sql.lua: pure SQL generation.
-- No DB calls. No state. Pure string builders.

local M = {}

-- Quote a value for use in SQL.
-- nil    → NULL
-- string → 'value' with single-quote escaping
-- number → n
-- bool   → TRUE / FALSE
-- Escape a value for embedding in a single-quoted SQL string literal.
-- Only the quote doubling: callers add the surrounding quotes themselves,
-- which is what every catalog query in the adapters needs.
-- Returns exactly one value, so it is safe as the last argument to
-- string.format (a bare :gsub() there leaks its match count as an extra arg).
function M.escape_literal(v)
  return (tostring(v):gsub("'", "''"))
end
local escape_literal = M.escape_literal

function M.quote_value(v, adapter_kind, storage_type, exact)
  local problem=require('dadbod-grip.provenance').kind_error(storage_type);assert(not problem,problem)
  if v == nil or v == vim.NIL then
    return "NULL"
  elseif (adapter_kind == "sqlite" or adapter_kind == "mysql" or adapter_kind == "mariadb") and storage_type == "blob" then
    return "X'" .. tostring(v):gsub(".", function(ch) return string.format("%02x", ch:byte()) end) .. "'"
  elseif adapter_kind == "sqlite" and storage_type == "integer" then
    assert(tostring(v):match("^%-?%d+$"), "invalid integer receipt")
    return tostring(v)
  elseif adapter_kind == "sqlite" and storage_type == "real" then
    local numeric = exact or tostring(v)
    if numeric == "Inf" then numeric = "9e999" elseif numeric == "-Inf" then numeric = "-9e999" end
    assert(numeric:match("^[%+%-]?[%d%.]+[eE]?[%+%-]?%d*$"), "invalid real receipt")
    return "CAST(" .. numeric .. " AS REAL)"
  elseif type(v) == "boolean" then
    return v and "TRUE" or "FALSE"
  elseif type(v) == "number" then
    return tostring(v)
  else
    if tostring(v):find("\0", 1, true) then
      assert(adapter_kind ~= "postgresql", "PostgreSQL text cannot contain NUL bytes")
      local hex = tostring(v):gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
      if adapter_kind == "mysql" or adapter_kind == "mariadb" then
        return "CONVERT(X'" .. hex .. "' USING utf8mb4)"
      elseif adapter_kind == "duckdb" then return "decode(from_hex('" .. hex .. "'))" end
      return "CAST(X'" .. hex .. "' AS TEXT)"
    end
    return "'" .. escape_literal(v) .. "'"
  end
end

--- Wrap statements in the transaction syntax accepted by the target adapter.
function M.wrap_transaction(statements, adapter_kind)
  local begin_stmt = adapter_kind == "sqlserver"
      and "SET XACT_ABORT ON;\nBEGIN TRANSACTION;" or "BEGIN;"
  local commit_stmt = adapter_kind == "sqlserver" and "COMMIT TRANSACTION;" or "COMMIT;"
  return begin_stmt .. "\n" .. table.concat(statements, ";\n") .. ";\n" .. commit_stmt
end

-- Quote a column or table identifier with double-quotes.
function M.quote_ident(name)
  -- Split on . and quote each part: schema.table → "schema"."table"
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    table.insert(parts, '"' .. part:gsub('"', '""') .. '"')
  end
  return table.concat(parts, ".")
end
local quote_ident = M.quote_ident

-- A column label is one identifier, even when its spelling contains a dot.
function M.quote_column(name)
  return '"' .. tostring(name):gsub('"', '""') .. '"'
end
local quote_column = M.quote_column

-- Strip outer quotes from each part of a possibly schema-qualified identifier.
-- Inverse of quote_ident: "public"."Participant" → public.Participant
-- Handles double-quotes, backticks, and escaped internal quotes.
-- Bare identifiers pass through unchanged.
function M.unquote_ident(name)
  local parts = {}
  for part in tostring(name):gmatch("[^.]+") do
    if part:match('^"') and part:match('"$') then
      part = part:sub(2, -2):gsub('""', '"')
    elseif part:match("^`") and part:match("`$") then
      part = part:sub(2, -2):gsub("``", "`")
    end
    table.insert(parts, part)
  end
  return table.concat(parts, ".")
end

-- Split a possibly schema-qualified table name and unquote both parts.
-- Catalog tables (information_schema, pg_catalog, …) store bare names, so
-- quoted identifiers must be stripped before they can be compared.
-- default_schema is used when the name carries no qualifier; adapters pass
-- their own ("public", "dbo", the connected database, …).
function M.split_table_name(table_name, default_schema)
  local schema, tbl = table_name:match("^([^.]+)%.(.+)$")
  if not schema then
    schema = default_schema
    tbl = table_name
  end
  return M.unquote_ident(schema), M.unquote_ident(tbl)
end

--- Split a URL authority ("user:password@host:port") into its three parts.
--- `user` is nil when there is no "@" at all; `password` is nil when the
--- userinfo carries no ":". `host` is always the remainder.
---
--- The split is on the LAST "@", mirroring parse_dadbod_url's own rule below:
--- a password may itself contain "@", and splitting on the first one would
--- leave the rest of the password — everything between that first "@" and the
--- real one before the host — outside whatever the caller does with it. That
--- is not academic: adapters/duckdb.lua's url_to_dsn used to split on the
--- first "@" and put the tail of the password into host=, which then defeated
--- the ATTACH-error mask downstream.
---
--- The single copy of that rule: redact_url, url_password and url_to_dsn all
--- go through here.
--- @param authority string
--- @return string|nil user
--- @return string|nil password
--- @return string host
local function split_authority(authority)
  local at = nil
  for i = #authority, 1, -1 do
    if authority:sub(i, i) == "@" then at = i; break end
  end
  if not at then return nil, nil, authority end
  local userinfo, host = authority:sub(1, at - 1), authority:sub(at + 1)
  local colon = userinfo:find(":", 1, true)
  if not colon then return userinfo, nil, host end
  return userinfo:sub(1, colon - 1), userinfo:sub(colon + 1), host
end
M.split_authority = split_authority

--- The password out of a URL's authority, or nil when there is none.
---
--- For callers that must scrub a password out of text they did not build —
--- a CLI's own stderr, say, which may have rewritten the URL past
--- recognition. redact_url() is the wrong tool there: it rewrites a URL it
--- can still see, whereas masking the *value* survives re-quoting,
--- truncation, percent-decoding and path-prefixing. See
--- adapters/duckdb.lua's redact_attach_error for the case that forced it.
--- @param url string|nil
--- @return string|nil password
function M.url_password(url)
  if type(url) ~= "string" then return nil end
  local authority = url:match("://([^/]*)")
  if not authority then return nil end
  local _, password = split_authority(authority)
  if password == nil or password == "" then return nil end
  return password
end

--- Mask the password in a connection URL for display in logs, errors, notifications.
--- The authority component is captured up to the next "/" (so this never
--- reaches into the path or query — a "/" always ends the search). Inside
--- that component, the split is on the LAST "@", mirroring
--- parse_dadbod_url's own rule below: a password may itself contain "@",
--- and splitting on the first one would leave the rest of the password —
--- everything between that first "@" and the real one before the host — in
--- cleartext right next to the mask. See redact_spec.lua for both cases.
---
--- Callers also feed this whatever the user typed as a URL even after it has
--- failed to parse (e.g. "Invalid MySQL URL: " .. redact_url(url)), so a
--- string with no "://" at all still needs a pass: fall back to masking any
--- "ident:secret@" run found anywhere in it, as long as neither side contains
--- whitespace. A real URL never has unescaped whitespace, so that costs
--- nothing on the input this fallback is actually for; it exists to keep the
--- fallback from treating an entire free-form sentence as one giant
--- credential (see redact_spec.lua). It is still just a heuristic scan, not
--- authority-aware like the "://" branch above: an incidental
--- whitespace-free "word:word@word" inside non-URL text can still get
--- masked. Callers should feed it a URL argument, not a full error message
--- built from other text.
--- @param url string|nil
--- @return string
function M.redact_url(url)
  if not url then return "" end
  if url:find("://", 1, true) then
    return (url:gsub("://([^/]*)", function(authority)
      local user, password, host = split_authority(authority)
      -- No "@", or no ":" in the userinfo: nothing that is a password.
      if not user or not password then return "://" .. authority end
      return "://" .. user .. ":***@" .. host
    end))
  end
  return (url:gsub("([^:/@%s]+):([^@%s]*)@", "%1:***@"))
end

-- Parse a dadbod-style connection URL into its components.
-- "scheme://user:pass@host:port/dbname" → {user, pass, host, port, dbname}
-- The auth part is matched greedily up to the last @ so passwords may contain @.
-- Missing pieces stay nil except host and port, which fall back to 127.0.0.1
-- and default_port (each adapter passes its own). Returns nil if there is no
-- "scheme://" prefix at all. No percent-decoding: values are passed to the
-- client CLIs verbatim, exactly as dadbod hands them over.
function M.parse_dadbod_url(url, default_port)
  local rest = url:match("^%w+://(.+)$")
  if not rest then return nil end

  local user, pass, host, port, dbname

  -- Split auth@hostpath (match last @ to support passwords containing @)
  local auth, hostpath = rest:match("^(.+)@([^@]+)$")
  if not auth then
    hostpath = rest
  else
    user, pass = auth:match("^([^:]*):(.*)$")
    if not user then user = auth end
  end

  -- Split hostpath into host:port/dbname
  local hp, db = hostpath:match("^([^/]+)/(.+)$")
  if not hp then hp = hostpath end
  dbname = db

  host, port = hp:match("^([^:]+):(%d+)$")
  if not host then host = hp end

  return {
    user   = user,
    pass   = pass,
    host   = host or "127.0.0.1",
    port   = port or default_port,
    dbname = dbname,
  }
end

local function write_options(settings)
  if type(settings) == "table" then return settings end
  return { adapter_kind = settings }
end

local function where_keys(pk_values, opts)
  local parts = {}
  for col, val in pairs(pk_values) do
    assert(val ~= nil and val ~= vim.NIL, "row identity cannot contain NULL")
    if opts.adapter_kind == 'sqlite' and opts.key_types and opts.key_types[col] then
      parts[#parts + 1] = 'typeof(' .. quote_column(col) .. ') = ' .. M.quote_value(opts.key_types[col])
    end
    parts[#parts + 1] = quote_column(col) .. " = " .. M.quote_value(val, opts.adapter_kind,
      opts.key_types and opts.key_types[col], opts.key_exact and opts.key_exact[col])
  end
  assert(#parts > 0, "row identity is missing")
  table.sort(parts)
  return table.concat(parts, " AND ")
end

-- Values and predicates are independent structures. Never locate SQL clauses
-- by searching generated SQL, where the same words can occur inside literals.
function M.build_update(table_name, pk_values, changes, settings)
  local opts, set_parts = write_options(settings), {}
  for col, val in pairs(changes) do
    set_parts[#set_parts + 1] = quote_column(col) .. " = " .. M.quote_value(val, opts.adapter_kind,
      opts.value_types and opts.value_types[col], opts.value_exact and opts.value_exact[col])
  end
  table.sort(set_parts)
  local identity_clause = where_keys(pk_values, opts)
  return "UPDATE " .. quote_ident(table_name) .. " SET " .. table.concat(set_parts, ", ")
    .. " WHERE " .. (opts.predicate or identity_clause)
end

function M.build_insert(table_name, values, columns, settings, override_identity)
  local opts, col_parts, val_parts = write_options(settings), {}, {}
  for _, col in ipairs(columns) do
    if values[col] ~= nil then
      col_parts[#col_parts + 1] = quote_column(col)
      val_parts[#val_parts + 1] = M.quote_value(values[col], opts.adapter_kind,
        opts.value_types and opts.value_types[col], opts.value_exact and opts.value_exact[col])
    end
  end
  if #col_parts == 0 then return "INSERT INTO " .. quote_ident(table_name) .. " DEFAULT VALUES" end
  return "INSERT INTO " .. quote_ident(table_name) .. " (" .. table.concat(col_parts, ", ") .. ")"
    .. ((opts.override_identity or override_identity) and " OVERRIDING SYSTEM VALUE" or "")
    .. " VALUES (" .. table.concat(val_parts, ", ") .. ")"
end

function M.build_delete(table_name, pk_values, settings)
  return "DELETE FROM " .. quote_ident(table_name) .. " WHERE " .. where_keys(pk_values, write_options(settings))
end

-- M.preview_staged(table_name, updates, deletes, inserts) → string
-- Generates a multi-line SQL preview of all staged changes.
-- updates: from data.get_updates(), deletes: from data.get_deletes(), inserts: from data.get_inserts()
function M.preview_staged(table_name, updates, deletes, inserts)
  local stmts = {}
  for _, del in ipairs(deletes) do
    table.insert(stmts, M.build_delete(table_name, del.pk_values, del) .. ";")
  end
  for _, upd in ipairs(updates) do
    table.insert(stmts, M.build_update(table_name, upd.pk_values, upd.changes, upd) .. ";")
  end
  for _, ins in ipairs(inserts) do
    table.insert(stmts, M.build_insert(table_name, ins.values, ins.columns, ins) .. ";")
  end
  if #stmts == 0 then return "-- no staged changes" end
  return table.concat(stmts, "\n")
end

return M
