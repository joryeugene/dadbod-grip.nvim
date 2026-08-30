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
local columns = vim.o.columns
local expected_columns = tonumber(vim.env.GRIP_EXPECT_COLUMNS or "")
if expected_columns then
  assert(columns == expected_columns,
    string.format("attached UI is %d columns, expected %d", columns, expected_columns))
end
local expected_sidebar = math.max(24, math.min(36, math.floor(columns * 0.25)))

assert(sidebar.col == 0 and sidebar.width == expected_sidebar, vim.inspect(windows))
assert(pad.col == welcome.col and pad.width == welcome.width, vim.inspect(windows))
assert(pad.col > sidebar.col + sidebar.width - 1, vim.inspect(windows))
assert(pad.row < welcome.row and pad.height >= 10 and welcome.height >= 4, vim.inspect(windows))
assert(pad.width >= 50, "main workspace too narrow: " .. vim.inspect(windows))

-- Optional local E2E path: an external tmux driver resizes the attached UI,
-- so Neovim's backing grid and 'columns' change together. Never fake a
-- headless resize by assigning vim.o.columns; Neovim documents that as
-- display-state corruption.
local tmux_sync = vim.env.GRIP_TMUX_SYNC
if tmux_sync and tmux_sync ~= "" then
  local function signal(step)
    local result = vim.system({ "tmux", "wait-for", "-S", tmux_sync .. "-" .. step },
      { text = true }):wait()
    assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  end
  local function wait_for_width(width)
    assert(vim.wait(3000, function() return vim.o.columns == width end, 10),
      string.format("attached UI did not resize to %d columns", width))
  end

  signal("ready")
  wait_for_width(80)
  vim.wait(1000, function() return vim.api.nvim_win_get_width(sidebar.id) == 24 end, 10)
  local width_at_80 = vim.api.nvim_win_get_width(sidebar.id)
  assert(width_at_80 == 24,
    string.format("sidebar width at 80 columns is %d, expected 24", width_at_80))
  assert(vim.api.nvim_win_get_width(pad.id) >= 50, "workspace became too narrow at 80 columns")
  signal("80")
  wait_for_width(160)
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24,
    "sidebar regrew after the attached UI expanded")
  signal("160")
  wait_for_width(100)
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24,
    "deliberately narrow sidebar changed on a second resize")
  signal("100")
end

vim.cmd("qall!")
