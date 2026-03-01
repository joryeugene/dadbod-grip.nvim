-- query_pad.lua — SQL scratch buffer that pipes results into grip grids.
-- ft=sql enables vim-dadbod-completion if installed.
-- b:db = connection URL for completion context.

local M = {}

local _pad_bufnr = nil

--- Get or create the query pad buffer.
local function ensure_buf(url)
  if _pad_bufnr and vim.api.nvim_buf_is_valid(_pad_bufnr) then
    -- Update connection if changed
    vim.b[_pad_bufnr].db = url
    return _pad_bufnr
  end

  _pad_bufnr = vim.api.nvim_create_buf(true, false)
  vim.bo[_pad_bufnr].buftype = "acwrite"
  vim.bo[_pad_bufnr].swapfile = false
  vim.bo[_pad_bufnr].filetype = "sql"
  vim.api.nvim_buf_set_name(_pad_bufnr, "grip://query")
  vim.b[_pad_bufnr].db = url

  -- Mark buffer as not modified after creation
  vim.bo[_pad_bufnr].modified = false

  -- BufWriteCmd: save query with :GripSave
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = _pad_bufnr,
    callback = function()
      local saved = require("dadbod-grip.saved")
      saved.save_prompt(_pad_bufnr)
    end,
  })

  return _pad_bufnr
end

--- Run SQL from the query pad and open results in a grip grid.
local function run_sql(url, sql)
  if not sql or sql:match("^%s*$") then
    vim.notify("Grip: empty query", vim.log.levels.WARN)
    return
  end
  local grip = require("dadbod-grip")
  grip.open(sql, url)
end

--- Set up buffer-local keymaps.
local function setup_keymaps(bufnr, url)
  -- C-CR: run full buffer
  vim.keymap.set("n", "<C-CR>", function()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    run_sql(url, table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  -- C-CR in insert mode too
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    run_sql(url, table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run query" })

  -- Visual C-CR: run selection
  vim.keymap.set("v", "<C-CR>", function()
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[2] - 1, end_pos[2], false)
    if #lines == 0 then return end
    -- Trim first and last line to visual selection columns
    if #lines == 1 then
      lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
    else
      lines[1] = lines[1]:sub(start_pos[3])
      lines[#lines] = lines[#lines]:sub(1, end_pos[3])
    end
    run_sql(url, table.concat(lines, "\n"))
  end, { buffer = bufnr, silent = true, desc = "Grip: run selection" })

  -- C-s: save query
  vim.keymap.set("n", "<C-s>", function()
    local saved = require("dadbod-grip.saved")
    saved.save_prompt(bufnr)
  end, { buffer = bufnr, silent = true, desc = "Grip: save query" })
end

--- Open the query pad.
--- @param url string connection URL
--- @param opts? { initial_sql?: string }
function M.open(url, opts)
  opts = opts or {}

  if not url then
    local db_mod = require("dadbod-grip.db")
    url = db_mod.get_url()
    if not url then
      vim.notify("Grip: no database connection. Set vim.g.db or use :GripConnect.", vim.log.levels.ERROR)
      return
    end
  end

  local bufnr = ensure_buf(url)
  setup_keymaps(bufnr, url)

  -- Find or create a window for the pad
  local pad_win = nil
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      pad_win = winid
      break
    end
  end

  if not pad_win then
    vim.cmd("botright split")
    pad_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(pad_win, bufnr)
    -- Reasonable height
    vim.api.nvim_win_set_height(pad_win, math.max(8, math.floor(vim.o.lines * 0.25)))
  end

  vim.api.nvim_set_current_win(pad_win)

  -- Pre-fill if requested and buffer is empty
  if opts.initial_sql then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local is_empty = #lines == 0 or (#lines == 1 and lines[1] == "")
    if is_empty then
      local sql_lines = vim.split(opts.initial_sql, "\n")
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sql_lines)
      vim.bo[bufnr].modified = false
    end
  end
end

return M
