-- ui.lua: shared UI primitives for dadbod-grip.
-- Kept small: only patterns that are reused across modules.

local M = {}

-- ── display-width text layout ─────────────────────────────────────────────
-- Shared by view.lua (the grid) and properties.lua/profile.lua/diff.lua (the
-- auxiliary report views), so alignment logic for non-ASCII column/cell
-- values (Cyrillic, CJK, emoji) lives in one place. er_diagram.lua does NOT
-- use this: it already routes every width through vim.fn.strdisplaywidth
-- directly and keeps its own truncate_col (verified correct, Task 11).
--
-- Bytes \32-\126 are exactly space..~ printable ASCII. The range deliberately
-- excludes tab (\9, whose width depends on 'tabstop'), every other control byte
-- and DEL (strdisplaywidth renders those as a 2-cell "^X"), and everything
-- >= 0x80 (UTF-8 lead/continuation bytes). For a string of only such bytes, and
-- only then, one byte is one character is one display cell — so #s is the
-- display width and s:sub(1, n) is a correctly truncated prefix, with no vim.fn
-- round-trip per character. That is the common case for a grid of numbers, ids
-- and short labels, which is why it is worth a branch.
--
--- Truncate `s` to fit `width` display cells. When it doesn't fit and
--- `ellipsize ~= false`, cuts to width - width(marker) cells and appends
--- `marker` (default "…"); properties.lua/diff.lua use "~" to match their
--- established style. `ellipsize == false` just cuts to fit, no marker.
--- @return string truncated, integer display_width
function M.truncate_display(s, width, ellipsize, marker)
  s = tostring(s or "")
  if width <= 0 then return "", 0 end

  local ascii = not s:find("[^\32-\126]")

  local dw = ascii and #s or vim.fn.strdisplaywidth(s)
  if dw <= width then return s, dw end

  local ell = ellipsize ~= false and (marker or "…") or ""
  -- Not hoisted to a constant: 'ambiwidth' can change at runtime.
  local ell_w = vim.fn.strdisplaywidth(ell)
  if ell ~= "" and ell_w == width then
    return ell, ell_w
  end

  local target = math.max(0, width - ell_w)
  local out, used
  if ascii then
    -- dw > width >= target, so the prefix is always exactly `target` bytes.
    out = s:sub(1, target)
    used = #out
  else
    local parts = {}
    used = 0
    for i = 0, vim.fn.strchars(s) - 1 do
      local ch = vim.fn.strcharpart(s, i, 1)
      local cw = vim.fn.strdisplaywidth(ch)
      if used + cw > target then break end
      parts[#parts + 1] = ch
      used = used + cw
    end
    out = table.concat(parts)
  end

  if ell ~= "" and used + ell_w <= width then
    out = out .. ell
    used = used + ell_w
  end
  return out, used
end

--- Truncate (see M.truncate_display) then right-pad with spaces to exactly
--- `width` display cells.
--- @return string padded, integer display_width_before_padding
function M.pad_display(s, width, ellipsize, marker)
  local trimmed, dw = M.truncate_display(s, width, ellipsize, marker)
  return trimmed .. string.rep(" ", math.max(0, width - dw)), dw
end

--- Slice `width` display cells out of `s`, starting `from` cells in.
--- `from` is 0-based and in the same units as winsaveview().leftcol.
--- @return string
function M.slice_display(s, from, width)
  s = tostring(s or "")
  if width <= 0 then return "" end

  local out, used, skipped = {}, 0, 0
  for i = 0, vim.fn.strchars(s) - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if skipped + cw <= from then
      skipped = skipped + cw
    elseif skipped < from then
      -- `from` lands inside a wide glyph: only its trailing cells are visible.
      -- Emitting the glyph itself would pull everything after it one cell left
      -- of the grid row underneath, so pad with what is actually on screen.
      local visible = math.min(skipped + cw - from, width - used)
      out[#out + 1] = string.rep(" ", visible)
      used = used + visible
      skipped = skipped + cw
    else
      if used + cw > width then
        -- Mirror of the `from` case at the right edge: a glyph straddling the
        -- end of the slice contributes only the cells that fit.
        out[#out + 1] = string.rep(" ", width - used)
        break
      end
      out[#out + 1] = ch
      used = used + cw
    end
  end
  return table.concat(out)
end

--- Return the configured float border style.
--- Lazy-requires init to avoid circular dependency.
function M.border()
  return require("dadbod-grip").get_opts().border
end

--- Open a read-only report in a bottom split and return its buffer and window.
---
--- The shape shared by GripDiff and GripProfile: a named scratch buffer, a
--- botright split sized to the content (capped at 30 lines), cursorline on and
--- wrap off. Callers add their own highlights and keymaps afterwards.
---
--- @param lines string[]  report body
--- @param name  string    buffer name, e.g. "grip://profile/users"
--- @return integer bufnr, integer winid
function M.report_split(lines, name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_buf_set_name, bufnr, name)

  vim.cmd("botright split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_height(winid, math.min(30, #lines + 2))
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  return bufnr, winid
end

--- Prompt on the cmdline; return nil when the user cancels.
---
--- vim.fn.input() signals a cancel two ways: <Esc> returns `cancelreturn`, while
--- <C-c> raises. Both mean nil here. An empty answer counts as a cancel too
--- unless `allow_empty` is set — which is what almost every prompt here wants.
---
--- vim.fn.input() and not vim.ui.input() on purpose: it always uses the native
--- cmdline, so it is never intercepted by dressing.nvim/noice floats.
---
--- @param opts table   prompt, default?, completion?, allow_empty?
--- @return string|nil  the answer, or nil if cancelled
function M.input(opts)
  local CANCEL = "\0"
  local ok, answer = pcall(vim.fn.input, {
    prompt       = opts.prompt,
    default      = opts.default,
    completion   = opts.completion,
    cancelreturn = CANCEL,
  })
  if not ok or answer == CANCEL then return nil end
  if answer == "" and not opts.allow_empty then return nil end
  return answer
end

--- Ask a yes/no question. Only a literal "y"/"yes" is a yes; anything else —
--- including an empty answer or a cancel — is a no.
--- @param prompt string  spell out the default, e.g. "Drop table? (y/N): "
--- @return boolean
function M.confirm(prompt)
  local answer = M.input({ prompt = prompt, allow_empty = true })
  return answer == "y" or answer == "yes"
end

--- Open an editor-relative float and return its window and buffer.
---
--- Covers only what the info floats across the plugin share: a scratch buffer,
--- centered geometry, style = "minimal" and the configured border. Sizing rules
--- stay with the caller — every float has its own idea of how wide it should be.
--- Keys left nil are not passed to nvim_open_win at all, so a caller that never
--- set `title`/`zindex` keeps the stock window it had before.
---
--- @param opts table
---   lines      string[]|nil  fill a fresh scratch buffer with these
---   buf        integer|nil   use this buffer instead of creating one (pass it
---                            when buffer options must be set before the window
---                            exists, e.g. filetype)
---   width      integer       required
---   height     integer       required
---   relative   string|nil    default "editor"
---   row, col   integer|nil   default: centered for width/height
---   enter      boolean|nil   focus the float (default true)
---   style, border, title, title_pos, zindex, footer, footer_pos
---                            forwarded as-is; style/border default to
---                            "minimal" / M.border()
--- @return integer win, integer buf
function M.info_float(opts)
  local buf = opts.buf
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    if opts.lines then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
    end
  end

  local cfg = {
    relative  = opts.relative or "editor",
    width     = opts.width,
    height    = opts.height,
    row       = opts.row or math.floor((vim.o.lines   - opts.height) / 2),
    col       = opts.col or math.floor((vim.o.columns - opts.width) / 2),
    style     = opts.style or "minimal",
    border    = opts.border or M.border(),
    title     = opts.title,
    title_pos = opts.title_pos,
    zindex    = opts.zindex,
  }

  local enter = opts.enter ~= false

  -- A footer needs a border; fall back silently when nvim rejects the config
  -- (border = "none").
  if opts.footer then
    local with_footer = vim.tbl_extend("force", cfg,
      { footer = opts.footer, footer_pos = opts.footer_pos })
    local ok, win = pcall(vim.api.nvim_open_win, buf, enter, with_footer)
    if ok then return win, buf end
  end

  return vim.api.nvim_open_win(buf, enter, cfg), buf
end

--- Wire the standard dismissal for a focused info float: `q` and `<Esc>` close
--- it and hand focus back to the window it was opened from, and leaving the
--- float's window closes it as well.
---
--- The augroup is a parameter, not a constant: each module registers the
--- WinLeave in its own group so that its own reload/clear keeps owning it.
---
--- close() owns the whole float: it drops the autocmd, closes the window and
--- deletes the buffer. The buffer has to go with the window — info_float's
--- scratch buffer is unlisted with bufhidden=hide, so closing only the window
--- leaves it hidden (and invisible to :ls) for the rest of the session, one
--- more every time a float is opened. Deleting it is also what retires the
--- buffer-local WinLeave when the float was opened with `enter = false`: a
--- window that was never entered is never left, so the autocmd would otherwise
--- outlive the float it was watching.
---
--- @param opts table
---   win        integer  the float window
---   buf        integer  the float buffer (keymaps and WinLeave are buffer-local)
---   caller_win integer  window to focus after q/<Esc>
---   group      integer  augroup id for the WinLeave autocmd
--- @return function close  closes the float without moving focus
function M.dismiss_float(opts)
  local win, buf, caller_win = opts.win, opts.buf, opts.caller_win

  local au_id

  -- Every step is guarded and nothing is allowed to raise: close() runs twice
  -- whenever it is called by hand from a window it is also watching (the manual
  -- call plus the WinLeave it triggers), the window may already be gone because
  -- the user typed :q, and the second half of it runs inside an autocmd.
  local function close()
    -- Dropping the autocmd up front, before the window goes, is what keeps
    -- close() from being re-entered through the WinLeave that closing a focused
    -- float fires: no redundant close gets scheduled to land after the caller
    -- has moved on (properties.lua's gI closes and reopens in one breath).
    -- `once = true` already dropped the id if the WinLeave did fire, hence pcall.
    if au_id then
      pcall(vim.api.nvim_del_autocmd, au_id)
      au_id = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  au_id = vim.api.nvim_create_autocmd("WinLeave", {
    group  = opts.group,
    buffer = buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
      if vim.api.nvim_win_is_valid(caller_win) then
        vim.api.nvim_set_current_win(caller_win)
      end
    end, { buffer = buf })
  end

  return close
end

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
    relative = "editor", style = "minimal", border = M.border(),
    width    = w, height = 3,
    row      = math.floor((vim.o.lines   - 3) / 2),
    col      = math.floor((vim.o.columns - w) / 2),
  })
  vim.o.eventignore = ei

  -- Flush to terminal NOW, before fn() runs. nvim__redraw is private API on
  -- purpose: there is no public equivalent that flushes from inside a blocking
  -- call (:redraw is a no-op while we hold the loop).
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
  -- table.unpack is nil on the LuaJIT Neovim embeds; probed so this keeps working
  -- if Neovim ever moves to a 5.2+ VM, where the bare `unpack` global is gone.
  -- luacheck: ignore 143
  return (table.unpack or unpack)(rets)
end

return M
