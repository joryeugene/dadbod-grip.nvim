-- editor.lua — float cell editor.
-- Minimal: one purpose, no state leaked to caller.

local M = {}

-- Sentinel: caller uses this to distinguish "user set NULL" from "user cancelled".
M.NULL_VALUE = "__GRIP_NULL__"

-- M.open(prompt, initial_value, on_save)
--   prompt:        string shown in border title (e.g. "users.name")
--   initial_value: string | nil (nil = current value is NULL, pre-fill empty)
--   on_save(result):
--     result = nil              → user cancelled (Esc)
--     result = M.NULL_VALUE     → user explicitly wants NULL (saved empty)
--     result = "some string"    → new value
function M.open(prompt, initial_value, on_save)
  local caller_win = vim.api.nvim_get_current_win()  -- save for restore on close
  local pre_fill = initial_value or ""
  local width = math.min(60, math.max(30, #pre_fill + 6))

  -- Create a scratch buffer for the editor
  local edit_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = edit_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = edit_buf })
  vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, { pre_fill })

  -- Position: above cursor row
  local cursor = vim.api.nvim_win_get_cursor(0)
  local win_row = cursor[1]
  local float_row = win_row > 3 and -2 or 1

  local float_win = vim.api.nvim_open_win(edit_buf, true, {
    relative = "cursor",
    row = float_row,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " " .. (prompt or "edit") .. " ",
    title_pos = "center",
    footer = "  <CR> save   <Esc> cancel  ",
    footer_pos = "right",
    zindex = 60,
  })

  -- Start in insert mode at end of line
  vim.cmd("startinsert!")

  local closed = false  -- guard against double-fire (save + WinLeave)

  local function restore_caller()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(caller_win) then
        vim.api.nvim_set_current_win(caller_win)
      end
    end)
  end

  local function do_save()
    if closed then return end
    closed = true
    local lines = vim.api.nvim_buf_get_lines(edit_buf, 0, -1, false)
    local val = lines[1] or ""
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
    restore_caller()
    -- Empty string → NULL signal
    local result = val == "" and M.NULL_VALUE or val
    on_save(result)
  end

  local function do_cancel()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
    restore_caller()
    on_save(nil)
  end

  -- Keymaps (buf-local)
  vim.keymap.set({ "i", "n" }, "<CR>", do_save,   { buffer = edit_buf, noremap = true })
  vim.keymap.set({ "i", "n" }, "<C-s>", do_save,  { buffer = edit_buf, noremap = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", do_cancel, { buffer = edit_buf, noremap = true })

  -- Also cancel if the float loses focus
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = edit_buf,
    once = true,
    callback = function()
      if closed then return end  -- already handled by save/cancel
      closed = true
      if vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      restore_caller()
      on_save(nil)
    end,
  })
end

-- Show a focused error float. Dismiss with q / <CR> / <Esc>.
function M.show_error(title, lines)
  local caller_win = vim.api.nvim_get_current_win()

  local max_w = 0
  for _, l in ipairs(lines) do max_w = math.max(max_w, #l) end
  local width = math.min(80, math.max(40, max_w + 4))

  local err_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(err_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = err_buf })

  -- Highlight group for error
  local ns = vim.api.nvim_create_namespace("grip_error")
  for i, line in ipairs(lines) do
    if line:match("^✗") or line:match("violates") or line:match("constraint") then
      vim.api.nvim_buf_set_extmark(err_buf, ns, i - 1, 0, {
        end_col = #line,
        hl_group = "DiagnosticError",
      })
    elseif line:match("preserved") or line:match("Fix") or line:match("press") then
      vim.api.nvim_buf_set_extmark(err_buf, ns, i - 1, 0, {
        end_col = #line,
        hl_group = "DiagnosticHint",
      })
    end
  end

  local float_win = vim.api.nvim_open_win(err_buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines - 4) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "Error") .. " ",
    title_pos = "center",
    zindex = 70,
  })

  local function dismiss()
    if vim.api.nvim_win_is_valid(float_win) then
      vim.api.nvim_win_close(float_win, true)
    end
    if vim.api.nvim_win_is_valid(caller_win) then
      vim.api.nvim_set_current_win(caller_win)
    end
  end

  for _, key in ipairs({ "q", "<CR>", "<Esc>" }) do
    vim.keymap.set("n", key, dismiss, { buffer = err_buf, nowait = true })
  end

  -- Safety: dismiss if float loses focus (e.g. user clicks away)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = err_buf,
    once = true,
    callback = dismiss,
  })
end

return M
