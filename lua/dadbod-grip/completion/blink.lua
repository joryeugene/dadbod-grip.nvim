-- blink.lua: native blink.cmp source provider for dadbod-grip SQL completion.
-- Wraps completion.complete() in blink's provider interface so users get
-- identical SQL intelligence (tables, columns, keywords) through blink's UI.
--
-- Usage in blink.cmp config:
--   sources.providers = {
--     dadbod_grip = { name = "Grip SQL", module = "dadbod-grip.completion.blink" }
--   }

local completion = require("dadbod-grip.completion")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  local url = vim.b.db or vim.g.db
  return type(url) == "string" and url ~= ""
end

function source:get_trigger_characters()
  return { "." }
end

-- LSP CompletionItemKind values (no dependency on cmp.types)
local KIND_FIELD   = 5
local KIND_MODULE  = 6
local KIND_KEYWORD = 14

function source:get_completions(ctx, callback)
  local url = vim.b.db or vim.g.db
  if not url or url == "" then
    callback({ items = {}, is_incomplete_backward = false })
    return
  end

  local before  = ctx.line:sub(1, ctx.cursor[2])
  local bufnr   = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local lines   = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local aliases = completion.extract_aliases(table.concat(lines, "\n"))

  local raw = completion.complete(before, url, aliases)
  if #raw == 0 then
    callback({ items = {}, is_incomplete_backward = true })
    return
  end

  local items = {}
  for _, it in ipairs(raw) do
    local kind = KIND_FIELD
    if it.menu == "[table]" then
      kind = KIND_MODULE
    elseif it.menu == "[keyword]" then
      kind = KIND_KEYWORD
    end
    items[#items + 1] = {
      label      = it.word,
      detail     = it.menu,
      kind       = kind,
      insertText = it.word,
    }
  end

  callback({ items = items, is_incomplete_backward = true })
end

return source
