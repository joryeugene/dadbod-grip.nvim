-- Parse single-target mutation previews. Token positions let us keep
-- predicate text intact while ignoring keywords inside comments or expressions.
local sql = require("dadbod-grip.sql")
local M = {}

local clauses = {
  SET = true, WHERE = true, ORDER = true, LIMIT = true, OFFSET = true,
  RETURNING = true, OUTPUT = true, USING = true, FROM = true, OPTION = true,
  JOIN = true, INNER = true, LEFT = true, RIGHT = true, FULL = true,
  CROSS = true, NATURAL = true, INDEXED = true, NOT = true, PARTITION = true,
  WITH = true, USE = true, FORCE = true, IGNORE = true,
}
-- T-SQL generally permits adjacent statements without semicolons. These
-- command keywords cannot appear unquoted as scalar identifiers.
local sqlserver_commands = {
  INSERT = true, UPDATE = true, DELETE = true, MERGE = true, TRUNCATE = true,
  ALTER = true, CREATE = true, DROP = true, EXEC = true, EXECUTE = true,
  DECLARE = true, BEGIN = true, COMMIT = true, ROLLBACK = true, SAVE = true,
  USE = true, GRANT = true, DENY = true, REVOKE = true, BACKUP = true,
  RESTORE = true, DBCC = true, CHECKPOINT = true, RECONFIGURE = true,
  SHUTDOWN = true, KILL = true, BULK = true, IF = true, WHILE = true,
  GOTO = true, RETURN = true, BREAK = true, CONTINUE = true, WAITFOR = true,
  PRINT = true, RAISERROR = true, OPEN = true, CLOSE = true, DEALLOCATE = true,
  SETUSER = true, READTEXT = true, WRITETEXT = true, UPDATETEXT = true,
  SET = "set", SELECT = "select", CASE = "case", END = "end",
  ENABLE = "trigger", DISABLE = "trigger", GO = "batch",
  EXIT = "client", QUIT = "client", RESET = "client", ED = "client", ON = "on_error",
  [":"] = "directive", ["!"] = "shell",
}
local closes = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
local expression_prefix = {
  WHERE = true, AND = true, OR = true, NOT = true, IS = true, IN = true,
  LIKE = true, BETWEEN = true, WHEN = true, THEN = true, ELSE = true,
  CASE = true, COLLATE = true,
}

