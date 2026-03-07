-- adapters/init.lua: adapter registry.
-- Detects DB type from URL scheme, returns the correct adapter module.

local M = {}

--- Run a CLI command and wait for it to finish, pumping the full Neovim event
--- loop during the wait. This allows vim.schedule_wrap timer callbacks (such as
--- the ui.blocking spinner) to fire while a CLI process is in progress.
---
--- vim.system():wait() only pumps libuv; vim.schedule_wrap callbacks live in the
--- Neovim main event queue and require vim.wait() to execute.
---
--- @param args  string[]   argv for vim.system
--- @param timeout_ms number|nil  process timeout in ms (default 30000)
--- @return string stdout
--- @return string stderr
--- @return number exit_code
function M.run_cmd(args, timeout_ms)
  local t = timeout_ms or 30000
  local out
  local done = false
  vim.system(args, { text = true, timeout = t }, function(r)
    out = r
    done = true
  end)
  -- Poll at 1ms so done is detected immediately after the on_exit callback fires.
  -- The 80ms spinner timer fires when vim.wait pumps the event loop regardless of
  -- poll interval; tight polling just reduces per-call overhead in tests.
  -- Add 3s buffer beyond the process timeout to absorb on_exit callback latency.
  vim.wait(t + 3000, function() return done end, 1)
  local r = out or { stdout = "", stderr = "command timed out", code = 1 }
  return r.stdout or "", r.stderr or "", r.code
end

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
