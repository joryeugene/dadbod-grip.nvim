-- ui.lua: shared UI primitives for dadbod-grip.
-- Kept small: only patterns that are reused across modules.

local M = {}

--- Show an animated spinner float, run fn(), then clear the float.
---
--- IMPORTANT: fn() must be synchronous OR use vim.wait() for async work.
--- If fn() returns before work is done, the float closes prematurely.
--- For async callers (e.g. curl/jobstart), use this pattern inside fn():
---
---   local done = false
---   start_async(function(result) ... done = true end)
---   vim.wait(30000, function() return done end, 50)
---
--- The spinner (braille frames) animates during vim.system():wait() and
--- vim.wait() calls inside fn() because both pump the libuv event loop.
--- eventignore="all" suppresses plugin autocmds (WinNew/BufNew) that add
--- 200-400ms overhead from noice/treesitter/nvim-cmp handlers.
---
--- @param msg string
--- @param fn  function  must be synchronous or use vim.wait() internally
--- @return    any       all return values from fn() forwarded
function M.blocking(msg, fn)
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local fi = 1

  local display = "  " .. msg
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. display, "" })
  local w = math.min(vim.fn.strdisplaywidth(display) + 6, vim.o.columns - 4)

  -- Suppress plugin autocmds during float create to avoid 200-400ms overhead.
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = "rounded",
    width    = w, height = 3,
    row      = math.floor((vim.o.lines   - 3) / 2),
    col      = math.floor((vim.o.columns - w) / 2),
  })
  vim.o.eventignore = ei

  -- Flush to terminal NOW, before fn() runs.
  vim.api.nvim__redraw({ flush = true })

  -- Animate: timer fires during vim.system():wait() and vim.wait() event loop pumps.
  -- libuv timer callbacks are "fast events" - nvim API calls are forbidden there.
  -- vim.schedule_wrap defers the API work into the main loop, which pumps during wait().
  local timer = vim.uv.new_timer()
  timer:start(80, 80, vim.schedule_wrap(function()
    fi = (fi % #frames) + 1
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false,
        { "", "  " .. frames[fi] .. " " .. msg, "" })
      vim.api.nvim__redraw({ flush = true })
    end
  end))

  -- table.pack/table.unpack are Lua 5.2+; LuaJIT is 5.1.
  -- { pcall(fn) } => { ok, r1, r2, ... } or { false, errmsg }
  local rets = { pcall(fn) }
  local ok   = table.remove(rets, 1)

  timer:stop()
  timer:close()

  -- Close float, suppressing autocmds again.
  ei = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  vim.o.eventignore = ei

  -- Flush the close to terminal so the float disappears before the next render.
  vim.api.nvim__redraw({ flush = true })

  if not ok then error(rets[1], 2) end
  return (table.unpack or unpack)(rets)
end

return M
