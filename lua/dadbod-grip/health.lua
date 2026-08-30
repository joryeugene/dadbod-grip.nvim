-- health.lua: :checkhealth dadbod-grip
-- Auto-discovered by Neovim. Checks Neovim version, adapter CLIs,
-- and optional AI provider configuration.

local M = {}

function M.check()
  vim.health.start("dadbod-grip")

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required (current version is too old)")
  end

  -- Adapter CLIs (warn = feature degraded, not broken)
  for _, cli in ipairs({ "psql", "sqlite3", "mysql", "duckdb", "sqlcmd" }) do
    if vim.fn.executable(cli) == 1 then
      vim.health.ok(cli .. " found")
    else
      vim.health.warn(cli .. " not found (required for that adapter)")
    end
  end

  -- AI provider keys (optional)
  local ai_providers = {
    { env = "ANTHROPIC_API_KEY", label = "Anthropic" },
    { env = "OPENAI_API_KEY",    label = "OpenAI" },
    { env = "GEMINI_API_KEY",    label = "Gemini" },
  }
  local found_ai = false
  for _, p in ipairs(ai_providers) do
    if os.getenv(p.env) then
      vim.health.ok(p.label .. " API key set (" .. p.env .. ")")
      found_ai = true
    end
  end
  -- Ollama (local AI, fully optional)
  if vim.fn.executable("ollama") == 1 then
    vim.health.ok("ollama found (local AI available)")
    found_ai = true
  end
  if not found_ai then
    vim.health.warn("No AI provider found (set an API key or install Ollama for GripAsk)")
  end
end

return M
