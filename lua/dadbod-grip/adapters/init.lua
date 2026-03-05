-- adapters/init.lua: adapter registry.
-- Detects DB type from URL scheme, returns the correct adapter module.

local M = {}

local SCHEME_MAP = {
  ["postgresql://"] = "dadbod-grip.adapters.postgresql",
  ["postgres://"]   = "dadbod-grip.adapters.postgresql",
  ["sqlite:"]       = "dadbod-grip.adapters.sqlite",
  ["mysql://"]      = "dadbod-grip.adapters.mysql",
  ["mariadb://"]    = "dadbod-grip.adapters.mysql",
  ["duckdb:"]       = "dadbod-grip.adapters.duckdb",
}

--- Resolve the adapter module for a given connection URL.
--- @param url string
--- @return table|nil adapter module
--- @return string|nil error message
function M.resolve(url)
  if not url or url == "" then
    return nil, "No database URL provided"
  end
  for prefix, mod_name in pairs(SCHEME_MAP) do
    if url:sub(1, #prefix):lower() == prefix:lower() then
      local ok, adapter = pcall(require, mod_name)
      if not ok then
        return nil, "Failed to load adapter " .. mod_name .. ": " .. tostring(adapter)
      end
      return adapter, nil
    end
  end
  local scheme = url:match("^([^:]+:)") or url
  return nil, "Unsupported database scheme: " .. scheme
end

return M