function M.parse(text, tokens, adapter_kind, stmt_type)
  local function reject()
    return nil, "Cannot safely preview this mutation; use a single target table"
  end
  local inserting = stmt_type == "INSERT" or stmt_type == "REPLACE"
  if not tokens or not tokens[1] or tokens[1].upper ~= stmt_type
      or (not inserting and stmt_type ~= "UPDATE" and stmt_type ~= "DELETE") then return reject() end

  local function raw(first, last)
    return text:sub(tokens[first].start, tokens[last or first].finish)
  end
  local function name(token)
    return adapter_kind == "postgresql" and token.upper and token.text:lower() or token.text
  end
  local function same(a, b)
    if adapter_kind == "postgresql" then return name(a) == name(b) end
    return a.text:lower() == b.text:lower()
  end
  local function path(pos)
    local parts = {}
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil, pos end
    repeat
      parts[#parts + 1] = tokens[pos]
      pos = pos + 1
      if not tokens[pos] or tokens[pos].kind ~= "." then break end
      pos = pos + 1
      if not tokens[pos] or tokens[pos].kind ~= "ident" then return nil, pos end
    until false
    return parts, pos
  end

  -- A single terminal semicolon is allowed. Never preview only one statement
  -- while retaining multiple statements in the SQL offered for execution.
  local depth, stack, matching, last = {}, {}, {}, #tokens
  local sqlserver = adapter_kind == "sqlserver"
  local sqlserver_set, sqlserver_select, case_depth = false, false, 0
  for idx, token in ipairs(tokens) do
    depth[idx] = #stack
    if token.kind == "ident" and not token.upper then
      -- The shared lexer tolerates several identifier quote styles. A CLI
      -- must recognize the same boundary or hidden client commands can escape.
      local quote = text:byte(token.start)
      if (quote == 96 and (adapter_kind == "postgresql" or adapter_kind == "sqlserver"))
          or (quote == 91 and adapter_kind == "mysql")
          or (quote == 91 and adapter_kind == "sqlite" and raw(idx):find("]]", 1, true)) then return reject() end
    end
    -- Preview SQL is sent to CLI stdin. Bare backslashes can invoke psql/mysql
    -- client commands; supported SQL uses them only inside quoted tokens.
    if token.kind == "\\" then return reject() end
    local action = sqlserver and sqlserver_commands[token.upper or token.kind]
    if action then
      local previous, following = tokens[idx - 1], tokens[idx + 1]
      local line_command = (action == "directive"
          and (not following or following.kind ~= ":" or following.start ~= token.finish + 1)
          and (not previous or previous.kind ~= ":" or token.start ~= previous.finish + 1))
        or (action == "shell" and following and following.kind == "!")
      local client_token = (action == "batch" or action == "client") and token
      if action == "on_error" and following and following.upper == "ERROR"
          and following.start == token.finish + 2 and text:byte(token.finish + 1) == 32 then
        client_token = following
      end
      if client_token then
        -- sqlcmd matches whitespace or EOL after these words, and also '('
        -- after EXIT. Adjacent operators keep ordinary identifiers intact.
        local next_byte = text:byte(client_token.finish + 1)
        line_command = not next_byte or next_byte == 9 or next_byte == 10
          or next_byte == 13 or next_byte == 32 or (token.upper == "EXIT" and next_byte == 40)
      end
      -- sqlcmd commands operate at physical line starts even inside SQL
      -- parentheses. Examine only bounded gaps between tokens; they cannot
      -- rescan a long SQL prefix or confuse quoted text with client commands.
      if line_command and (not previous
          or text:sub(previous.finish + 1, token.start - 1):find("[\r\n]")) then
        return reject()
      end
      if idx > 1 and #stack == 0 and previous.kind ~= "." and previous.kind ~= "@"
          and (not following or following.kind ~= ".") then
        if action == true
            or (action == "trigger" and following and following.upper == "TRIGGER") then return reject() end
        if action == "set" then
          if stmt_type ~= "UPDATE" or sqlserver_set then return reject() end
          sqlserver_set = true
        elseif action == "select" then
          local operator = previous.upper
          if operator == "ALL" and tokens[idx - 2] then operator = tokens[idx - 2].upper end
          if not inserting or (sqlserver_select and operator ~= "UNION"
              and operator ~= "INTERSECT" and operator ~= "EXCEPT") then return reject() end
          sqlserver_select = true
        elseif action == "case" then
          case_depth = case_depth + 1
        elseif action == "end" then
          if case_depth > 0 then
            case_depth = case_depth - 1
          elseif following and following.upper == "CONVERSATION" then
            return reject()
          end
        end
      end
    end
    if token.kind == "(" or token.kind == "[" or token.kind == "{" then
      stack[#stack + 1] = idx
    elseif closes[token.kind] then
      local opener = stack[#stack]
      if not opener or tokens[opener].kind ~= closes[token.kind] then return reject() end
      matching[opener] = idx
      stack[#stack] = nil
    elseif token.kind == ";" then
      if #stack > 0 or idx ~= #tokens then return reject() end
      last = idx - 1
    end
  end
  if #stack > 0 then return reject() end

  local pos, delete_target = 2, nil
  local current_state = stmt_type == "REPLACE"
  if inserting then
    if (adapter_kind == "sqlite" or adapter_kind == "duckdb")
        and tokens[pos] and tokens[pos].upper == "OR" then
      local action = tokens[pos + 1] and tokens[pos + 1].upper
      local valid = action == "IGNORE" or action == "REPLACE"
        or (adapter_kind == "sqlite" and ({ ROLLBACK = true, ABORT = true, FAIL = true })[action])
      if not valid then return reject() end
      current_state, pos = true, pos + 2
    elseif adapter_kind == "mysql" then
      while tokens[pos] and ({ LOW_PRIORITY = true, HIGH_PRIORITY = true,
          DELAYED = true, IGNORE = true })[tokens[pos].upper] do
        if tokens[pos].upper == "IGNORE" or tokens[pos].upper == "DELAYED" then current_state = true end
        pos = pos + 1
      end
    end
    if tokens[pos] and tokens[pos].upper == "INTO" then
      pos = pos + 1
    elseif adapter_kind ~= "mysql" and adapter_kind ~= "sqlserver" then return reject() end
  elseif stmt_type == "DELETE" then
    -- SQL Server also permits DELETE table WHERE ..., without the first FROM.
    local optional_from = adapter_kind == "sqlserver" and tokens[pos]
      and tokens[pos].upper ~= "FROM" and not (tokens[pos + 1] and tokens[pos + 1].upper == "FROM")
    if not optional_from then
      if tokens[pos] and tokens[pos].upper ~= "FROM" then
        if tokens[pos].kind ~= "ident" then return reject() end
        delete_target = tokens[pos]
        pos = pos + 1
      end
      if not tokens[pos] or tokens[pos].upper ~= "FROM" then return reject() end
      pos = pos + 1
    end
  end

  local target
  target, pos = path(pos)
  if not target then return reject() end
  -- These dialect modifiers are not target names. Reject them until their
  -- inheritance/conflict semantics can be represented by the preview.
  if (adapter_kind == "postgresql" and target[1].upper == "ONLY")
      or (adapter_kind == "mysql" and (target[1].upper == "LOW_PRIORITY"
        or target[1].upper == "IGNORE")) then return reject() end
  local names = {}
  for idx, token in ipairs(target) do
    -- Catalog APIs use a dotted table name; a literal dot inside one quoted
    -- component cannot be represented there without confusing table and schema.
    if token.text:find(".", 1, true) then return reject() end
    names[idx] = name(token)
  end
  local table_name = table.concat(names, ".")
  local source_sql = sql.quote_ident(table_name)

  local alias
  if tokens[pos] and tokens[pos].upper == "AS" then
    pos = pos + 1
    if not tokens[pos] or tokens[pos].kind ~= "ident" then return reject() end
    alias = tokens[pos]
  elseif not inserting and tokens[pos] and tokens[pos].kind == "ident" and not clauses[tokens[pos].upper] then
    alias = tokens[pos]
  end
  if alias then
    if not inserting then source_sql = source_sql .. " AS " .. raw(pos) end
    pos = pos + 1
  end
  if delete_target and not same(delete_target, alias or target[#target]) then return reject() end

  -- Only literals have a known new value without executing the mutation.
  -- Expressions and subqueries remain unstaged rather than displaying SQL as data.
  local function literal(first, finish)
    if first > finish then return false end
    local token, value = tokens[first], raw(first, finish)
    if first == finish then
      if token.upper == "NULL" then return true, nil end
      if token.kind == "literal" and value:sub(1, 1) == "'" then
        if token.escape_string or ((adapter_kind == "mysql" or adapter_kind == "postgresql")
            and value:find("\\", 1, true)) then return false end
        return true, token.text
      end
      if token.kind == "literal" and value:match("^%$") then
        local delimiter = value:match("^(%$[%w_]*%$)")
        if delimiter then return true, value:sub(#delimiter + 1, -#delimiter - 1) end
      end
    end
    if value:match("^[+-]?%d+%.?%d*$") or value:match("^[+-]?%.%d+$")
        or value:match("^[+-]?%d+%.?%d*[eE][+-]?%d+$") then return true, value end
    return false
  end


  if inserting then
    local result = {
      table_name = table_name, source_sql = source_sql,
      insert_values = {}, current_state = current_state,
    }

    -- Parse identifier lists only at their grammatical position. Parentheses
    -- inside quoted aliases and strings cannot become a column or VALUES list.
    local function identifiers(first)
      local close = matching[first]
      if not close then return nil end
      local fields, next_pos, seen = {}, first + 1, {}
      while next_pos < close do
        local token = tokens[next_pos]
        if token.kind ~= "ident" then return nil end
        local field = name(token)
        if seen[field] then return nil end
        fields[#fields + 1], seen[field] = field, true
        next_pos = next_pos + 1
        if next_pos < close then
          if tokens[next_pos].kind ~= "," then return nil end
          next_pos = next_pos + 1
          if next_pos == close then return nil end
        end
      end
      if #fields == 0 then return nil end
      return fields, close + 1
    end

    if adapter_kind == "mysql" and tokens[pos] and tokens[pos].upper == "PARTITION" then
      local parts, next_pos = identifiers(pos + 1)
      if not parts then return reject() end
      pos, result.current_state = next_pos, true
    end
    if adapter_kind == "duckdb" and tokens[pos] and tokens[pos].upper == "BY" then
      local order = tokens[pos + 1] and tokens[pos + 1].upper
      if order ~= "NAME" and order ~= "POSITION" then return reject() end
      pos, result.current_state = pos + 2, true
    end

    -- Parenthesized source queries occupy the same slot as an optional column
    -- list. Quoted keyword-shaped columns have no upper field and stay columns.
    local function source_query(first)
      if adapter_kind ~= "postgresql" and adapter_kind ~= "mysql"
          and adapter_kind ~= "duckdb" then return false end
      if not tokens[first] or tokens[first].kind ~= "(" then return false end
      while tokens[first] and tokens[first].kind == "(" do first = first + 1 end
      local keyword = tokens[first] and tokens[first].upper
      return keyword == "SELECT" or keyword == "WITH"
        or keyword == "VALUES" or keyword == "TABLE"
        or (adapter_kind == "duckdb" and keyword == "FROM")
    end
    if source_query(pos) then result.current_state = true; return result end
    if tokens[pos] and tokens[pos].kind == "(" then
      if adapter_kind == "mysql" and matching[pos] == pos + 1 then
        -- MySQL () VALUES () requests defaults, not an all-NULL predicted row.
        result.insert_columns, result.current_state, pos = {}, true, pos + 2
      else
        result.insert_columns, pos = identifiers(pos)
        if not result.insert_columns then return reject() end
      end
    end
    if source_query(pos) then result.current_state = true; return result end

    if adapter_kind == "sqlserver" and tokens[pos] and tokens[pos].upper == "OUTPUT" then
      -- OUTPUT (including INTO and its destination columns) precedes the source
      -- in T-SQL. Its expressions are not INSERT values or a target column list.
      local output_start = pos
      pos = pos + 1
      while pos <= last do
        local token, previous = tokens[pos], tokens[pos - 1]
        if depth[pos] == 0 and previous.kind ~= "." and
            (token.upper == "VALUES" or token.upper == "SELECT"
              or (token.upper == "DEFAULT" and tokens[pos + 1] and tokens[pos + 1].upper == "VALUES")) then
          break
        end
        pos = pos + 1
      end
      if pos > last or pos == output_start + 1 then return reject() end
    end

    local body = tokens[pos] and tokens[pos].upper
    if body == "SELECT" or body == "WITH" or body == "TABLE" or body == "OVERRIDING"
        or (adapter_kind == "duckdb" and body == "FROM") then
      -- Source queries and identity overrides cannot be predicted without
      -- executing SQL. The preview shows the current target table only.
      result.current_state = true
      return result
    elseif body == "DEFAULT" and tokens[pos + 1] and tokens[pos + 1].upper == "VALUES" then
      result.current_state, pos = true, pos + 2
    elseif body == "VALUES" or (body == "VALUE" and adapter_kind == "mysql") then
      pos = pos + 1
      repeat
        if adapter_kind == "mysql" and tokens[pos] and tokens[pos].upper == "ROW" then pos = pos + 1 end
        if not tokens[pos] or tokens[pos].kind ~= "(" then return reject() end
        local close, first, count, values = matching[pos], pos + 1, 0, {}
        if not close then return reject() end
        for idx = first, close do
          if idx == close or (depth[idx] == depth[pos] + 1 and tokens[idx].kind == ",") then
            if first == idx then
              -- MySQL's VALUES () uses defaults; never display them as NULL.
              if idx ~= close or count ~= 0 then return reject() end
              result.current_state = true
            else
              count = count + 1
              local known, value = literal(first, idx - 1)
              if not known then result.current_state = true end
              values[count] = value
            end
            first = idx + 1
          end
        end
        if result.insert_columns and count ~= #result.insert_columns then return reject() end
        values.n = count -- Preserve positional NULLs; Lua's length drops holes.
        result.insert_values[#result.insert_values + 1] = values
        pos = close + 1
        if not tokens[pos] or tokens[pos].kind ~= "," then break end
        pos = pos + 1
      until false
    elseif body == "SET" and adapter_kind == "mysql" then
      if result.insert_columns then return reject() end
      local fields, values, seen, first, finish = {}, {}, {}, pos + 1, last
      for idx = first, last do
        local token = tokens[idx]
        if depth[idx] == 0 and (token.upper == "AS" or token.upper == "ON"
            or token.upper == "RETURNING") and tokens[idx - 1].kind ~= "="
            and tokens[idx - 1].kind ~= "," and tokens[idx - 1].kind ~= "." then
          finish = idx - 1
          break
        end
      end
      for idx = first, finish + 1 do
        if idx == finish + 1 or (depth[idx] == 0 and tokens[idx].kind == ",") then
          local field = tokens[first]
          if not field or field.kind ~= "ident" or not tokens[first + 1]
              or tokens[first + 1].kind ~= "=" or first + 2 >= idx then return reject() end
          local column = name(field)
          if seen[column] then result.current_state = true end
          seen[column], fields[#fields + 1] = true, column
          local known, value = literal(first + 2, idx - 1)
          if not known then result.current_state = true end
          values[#fields] = value
          first = idx + 1
        end
      end
      values.n = #fields
      result.insert_columns, result.insert_values, pos = fields, { values }, finish + 1
    else
      return reject()
    end

    -- MySQL row/column aliases describe the VALUES output, not additional rows.
    if adapter_kind == "mysql" and tokens[pos] and tokens[pos].upper == "AS" then
      if not tokens[pos + 1] or tokens[pos + 1].kind ~= "ident" then return reject() end
      pos = pos + 2
      if tokens[pos] and tokens[pos].kind == "(" then
        local fields, next_pos = identifiers(pos)
        if not fields then return reject() end
        pos = next_pos
      end
    end
    if pos <= last then
      if tokens[pos].upper == "ON"
          and ((tokens[pos + 1] and tokens[pos + 1].upper == "CONFLICT")
            or (tokens[pos + 1] and tokens[pos + 1].upper == "DUPLICATE"
              and tokens[pos + 2] and tokens[pos + 2].upper == "KEY"
              and tokens[pos + 3] and tokens[pos + 3].upper == "UPDATE")) then
        result.current_state = true
      elseif (body == "VALUES" or body == "VALUE")
          and ({ UNION = true, INTERSECT = true, EXCEPT = true, ORDER = true,
            LIMIT = true, OFFSET = true, FETCH = true })[tokens[pos].upper] then
        -- VALUES may start a larger query. Its first tuples do not predict the
        -- result of set operations, ordering, or limits applied to that query.
        result.current_state = true
      elseif tokens[pos].upper ~= "RETURNING" then
        return reject()
      end
    end
    if result.current_state then result.insert_values = {} end
    return result
  end

  local set_start
  if stmt_type == "UPDATE" then
    if not tokens[pos] or tokens[pos].upper ~= "SET" then return reject() end
    set_start, pos = pos + 1, pos + 1
  elseif pos <= last and tokens[pos].upper ~= "WHERE"
      and tokens[pos].upper ~= "ORDER" and tokens[pos].upper ~= "LIMIT"
      and tokens[pos].upper ~= "RETURNING"
      and ((tokens[pos].upper ~= "OPTION" and tokens[pos].upper ~= "OUTPUT")
        or adapter_kind ~= "sqlserver") then
    return reject()
  end

  local where_idx, tail_idx, output_idx
  for idx = pos, last do
    local token = tokens[idx]
    local previous, following = tokens[idx - 1], tokens[idx + 1]
    if depth[idx] == 0 and (not previous or previous.kind ~= ".")
        and (not following or following.kind ~= ".") then
      local keyword = token.upper
      -- UPDATE FROM adds another source, but DISTINCT FROM is an expression
      -- operator. Once WHERE starts, source clauses can only be nested queries.
      if not where_idx and keyword == "FROM" and tokens[idx - 1].upper ~= "DISTINCT" then return reject() end
      if keyword == "OUTPUT" and adapter_kind == "sqlserver" and not output_idx then
        local operand = (following and following.kind == "=")
          or (previous and (expression_prefix[previous.upper] or previous.upper == "SET"
            or previous.upper == "AS" or previous.kind:match("^[=+*/%%<>!~|&^,:@-]$")))
        if not operand then
          if where_idx or not following or following.upper == "WHERE" or following.upper == "OPTION" then
            return reject()
          end
          output_idx = idx
        end
      elseif keyword == "WHERE" then
        if where_idx then return reject() end
        where_idx = idx
      elseif ((not output_idx or where_idx) and (keyword == "RETURNING" or keyword == "LIMIT"
          or (keyword == "ORDER" and following and following.upper == "BY")))
          or (keyword == "OPTION" and adapter_kind == "sqlserver") then
        -- Some dialects allow these words as unquoted columns. An assignment
        -- or expression operand cannot start a trailing statement clause.
        local operand = (following and following.kind == "=")
          or (previous and (expression_prefix[previous.upper] or previous.upper == "AS"
            or previous.kind:match("^[=+*/%%<>!~|&^,:@-]$")))
        if not operand then
          -- A real trailing clause cannot precede the statement's WHERE.
          -- Refuse an ambiguous keyword instead of silently dropping a filter.
          if not where_idx then
            for later = idx + 1, last do
              if depth[later] == 0 and tokens[later].upper == "WHERE"
                  and tokens[later - 1].kind ~= "."
                  and (not tokens[later + 1] or tokens[later + 1].kind ~= ".") then return reject() end
            end
          end
          tail_idx = idx
          break
        end
      end
    end
  end

  local result = { table_name = table_name, source_sql = source_sql, assignments = {} }
  if where_idx then
    local end_token = tail_idx and tail_idx - 1 or last
    if where_idx + 1 > end_token then return reject() end
    -- Exclude trailing comments so a removed clause cannot leave a line comment
    -- swallowing SQL appended by an adapter; internal newlines stay intact.
    local finish = tokens[end_token].finish
    result.where = vim.trim(text:sub(tokens[where_idx].finish + 1, finish))
  end

  local assignment_slots = {}
  local function assignment(first, finish)
    local fields, next_pos = path(first)
    if not fields or next_pos > finish or tokens[next_pos].kind ~= "=" then
      -- Tuple/subscript targets may overwrite a scalar already encountered.
      -- Their full target set is not represented here, so discard earlier
      -- predictions; subsequent simple literal assignments can still be staged.
      result.assignments, assignment_slots = {}, {}
      return
    end
    if #fields > 1 and (adapter_kind == "postgresql" or adapter_kind == "sqlserver") then
      -- Dotted SET targets address PostgreSQL composite fields or SQL Server
      -- UDT properties. Do not mistake them for alias-qualified scalar columns.
      local column = name(fields[1])
      if adapter_kind == "sqlserver" then
        result.assignments[#result.assignments + 1] = { column = column, known = false }
      else
        local slot = assignment_slots[column]
        if slot then result.assignments[slot] = { column = column, known = false } end
      end
      return
    end
    if #fields > 1 then
      local qualifiers = alias and { alias } or target
      local matches = #fields - 1 == #qualifiers
      if matches then
        for idx = 1, #qualifiers do
          if not same(fields[idx], qualifiers[idx]) then matches = false; break end
        end
      end
      if not matches and not alias and #fields == 2 then matches = same(fields[1], target[#target]) end
      if not matches then return end
    end
    local column = name(fields[#fields])
    local key = adapter_kind == "postgresql" and column or column:lower()
    -- SQL Server column case depends on the catalog collation. Preserve the
    -- original order until preview metadata resolves each actual column.
    local slot = adapter_kind == "sqlserver" and (#result.assignments + 1)
      or assignment_slots[key] or (#result.assignments + 1)
    assignment_slots[key] = slot
    local known, value = literal(next_pos + 1, finish)
    -- A later assignment wins, including one whose value cannot be predicted.
    result.assignments[slot] = { column = column, value = value, known = known }
  end
  if set_start then
    local finish = (output_idx or where_idx or tail_idx or (last + 1)) - 1
    if finish < set_start then return reject() end
    local first = set_start
    for idx = first, finish do
      if depth[idx] == 0 and tokens[idx].kind == "," then
        assignment(first, idx - 1)
        first = idx + 1
      end
    end
    assignment(first, finish)
    local literals = {}
    for _, entry in ipairs(result.assignments) do
      if entry.known then
        entry.known = nil
        literals[#literals + 1] = entry
      elseif adapter_kind == "sqlserver" then
        -- A later expression can invalidate an earlier differently-cased
        -- literal on a case-insensitive SQL Server database.
        literals[#literals + 1] = entry
      end
    end
    result.assignments = literals
  end
  return result
end

return M
