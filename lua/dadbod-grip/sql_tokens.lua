local M = {}

-- Numeric byte lookups avoid allocating and matching a one-character string
-- for every identifier byte. UTF-8 bytes remain part of the same identifier.
local word_start = {}
for byte = 65, 90 do word_start[byte] = true end
for byte = 97, 122 do word_start[byte] = true end
for byte = 128, 255 do word_start[byte] = true end
word_start[95] = true

-- Default mode preserves the conservative SELECT editability token stream.
-- true adds source positions for mutation parsing. Partial mode returns only
-- complete prefix tokens; execution and editability checks use strict mode.
function M.tokenize(sql_text, adapter_kind, with_positions, partial)
  local tokens, count = {}, 0
  local i, len = 1, #sql_text
  local positions = with_positions == true

  local function read_number()
    local radix_pattern
    if sql_text:byte(i) == 48 then
      local next_byte = sql_text:byte(i + 1)
      radix_pattern = (next_byte == 120 or next_byte == 88) and "^0[xX]_?[%da-fA-F][%da-fA-F_]*"
        or (next_byte == 98 or next_byte == 66) and "^0[bB]_?[01][01_]*"
        or (next_byte == 111 or next_byte == 79) and "^0[oO]_?[0-7][0-7_]*"
    end
    local _, finish
    if radix_pattern then
      _, finish = sql_text:find(radix_pattern, i)
      if not finish then return false end
    else
      _, finish = sql_text:find("^%d[%d_]*", i)
      finish = finish or (i - 1)
      if sql_text:byte(finish + 1) == 46 then
        _, finish = sql_text:find("^%.[%d_]*", finish + 1)
      end
      local next_byte = sql_text:byte(finish + 1)
      if next_byte == 69 or next_byte == 101 then
        local _, exponent_end = sql_text:find("^[eE][+-]?%d[%d_]*", finish + 1)
        finish = exponent_end or finish
      end
    end
    i = finish + 1
    -- A suffix cannot become a separate identifier in source checks.
    return not word_start[sql_text:byte(i)]
  end

  local function read_quoted(quote, escape_string)
    local close_quote = quote == "[" and "]" or quote
    local close_byte = close_quote:byte()
    i = i + 1
    local marker = quote == "'" and sql_text:find("[\\']", i)
      or sql_text:find(close_quote, i, true)
    if not marker then return nil, true end
    -- The usual unescaped string/identifier needs one slice and no pieces table.
    if sql_text:byte(marker) == close_byte and sql_text:byte(marker + 1) ~= close_byte then
      local value = sql_text:sub(i, marker - 1)
      i = marker + 1
      return value
    end
    local value = {}
    while i <= len do
      if not marker then return nil, true end
      if marker > i then
        value[#value + 1] = sql_text:sub(i, marker - 1)
        i = marker
      end
      local byte = sql_text:byte(i)
      if byte == 92 and quote == "'" then
        local start = i
        local _, finish = sql_text:find("^\\+", i)
        i = finish + 1
        local odd = (i - start) % 2 == 1
        if escape_string and odd then
          if i > len then return nil, true end
          i = i + 1
        elseif odd and sql_text:byte(i) == 39
            and (adapter_kind == "postgresql" or adapter_kind == "mysql") then
          -- Session settings can change this quote's closing boundary.
          return nil
        end
        value[#value + 1] = sql_text:sub(start, i - 1)
      elseif byte == close_byte then
        if sql_text:byte(i + 1) == close_byte then
          value[#value + 1] = close_quote
          i = i + 2
        else
          i = i + 1
          return table.concat(value)
        end
      end
      marker = quote == "'" and sql_text:find("[\\']", i)
        or sql_text:find(close_quote, i, true)
    end
    return nil, true
  end

  while i <= len do
    local _, space_end = sql_text:find("^%s*", i)
    i = space_end + 1
    if i > len then break end

    local token_start = i
    local byte, next_byte = sql_text:byte(i, i + 1)
    local token

    if (byte == 45 and next_byte == 45)
        or (with_positions and adapter_kind == "mysql" and byte == 35) then
      local following = sql_text:sub(i + 2, i + 2)
      if byte == 45 and adapter_kind == "mysql" and following ~= ""
          and not following:match("[%s%c]") then
        if not with_positions then return nil end
        -- MySQL value--1 is subtraction, not a comment.
        token, i = { kind = "-" }, i + 1
      else
        local newline = sql_text:find("[\r\n]", i + (byte == 35 and 1 or 2))
        if newline and sql_text:byte(newline) == 13
            and sql_text:byte(newline + 1) ~= 10
            and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb" then return nil end
        i = newline and (newline + 1) or (len + 1)
      end
    elseif byte == 47 and next_byte == 42 then
      -- Executable MySQL/MariaDB comments cannot be discarded safely.
      if adapter_kind == "mysql"
          and (sql_text:byte(i + 2) == 33 or sql_text:sub(i + 2, i + 3) == "M!") then return nil end
      local hint = adapter_kind == "mysql" and sql_text:byte(i + 2) == 43
      local depth = 1
      i = i + 2
      while i <= len and depth > 0 do
        -- mysql executes short client commands even inside optimizer hints.
        -- Ordinary comments retain their usual inert backslash text.
        local marker = sql_text:find(hint and "[/*\\]" or "[/*]", i)
        if hint and marker and sql_text:byte(marker) == 92 then return nil end
        if not marker then i = len + 1; break end
        local pair = sql_text:sub(marker, marker + 1)
        if pair == "/*" then
          if adapter_kind ~= "postgresql" then return nil end
          depth = depth + 1
          i = marker + 2
        elseif pair == "*/" then
          depth = depth - 1
          i = marker + 2
        else
          i = marker + 1
        end
      end
      if depth ~= 0 then return partial and tokens or nil end
    elseif byte == 34 or byte == 96 or byte == 39
        or (byte == 91 and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb") then
      local ch = sql_text:sub(i, i)
      local previous = tokens[count]
      local escape_string = ch == "'" and previous and previous.escape_string
      local ident, incomplete = read_quoted(ch, escape_string)
      if not ident then return incomplete and partial and tokens or nil end
      token = { kind = ch == "'" and "literal" or "ident", text = ident, escape_string = escape_string }
    elseif (byte >= 48 and byte <= 57)
        or (byte == 46 and next_byte and next_byte >= 48 and next_byte <= 57) then
      if not read_number() then return partial and tokens or nil end
      token = { kind = "literal" }
    elseif word_start[byte] then
      local _, finish = sql_text:find("^[%w_$\128-\255]+", i)
      local word = sql_text:sub(i, finish)
      local upper = word:upper()
      i = finish + 1
      if upper == "E" and sql_text:byte(i) == 39
          and (adapter_kind == "postgresql" or adapter_kind == "duckdb") then
        local value, incomplete = read_quoted("'", true)
        if not value then return incomplete and partial and tokens or nil end
        token = { kind = "literal", text = value, escape_string = true }
      else
        token = { kind = "ident", text = word, upper = upper }
      end
    elseif byte == 36 and (adapter_kind == "postgresql" or adapter_kind == "duckdb") then
      local delimiter = sql_text:match("^%$%$", i)
        or sql_text:match("^%$[%a_\128-\255][%w_\128-\255]*%$", i)
      if not delimiter then return partial and tokens or nil end
      local close = sql_text:find(delimiter, i + #delimiter, true)
      if not close then return partial and tokens or nil end
      token = { kind = "literal" }
      i = close + #delimiter
    elseif byte == 36 or (byte == 35 and adapter_kind ~= "postgresql" and adapter_kind ~= "duckdb") then
      return nil
    else
      token = { kind = sql_text:sub(i, i) }
      i = i + 1
    end
    if token then
      if positions then token.start, token.finish = token_start, i - 1 end
      count = count + 1
      tokens[count] = token
    end
  end
  return tokens
end

return M
