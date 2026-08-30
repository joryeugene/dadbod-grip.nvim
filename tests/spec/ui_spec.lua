-- ui_spec.lua: unit tests for ui.blocking() and ui.info_float()
dofile("tests/minimal_init.lua")
local ui = require("dadbod-grip.ui")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function win_count()
  return #vim.api.nvim_list_wins()
end

test("blocking: returns single value", function()
  local result = ui.blocking("test", function() return 42 end)
  eq(result, 42, "return value")
end)

test("blocking: returns multiple values", function()
  local a, b, c = ui.blocking("test", function() return 1, 2, 3 end)
  eq(a, 1, "first"); eq(b, 2, "second"); eq(c, 3, "third")
end)

test("blocking: no extra windows after success", function()
  local before = win_count()
  ui.blocking("test", function() return "ok" end)
  local after = win_count()
  eq(after, before, "window count unchanged after success")
end)

test("blocking: no extra windows after error", function()
  local before = win_count()
  pcall(ui.blocking, "test", function() error("intentional") end)
  local after = win_count()
  eq(after, before, "window count unchanged after error")
end)

test("blocking: error is re-raised", function()
  local ok, err = pcall(ui.blocking, "test", function() error("boom") end)
  eq(ok, false, "should error")
  assert(tostring(err):find("boom"), "error msg should contain 'boom'")
end)

test("blocking: nil return values handled", function()
  local a, b = ui.blocking("test", function() return nil, nil end)
  eq(a, nil, "first nil")
  eq(b, nil, "second nil")
end)

-- ── input / confirm ─────────────────────────────────────────────────────────

--- Answer the next prompt with `keys`, then run fn().
local function answering(keys, fn)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "L", false)
  return fn()
end

test("input: returns the typed answer", function()
  eq(answering("hello<CR>", function() return ui.input({ prompt = "P: " }) end),
    "hello", "answer")
end)

test("input: an empty answer is a cancel by default", function()
  eq(answering("<CR>", function() return ui.input({ prompt = "P: " }) end),
    nil, "empty -> nil")
end)

test("input: allow_empty keeps an empty answer", function()
  eq(answering("<CR>", function()
    return ui.input({ prompt = "P: ", allow_empty = true })
  end), "", "empty -> empty string")
end)

test("input: <Esc> cancels even with allow_empty", function()
  eq(answering("<Esc>", function() return ui.input({ prompt = "P: " }) end),
    nil, "esc -> nil")
  eq(answering("<Esc>", function()
    return ui.input({ prompt = "P: ", allow_empty = true })
  end), nil, "esc -> nil with allow_empty")
end)

test("input: default is prefilled and editable", function()
  eq(answering("<CR>", function()
    return ui.input({ prompt = "P: ", default = "dflt" })
  end), "dflt", "default accepted as-is")
  eq(answering("!<CR>", function()
    return ui.input({ prompt = "P: ", default = "dflt" })
  end), "dflt!", "default can be appended to")
end)

test("input: never propagates the <C-c> error", function()
  local real = vim.fn.input
  vim.fn.input = function() error("Keyboard interrupt") end
  local ok, res = pcall(ui.input, { prompt = "P: " })
  vim.fn.input = real
  eq(ok, true, "no error escapes")
  eq(res, nil, "interrupt -> nil")
end)

test("confirm: only y/yes is a yes", function()
  for _, answer in ipairs({ "y", "yes" }) do
    eq(answering(answer .. "<CR>", function()
      return ui.confirm("Q? (y/N): ")
    end), true, answer .. " -> true")
  end
  for _, answer in ipairs({ "n", "no", "Y", "YES", "maybe" }) do
    eq(answering(answer .. "<CR>", function()
      return ui.confirm("Q? (y/N): ")
    end), false, answer .. " -> false")
  end
end)

test("confirm: empty answer and cancel are both a no", function()
  eq(answering("<CR>", function() return ui.confirm("Q? (y/N): ") end),
    false, "empty -> false")
  eq(answering("<Esc>", function() return ui.confirm("Q? (y/N): ") end),
    false, "esc -> false")
end)

