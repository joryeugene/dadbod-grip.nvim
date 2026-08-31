local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")
local data = require("dadbod-grip.data")
local db = require("dadbod-grip.db")
local view = require("dadbod-grip.view")

local url = "sqlite:tests/seed_sqlite.db"
grip.setup({ open_sidebar = true })
assert(connections.switch(url, "seed", "sqlite"))
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

  grip.open("users", url)
  assert(vim.wait(3000, function() return vim.fn.bufnr("grip://users") ~= -1 end, 10),
    "users grid did not open")
  local grid_lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr("grip://users"), 0, -1, false)
  local grid = table.concat(grid_lines, "\n")
  assert(grid:find("Alice", 1, true), "users grid did not render seeded rows")

  vim.cmd("redraw")
  signal("ready")
  wait_for_width(80)
  vim.wait(1000, function() return vim.api.nvim_win_get_width(sidebar.id) == 24 end, 10)
  local width_at_80 = vim.api.nvim_win_get_width(sidebar.id)
  assert(width_at_80 == 24,
    string.format("sidebar width at 80 columns is %d, expected 24", width_at_80))
  assert(vim.api.nvim_win_get_width(pad.id) >= 50, "workspace became too narrow at 80 columns")
  vim.cmd("redraw")
  signal("80")
  wait_for_width(160)
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24,
    "sidebar regrew after the attached UI expanded")
  vim.cmd("redraw")
  signal("160")
  wait_for_width(100)
  assert(vim.api.nvim_win_get_width(sidebar.id) == 24,
    "deliberately narrow sidebar changed on a second resize")
  signal("100")

  local grid_buf = vim.fn.bufnr("grip://users")
  local function session() return view._sessions[grid_buf] end
  local function imported_count()
    local result = assert(db.query(
      "SELECT COUNT(*) FROM users WHERE email IN "
        .. "('e2e-one@example.test', 'e2e-two@example.test')", url))
    return tonumber(result.rows[1][1])
  end

  local function fail(message)
    vim.api.nvim_err_writeln("workspace layout integration: " .. tostring(message))
    vim.cmd("cquit")
  end

  local function wait_until(label, predicate, on_ready, attempt)
    attempt = (attempt or 0) + 1
    local ok, ready = pcall(predicate)
    if not ok then fail(ready); return end
    if ready then
      ok, ready = pcall(on_ready)
      if not ok then fail(ready) end
      return
    end
    if attempt >= 800 then fail(label); return end
    vim.defer_fn(function() wait_until(label, predicate, on_ready, attempt) end, 10)
  end

  signal("import-ready")
  wait_until("real :GripImport did not stage two rows", function()
    local current = session()
    return current and data.count_staged(current.state) == 2
  end, function()
    assert(imported_count() == 0, "import wrote before the apply confirmation")
    local staged = table.concat(vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false), "\n")
    assert(staged:find("E2E Import One", 1, true), "first staged row did not render")
    assert(staged:find("E2E Import Two", 1, true), "second staged row did not render")
    assert(staged:find("2 staged", 1, true), "staged-count badge did not render")
    signal("import-staged")

    wait_until("gs did not show both imported INSERT statements", function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].filetype ~= "sql" then return false end
      local sql = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      return sql:find("E2E Import One", 1, true) and sql:find("E2E Import Two", 1, true)
    end, function()
      local sql = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      local _, inserts = sql:gsub("INSERT INTO", "")
      assert(inserts == 2, "staged SQL preview did not contain exactly two INSERTs")
      signal("import-sql")

      wait_until("one u did not remove the complete imported batch", function()
        local current = session()
        return current and data.count_staged(current.state) == 0
      end, function()
        assert(imported_count() == 0, "undo wrote imported rows to the database")
        signal("import-undone")

        wait_until("second :GripImport did not restage the batch", function()
          local current = session()
          return current and data.count_staged(current.state) == 2
        end, function()
          signal("import-restaged")

          wait_until("confirmed apply did not clear the staged batch", function()
            local current = session()
            return current and data.count_staged(current.state) == 0
          end, function()
            assert(imported_count() == 2, "confirmed apply did not commit exactly two imported rows")
            signal("import-applied")
          end)
        end)
      end)
    end)
  end)
  return
end

vim.cmd("qall!")
