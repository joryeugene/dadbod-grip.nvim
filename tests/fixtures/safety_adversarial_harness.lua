-- Independent disposable public-path harness. No production database or
-- registry can be reached: each case gets a new SQLite file and fake home.
local M = { pass = 0, fail = 0 }
function M.eq(got, want, message)
  assert(vim.deep_equal(got, want), (message or "") .. ": expected "
    .. vim.inspect(want) .. ", got " .. vim.inspect(got))
end
function M.key(buf, key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == key then
      assert(type(mapping.callback) == "function", "missing callback: " .. key)
      mapping.callback()
      return
    end
  end
  error("missing normal mapping: " .. key)
end
function M.fixture(fn)
  local grip, view = require("dadbod-grip"), require("dadbod-grip.view")
  local db, paths, ui = require("dadbod-grip.db"), require("dadbod-grip.paths"), require("dadbod-grip.ui")
  local root = vim.fn.tempname() .. "_safety_adversarial"
  vim.fn.mkdir(root .. "/project/.grip", "p")
  vim.fn.mkdir(root .. "/home/.grip", "p")
  local orig = { opts = grip.get_opts(), root = paths.project_root, expand = vim.fn.expand,
    notify = vim.notify, confirm = ui.confirm, fn_confirm = vim.fn.confirm, gdb = vim.g.db,
    tab = vim.api.nvim_get_current_tabpage() }
  local before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do before[b] = true end
  local c = { root = root, url = "sqlite:" .. root .. "/case.sqlite", notices = {} }
  paths.project_root = function() return root .. "/project" end
  vim.fn.expand = function(s, ...)
    if s == "~" then return root .. "/home" end
    return orig.expand(s, ...)
  end
  vim.notify = function(msg) c.notices[#c.notices + 1] = tostring(msg) end
  ui.confirm = function() return true end
  vim.fn.confirm = function() return 1 end
  vim.g.db = nil
  grip.setup({ discovery = false, open_sidebar = false, timeout = 5000, sticky_header = true })
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  function c.exec(statement)
    local result, err = db.execute(statement, c.url)
    assert(result, err)
    return result
  end
  function c.rows(statement)
    local result, err = db.query(statement, c.url)
    assert(result, err)
    return result.rows
  end
  function c.scalar(statement) return c.rows(statement)[1][1] end
  function c.open(name)
    grip.open(name, c.url, { from_pad = true })
    local buf = vim.api.nvim_get_current_buf()
    local session = assert(view._sessions[buf], "missing fixture session")
    -- External stale-row mutations must follow the initial metadata read.
    -- Quiesce this fixture's callback; product query scheduling is separate.
    if session.state.table_name then
      assert(vim.wait(5000, function() return session._column_info ~= nil end, 1),
        "fixture column metadata did not settle")
    end
    return buf, session
  end
  function c.action(action)
    local mapping = vim.fn.maparg(require("dadbod-grip.keymaps").get(action), "n", false, true)
    assert(type(mapping.callback) == "function", "missing action: " .. action)
    mapping.callback()
  end
  function c.edit(buf, session, row, column, value)
    view.apply_edit(buf, require("dadbod-grip.data").add_change(session.state, row, column, value))
  end
  function c.focus(buf, session, row, column)
    local r = session._render
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    vim.api.nvim_win_set_cursor(0, { r.data_start + row - 1, r.byte_positions[row][column].start })
  end
  local ok, err = xpcall(function() fn(c) end, debug.traceback)
  vim.cmd("stopinsert")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before[b] then
      view._sessions[b] = nil
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  vim.api.nvim_set_current_tabpage(orig.tab)
  vim.wait(5, function() return false end, 1)
  paths.project_root, vim.fn.expand = orig.root, orig.expand
  vim.notify, ui.confirm, vim.fn.confirm, vim.g.db = orig.notify, orig.confirm, orig.fn_confirm, orig.gdb
  grip.setup(orig.opts)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end
function M.test(id, fn)
  local ok, err = pcall(M.fixture, fn)
  if ok then M.pass = M.pass + 1
  else M.fail = M.fail + 1; print("\nFAIL: " .. id .. ": " .. tostring(err)) end
end
function M.finish(name)
  print(string.format("%s: %d passed, %d failed", name, M.pass, M.fail))
  if M.fail > 0 then os.exit(1) end
end
return M
