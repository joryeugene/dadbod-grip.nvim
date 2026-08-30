-- File formats DuckDB can query directly. Keep startup routing, connection
-- discovery, and schema inspection on this single registry.

local M = {}

M.extensions = {
  ".parquet", ".csv", ".tsv", ".json", ".ndjson",
  ".jsonl", ".xlsx", ".orc", ".arrow", ".ipc",
}

--- Return whether a path or URL ends in a supported data-file extension.
--- Query strings and fragments are ignored and matching is case-insensitive.
function M.has_supported_extension(value)
  if type(value) ~= "string" or value == "" then return false end
  local path = value:lower():gsub("[?#].*$", "")
  for _, ext in ipairs(M.extensions) do
    if path:sub(-#ext) == ext then return true end
  end
  return false
end

return M