-- ── info_float ──────────────────────────────────────────────────────────────

vim.o.lines   = 40
vim.o.columns = 120

--- Run fn() with the editor's window chrome deliberately switched on, then
--- restore it. style = "minimal" only shows up as a difference against
--- non-minimal defaults: with the stock headless options every one of the
--- options it turns off is already off, so a float opened without the style
--- would look exactly the same.
local function with_chrome(fn)
  local chrome = { number = true, relativenumber = true, list = true,
                   cursorline = true, foldcolumn = "2", colorcolumn = "80",
                   signcolumn = "yes:2" }
  local saved = {}
  for opt, value in pairs(chrome) do
    saved[opt] = vim.o[opt]
    vim.o[opt] = value
  end
  local ok, err = pcall(fn)
  for opt, value in pairs(saved) do vim.o[opt] = value end
  if not ok then error(err, 0) end
end

--- Open a float, hand (win, buf, config) to fn, then always clean up.
local function with_float(opts, fn)
  local win, buf = ui.info_float(opts)
  local ok, err = pcall(fn, win, buf, vim.api.nvim_win_get_config(win))
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err, 0) end
end

test("info_float: fills a fresh scratch buffer with lines", function()
  with_float({ lines = { "a", "b" }, width = 20, height = 2 }, function(_, buf)
    local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(#got, 2, "line count"); eq(got[1], "a", "line 1"); eq(got[2], "b", "line 2")
    eq(vim.bo[buf].buflisted, false, "scratch buffer is unlisted")
  end)
end)

test("fit: leaves a size that already fits where it was", function()
  local size, offset = ui.fit(10, 40)
  eq(size, 10, "size"); eq(offset, math.floor((40 - 10) / 2), "offset")
end)

test("fit: clamps a size the screen cannot show", function()
  local size, offset = ui.fit(164, 40)
  eq(size, 36, "size")
  eq(offset >= 0 and offset + size + 2 <= 40, true, "border included, it stays on screen")
end)

-- The float asks Neovim for the size in its config, and that is what this
-- pins: in a TUI Neovim clamps an oversized window on its own, so the window
-- itself would look fine here either way. Under ext_multigrid the requested
-- size is the size the window gets, the buffer fits inside it, and nothing
-- scrolls -- which is the bug this guards.
test("info_float: asks for no more rows than the screen has", function()
  local lines = {}
  for i = 1, 164 do lines[i] = "line " .. i end
  with_float({ lines = lines, width = 40, height = #lines }, function(_, _, cfg)
    eq(cfg.height, 36, "height fitted to the 40-row screen")
    eq(cfg.height < #lines, true, "shorter than its buffer, so it scrolls")
  end)
end)

-- The width axis runs through the same fit as the height, and nothing else in
-- this file would notice if it stopped: every other case asks for a width the
-- 120-column screen can show.
test("info_float: asks for no more columns than the screen has", function()
  with_float({ lines = { "x" }, width = 400, height = 4 }, function(_, _, cfg)
    eq(cfg.width, 116, "width fitted to the 120-column screen")
    eq(cfg.col + cfg.width + 1 <= 120, true, "frame included, it stays on screen")
  end)
end)

-- editor.lua's error float is the live caller doing this: it centres on its
-- own line count, which it never clamps, so a tall one asks for a negative
-- row. Neovim takes that literally under ext_multigrid and the top of the
-- float is then off the editor, unreachable for the same reason an oversized
-- one's tail is.
test("info_float: an explicit row off the top of the editor is pulled back", function()
  with_float({ lines = { "x" }, width = 30, height = 100, row = -60 },
    function(_, _, cfg)
      eq(cfg.row >= 0, true, "row is on screen")
      eq(cfg.row + cfg.height + 1 <= 40, true, "and so is the rest of the frame")
    end)
end)

test("info_float: an explicit row past the bottom is pulled back", function()
  with_float({ lines = { "x" }, width = 30, height = 4, row = 200 },
    function(_, _, cfg)
      eq(cfg.row, 40 - 1 - 4, "row is the last one that shows the whole frame")
    end)
end)

-- A cursor-relative offset is not an editor coordinate, so it is not the
-- clamp's business: editor.lua opens the cell editor above the cursor row with
-- a negative row on purpose, and clamping that to the editor would drop it
-- back onto the cursor.
-- nvim_win_get_config reports a cursor-relative float back as window-relative
-- against the window the cursor was in, offsets verbatim, so `relative` is
-- read as "win" here and the row is what carries the assertion.
test("info_float: a cursor-relative float keeps its own negative row", function()
  with_float({ lines = { "x" }, width = 30, height = 4,
               relative = "cursor", row = -5, col = 0 },
    function(_, _, cfg)
      eq(cfg.relative, "win", "resolved against the cursor's window")
      eq(cfg.row, -5, "row untouched"); eq(cfg.col, 0, "col untouched")
    end)
end)

test("info_float: centers on the editor by default", function()
  with_float({ lines = { "x" }, width = 40, height = 10 }, function(_, _, cfg)
    eq(cfg.relative, "editor", "relative")
    eq(cfg.row, math.floor((40 - 10) / 2), "row centered")
    eq(cfg.col, math.floor((120 - 40) / 2), "col centered")
  end)
end)

-- style = "minimal" is pinned through its effects rather than through
-- nvim_win_get_config(): the returned config only reports `style` back from
-- Neovim 0.11 on, and on the supported 0.10 baseline the key is simply absent.
-- What "minimal" *does* is identical on both -- 'number', 'relativenumber',
-- 'list' and 'cursorline' off, 'foldcolumn' "0", 'colorcolumn' cleared,
-- 'signcolumn' back to "auto" -- and with_chrome turns all of that on
-- editor-wide first, so a float that lost the style would inherit the chrome
-- and fail every assertion below.
test("info_float: opens the float in the minimal style", function()
  with_chrome(function()
    with_float({ lines = { "x" }, width = 40, height = 10 }, function(win)
      eq(vim.wo[win].number, false, "'number' off")
      eq(vim.wo[win].relativenumber, false, "'relativenumber' off")
      eq(vim.wo[win].list, false, "'list' off")
      eq(vim.wo[win].cursorline, false, "'cursorline' off")
      eq(vim.wo[win].foldcolumn, "0", "'foldcolumn' cleared")
      eq(vim.wo[win].colorcolumn, "", "'colorcolumn' cleared")
      eq(vim.wo[win].signcolumn, "auto", "'signcolumn' back to auto")
    end)
  end)
end)

test("info_float: explicit row/col win over centering", function()
  with_float({ lines = { "x" }, width = 30, height = 4, row = 0, col = 7 },
    function(_, _, cfg)
      eq(cfg.row, 0, "row"); eq(cfg.col, 7, "col")
    end)
end)

test("info_float: a nil title leaves the window untitled", function()
  with_float({ lines = { "x" }, width = 20, height = 2 }, function(_, _, cfg)
    eq(cfg.title, nil, "no title")
    eq(cfg.title_pos, nil, "no title_pos")
  end)
end)

test("info_float: title and zindex are forwarded", function()
  with_float({ lines = { "x" }, width = 20, height = 2,
               title = " T ", title_pos = "center", zindex = 70 },
    function(_, _, cfg)
      eq(cfg.title[1][1], " T ", "title text")
      eq(cfg.title_pos, "center", "title_pos")
      eq(cfg.zindex, 70, "zindex")
    end)
end)

test("info_float: reuses a caller-supplied buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "sql"
  with_float({ buf = buf, width = 20, height = 2 }, function(_, got)
    eq(got, buf, "same buffer")
    eq(vim.bo[got].filetype, "sql", "filetype preserved")
  end)
end)

test("info_float: footer survives a bordered window", function()
  with_float({ lines = { "x" }, width = 30, height = 2,
               footer = " f ", footer_pos = "center", border = "rounded" },
    function(_, _, cfg)
      eq(cfg.footer[1][1], " f ", "footer text")
      eq(cfg.footer_pos, "center", "footer_pos")
    end)
end)

test("info_float: footer is dropped when the border cannot carry it", function()
  -- border = "none" makes nvim reject footer: the float must still open.
  with_float({ lines = { "x" }, width = 30, height = 2,
               footer = " f ", footer_pos = "center", border = "none" },
    function(win, _, cfg)
      assert(vim.api.nvim_win_is_valid(win), "float opened without the footer")
      eq(cfg.footer, nil, "footer dropped")
    end)
end)

test("info_float: enter = false keeps the current window focused", function()
  local before = vim.api.nvim_get_current_win()
  with_float({ lines = { "x" }, width = 20, height = 2, enter = false }, function(win)
    assert(win ~= before, "a new window was opened")
    eq(vim.api.nvim_get_current_win(), before, "focus unchanged")
  end)
end)

test("info_float: entered by default", function()
  local before = vim.api.nvim_get_current_win()
  with_float({ lines = { "x" }, width = 20, height = 2 }, function(win)
    eq(vim.api.nvim_get_current_win(), win, "float is focused")
  end)
  eq(vim.api.nvim_get_current_win(), before, "focus restored after close")
end)

test("info_float: scratch buffer options match a throwaway float, not a file", function()
  with_float({ lines = { "x" }, width = 20, height = 2 }, function(_, buf)
    eq(vim.bo[buf].buftype, "nofile", "buftype")
    eq(vim.bo[buf].bufhidden, "hide", "bufhidden")
    eq(vim.bo[buf].swapfile, false, "swapfile")
  end)
end)

-- ── dismiss_float ───────────────────────────────────────────────────────────
-- info_float only opens the window; dismiss_float wires the standard close
-- behavior (q/<Esc> and leaving the window) on top of it. Covered here since
-- both first-pass call sites (view.lua's popup, properties.lua) rely on it
-- and it had no committed test at all before task 14.

--- Open a float wired with dismiss_float, hand (win, buf, close, group) to fn.
--- Always closes and wipes the buffer afterward, whether or not fn left it open.
local function with_dismissable_float(fn)
  local caller_win = vim.api.nvim_get_current_win()
  local group = vim.api.nvim_create_augroup("ui_spec_dismiss_float", { clear = true })
  local win, buf = ui.info_float({ lines = { "x" }, width = 20, height = 2 })
  local close = ui.dismiss_float({ win = win, buf = buf, caller_win = caller_win, group = group })
  local ok, err = pcall(fn, win, buf, close, group, caller_win)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err, 0) end
end

--- q/<Esc> must land back on caller_win *by construction*, not by nvim's
--- default "previous window" fallback -- with only caller_win and the float
--- around, that fallback would pick caller_win anyway and the assertion
--- couldn't tell a real refocus from an accidental one. An extra window,
--- visited between opening the float and dismissing it (e.g. the user tabbed
--- through with <C-w>w and came back), makes caller_win no longer the
--- window-history default, so only dismiss_float's explicit
--- nvim_set_current_win(caller_win) can land focus there.
local function with_dismissable_float_and_decoy(fn)
  local caller_win = vim.api.nvim_get_current_win()
  vim.cmd("split")
  local decoy_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(caller_win)

  local group = vim.api.nvim_create_augroup("ui_spec_dismiss_float_decoy", { clear = true })
  local win, buf = ui.info_float({ lines = { "x" }, width = 20, height = 2 })
  local close = ui.dismiss_float({ win = win, buf = buf, caller_win = caller_win, group = group })
  vim.api.nvim_set_current_win(decoy_win)
  vim.api.nvim_set_current_win(win)

  local ok, err = pcall(fn, win, buf, close, caller_win, decoy_win)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_win_close, decoy_win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err, 0) end
end

test("dismiss_float: q closes the float and returns focus to caller_win", function()
  with_dismissable_float_and_decoy(function(win, _, _, caller_win, decoy_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
    eq(vim.api.nvim_get_current_win(), caller_win, "focus back on caller_win")
    assert(vim.api.nvim_get_current_win() ~= decoy_win, "not left on the decoy window")
  end)
end)

test("dismiss_float: <Esc> closes the float and returns focus to caller_win", function()
  with_dismissable_float_and_decoy(function(win, _, _, caller_win, decoy_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
    eq(vim.api.nvim_get_current_win(), caller_win, "focus back on caller_win")
    assert(vim.api.nvim_get_current_win() ~= decoy_win, "not left on the decoy window")
  end)
end)

test("dismiss_float: the returned close() closes the window directly", function()
  -- Exercises the closure the way properties.lua's gI/reopen keymap does:
  -- called directly, not through the q/<Esc> keymaps this same call wires up.
  with_dismissable_float(function(win, _, close)
    close()
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
  end)
end)

test("dismiss_float: close() takes the float's buffer down with the window", function()
  -- This assertion used to be inverted: it pinned the leak as characterization
  -- (close() called nvim_win_close only, so info_float's unlisted
  -- bufhidden=hide scratch buffer stayed alive, invisible to :ls, one more per
  -- float for the rest of the session). Task 17 fixed the leak, so the pin
  -- flipped by hand to the behavior we now want.
  with_dismissable_float(function(win, buf, close)
    close()
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
    eq(vim.api.nvim_buf_is_valid(buf), false, "buffer deleted, not left hidden")
  end)
end)

test("dismiss_float: enter = false -- close() still drops autocmd and buffer", function()
  -- A float opened unfocused is never entered, so its buffer-local WinLeave can
  -- never fire: cleanup has to come from close() itself or nothing happens at
  -- all. Mirrors the ddl.lua/json_tree.lua style of preview float.
  local caller_win = vim.api.nvim_get_current_win()
  local group = vim.api.nvim_create_augroup("ui_spec_dismiss_float_noenter", { clear = true })
  local win, buf = ui.info_float({ lines = { "x" }, width = 20, height = 2, enter = false })
  local close = ui.dismiss_float({ win = win, buf = buf, caller_win = caller_win, group = group })
  local ok, err = pcall(function()
    eq(vim.api.nvim_get_current_win(), caller_win, "float was never entered")
    close()
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed")
    eq(vim.api.nvim_buf_is_valid(buf), false, "buffer deleted")
    eq(#vim.api.nvim_get_autocmds({ group = group }), 0, "WinLeave dropped, not left dangling")
  end)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err, 0) end
end)

test("dismiss_float: close() is idempotent -- the second call is a silent no-op", function()
  -- with_dismissable_float leaves the cursor *in* the float, so the first
  -- close() is the reentrant case: it closes the very window whose WinLeave it
  -- registered. Nothing may raise, and the drain below gives a WinLeave that
  -- slipped through a chance to schedule a third close on already-dead handles.
  with_dismissable_float(function(win, buf, close, group)
    close()
    local ok2, err2 = pcall(close)
    eq(ok2, true, "second close() does not raise: " .. tostring(err2))
    vim.wait(50)
    eq(vim.api.nvim_win_is_valid(win), false, "window still closed")
    eq(vim.api.nvim_buf_is_valid(buf), false, "buffer still deleted")
    eq(#vim.api.nvim_get_autocmds({ group = group }), 0, "no autocmd left behind")
  end)
end)

test("dismiss_float: leaving the window (WinLeave) closes it without pressing q", function()
  with_dismissable_float(function(win, buf, _, _, caller_win)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_set_current_win(caller_win) -- e.g. <C-w>w away from the float
    vim.wait(200, function() return not vim.api.nvim_win_is_valid(win) end, 10)
    eq(vim.api.nvim_win_is_valid(win), false, "float window closed on WinLeave")
    eq(vim.api.nvim_buf_is_valid(buf), false, "and its buffer went with it")
  end)
end)

test("dismiss_float: a hand-typed :q leaves no buffer behind either", function()
  -- The one path that bypasses close() entirely on the way in: :q closes the
  -- window itself, and only the WinLeave it fires gets us into close() to
  -- collect the buffer.
  with_dismissable_float(function(win, buf)
    vim.api.nvim_set_current_win(win)
    vim.cmd("q")
    vim.wait(200, function() return not vim.api.nvim_buf_is_valid(buf) end, 10)
    eq(vim.api.nvim_win_is_valid(win), false, "float window gone")
    eq(vim.api.nvim_buf_is_valid(buf), false, "buffer collected by the WinLeave")
  end)
end)

test("dismiss_float: the WinLeave autocmd is consumed, not left dangling", function()
  with_dismissable_float(function(win, _, _, group)
    eq(#vim.api.nvim_get_autocmds({ group = group }), 1, "one autocmd while the float is open")
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
    eq(#vim.api.nvim_get_autocmds({ group = group }), 0, "none left after close")
  end)
end)

test("dismiss_float: repeated open/close cycles never accumulate autocmds", function()
  local caller_win = vim.api.nvim_get_current_win()
  local group = vim.api.nvim_create_augroup("ui_spec_dismiss_float_repeat", { clear = true })
  for _ = 1, 3 do
    local win, buf = ui.info_float({ lines = { "x" }, width = 20, height = 2 })
    ui.dismiss_float({ win = win, buf = buf, caller_win = caller_win, group = group })
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  eq(#vim.api.nvim_get_autocmds({ group = group }), 0, "no leftover autocmds after 3 cycles")
end)

-- ── report_split ────────────────────────────────────────────────────────────
-- report_split asks nvim for a height and gets whatever is still free, so the
-- tests below need a known editor geometry: 40 lines (already set for the
-- floats above), a one-line cmdline, and a window that actually occupies the
-- rest of the screen.
--
-- All three have to be stated. The cmdline prompts driven further up scroll
-- messages past the cmdline, which on Neovim 0.10 leaves 'cmdheight' inflated
-- -- 17 rows by the time we get here, so only 20 of the 30 requested rows are
-- still free and the cap assertion measures the screen instead of the cap.
-- Lowering 'cmdheight' is not enough on its own: the window does not grow into
-- the freed rows, and the next time nvim recomputes the layout (the first
-- botright split below) it hands them straight back to the cmdline. Asking for
-- an over-tall window makes the layout reclaim them for good -- nvim clamps the
-- request to whatever the single window may actually have.
vim.o.lines     = 40
vim.o.cmdheight = 1
vim.api.nvim_win_set_height(0, vim.o.lines)

test("report_split: read-only named scratch buffer in a bottom split", function()
  local before = win_count()
  local bufnr, winid = ui.report_split({ "line 1", "line 2" }, "grip://test/report")
  local ok, err = pcall(function()
    eq(win_count(), before + 1, "one new window")
    eq(vim.api.nvim_win_get_buf(winid), bufnr, "buffer shown in the split")
    eq(vim.bo[bufnr].buftype, "nofile", "buftype")
    eq(vim.bo[bufnr].modifiable, false, "read-only")
    assert(vim.api.nvim_buf_get_name(bufnr):find("grip://test/report", 1, true),
      "buffer name")
    eq(vim.wo[winid].cursorline, true, "cursorline")
    eq(vim.wo[winid].wrap, false, "wrap off")
    local got = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    eq(got[1], "line 1", "line 1"); eq(got[2], "line 2", "line 2")
  end)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if not ok then error(err, 0) end
end)

test("report_split: height follows the content, capped at 30", function()
  local short = {}
  for i = 1, 5 do short[i] = "l" .. i end
  local b1, w1 = ui.report_split(short, "grip://test/short")
  local h1 = vim.api.nvim_win_get_height(w1)
  pcall(vim.api.nvim_buf_delete, b1, { force = true })
  eq(h1, 7, "5 lines + 2")

  local long = {}
  for i = 1, 200 do long[i] = "l" .. i end
  local b2, w2 = ui.report_split(long, "grip://test/long")
  local h2 = vim.api.nvim_win_get_height(w2)
  pcall(vim.api.nvim_buf_delete, b2, { force = true })
  eq(h2, 30, "capped at 30")
end)

print(string.format("ui_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
