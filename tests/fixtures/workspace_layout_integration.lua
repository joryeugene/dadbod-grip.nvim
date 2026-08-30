local columns = assert(tonumber(vim.env.GRIP_TEST_COLUMNS), "GRIP_TEST_COLUMNS is required")
vim.o.columns = columns
vim.o.lines = 40

local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

grip.setup({ open_sidebar = true })
assert(connections.switch("sqlite:tests/seed_sqlite.db", "seed", "sqlite"))
assert(vim.wait(5000, function()
  return schema.is_open() and query_pad.get_pad_bufnr()
    and vim.fn.bufnr("grip://welcome") ~= -1
end, 10), "workspace did not finish opening")

local windows = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  if name:match("^grip://") then
    local pos = vim.api.nvim_win_get_position(win)
    windows[name] = {
      id = win,
      row = pos[1], col = pos[2],
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    }
  end
end

local sidebar = assert(windows["grip://schema"], vim.inspect(windows))
local pad = assert(windows["grip://query"], vim.inspect(windows))
local welcome = assert(windows["grip://welcome"], vim.inspect(windows))
local expected_sidebar = math.max(24, math.min(36, math.floor(columns * 0.25)))

assert(sidebar.col == 0 and sidebar.width == expected_sidebar, vim.inspect(windows))
assert(pad.col == welcome.col and pad.width == welcome.width, vim.inspect(windows))
assert(pad.col > sidebar.col + sidebar.width - 1, vim.inspect(windows))
assert(pad.row < welcome.row and pad.height >= 10 and welcome.height >= 4, vim.inspect(windows))
assert(pad.width >= 50, "main workspace too narrow: " .. vim.inspect(windows))

-- Exercise the real VimResized autocmd: shrink to 80, then grow back. The
-- sidebar must clamp to 24 and stay there rather than overriding user sizing.
if columns == 160 then
  vim.o.columns = 80
  vim.cmd("doautocmd VimResized")
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24, "sidebar did not shrink")
  vim.o.columns = 160
  vim.cmd("doautocmd VimResized")
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24, "sidebar regrew unexpectedly")
end

vim.cmd("qall!")
