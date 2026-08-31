-- importer.lua: parse clipboard/pipe rows into staged-insert value maps.

local data = require("dadbod-grip.data")
local db = require("dadbod-grip.db")

local M = {}

local function is_list(value)
  if vim.islist then return vim.islist(value) end
  return vim.tbl_islist(value)
end

local function target_index(columns)
  local index = {}
  for _, column in ipairs(columns) do index[column] = true end
  return index
end

local function normalize_json(value)
  if value == vim.NIL then return data.NULL_SENTINEL end
  if type(value) == "table" then return vim.json.encode(value) end
  return tostring(value)
end

local function parse_json(raw, columns, first)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then return nil, "invalid JSON" end

  local rows
  if first == "[" then
    if type(decoded) ~= "table" or not is_list(decoded) then
      return nil, "JSON input must be an array of objects"
    end
    rows = decoded
  else
    if type(decoded) ~= "table" then return nil, "JSON input must be an object" end
    rows = { decoded }
  end
  if #rows == 0 then return nil, "no rows to import" end

  local allowed = target_index(columns)
  local present, unknown, values = {}, {}, {}
  for row_number, row in ipairs(rows) do
    if type(row) ~= "table" or is_list(row) then
      return nil, "JSON row " .. row_number .. " must be an object"
    end
    local mapped = {}
    for column, value in pairs(row) do
      if not allowed[column] then
        unknown[column] = true
      else
        present[column] = true
        mapped[column] = normalize_json(value)
      end
    end
    values[#values + 1] = mapped
  end

  local unknown_list = {}
  for column in pairs(unknown) do unknown_list[#unknown_list + 1] = tostring(column) end
  table.sort(unknown_list)
  if #unknown_list > 0 then
    return nil, "unknown column(s): " .. table.concat(unknown_list, ", ")
  end

  local mapped_columns = {}
  for _, column in ipairs(columns) do
    if present[column] then mapped_columns[#mapped_columns + 1] = column end
  end
  if #mapped_columns == 0 then return nil, "no table columns found in JSON input" end

  return { format = "JSON", columns = mapped_columns, rows = values }
end

local function parse_delimited(raw, columns)
  local header = raw:match("^[^\r\n]*") or ""
  local delimiter = header:find("\t", 1, true) and "\t" or ","
  local parsed, err = db.parse_csv(raw, delimiter, true)
  if not parsed then return nil, err end
  if #parsed.columns == 0 or #parsed.rows == 0 then return nil, "no rows to import" end

  local allowed = target_index(columns)
  local seen = {}
  for _, column in ipairs(parsed.columns) do
    if column == "" then return nil, "empty column name" end
    if seen[column] then return nil, "duplicate column: " .. column end
    if not allowed[column] then return nil, "unknown column: " .. column end
    seen[column] = true
  end

  local values = {}
  for _, row in ipairs(parsed.rows) do
    local mapped = {}
    for index, column in ipairs(parsed.columns) do
      mapped[column] = data.from_csv_raw(row[index])
    end
    values[#values + 1] = mapped
  end

  return {
    format = delimiter == "\t" and "TSV" or "CSV",
    columns = parsed.columns,
    rows = values,
  }
end

--- Parse CSV, TSV, or JSON rows and map them to the target table columns.
function M.parse(raw, columns)
  if type(raw) ~= "string" or vim.trim(raw) == "" then return nil, "no rows to import" end
  raw = raw:gsub("^\239\187\191", "")
  local first = raw:match("^%s*(.)")
  if first == "[" or first == "{" then return parse_json(raw, columns, first) end
  return parse_delimited(raw, columns)
end

return M
