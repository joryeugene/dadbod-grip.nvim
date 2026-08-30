-- File formats DuckDB can query directly. Keep startup routing, connection
-- discovery, and schema inspection on this single registry.

local M = {}

M.extensions = {
  ".parquet", ".csv", ".tsv", ".json", ".ndjson",
  ".jsonl", ".xlsx", ".orc", ".arrow", ".ipc",
}

local WRITE_FORMATS = {
  [".parquet"] = "PARQUET",
  [".csv"] = "CSV",
  [".tsv"] = "CSV",
  [".json"] = "JSON",
  [".ndjson"] = "JSON",
  [".jsonl"] = "JSON",
  [".arrow"] = "ARROW",
  [".ipc"] = "ARROW",
}

local function matching_extension(value)
  if type(value) ~= "string" or value == "" then return nil end
  local path = value:lower():gsub("[?#].*$", "")
  for _, ext in ipairs(M.extensions) do
    if path:sub(-#ext) == ext then return ext end
  end
  return nil
end

--- Return whether a path or URL ends in a supported data-file extension.
--- Query strings and fragments are ignored and matching is case-insensitive.
function M.has_supported_extension(value)
  return matching_extension(value) ~= nil
end

--- Return the DuckDB COPY format for local files Grip can safely overwrite.
--- Read-only formats and remote URLs deliberately return nil.
function M.write_format(value)
  if type(value) ~= "string" or value:match("^https?://") or value:match("^s3://") then
    return nil
  end
  return WRITE_FORMATS[matching_extension(value)]
end

return M
