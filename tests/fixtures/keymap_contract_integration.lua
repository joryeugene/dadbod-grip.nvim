local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local editor = require("dadbod-grip.editor")
local keymaps = require("dadbod-grip.keymaps")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

local scenario = vim.env.GRIP_KEYMAP_SCENARIO or "default"
local observed = {}
local real_bind = keymaps.bind
keymaps.bind = function(surface, bufnr, action, mode, fn, opts)
  local registered = real_bind(surface, bufnr, action, mode, fn, opts)
  if registered then
    observed[table.concat({ surface, tostring(bufnr), mode, action }, "\0")] = {
      surface = surface,
      bufnr = bufnr,
      mode = mode,
      action = action,
      key = keymaps.get(action),
    }
  end
  return registered
end

local remaps = {
  grid_col_left = ",",
  grid_col_right = ";",
  table_picker_go = "zp",
  qpad_complete = "<F14>",
  qpad_complete_next = "<F15>",
  qpad_complete_prev = "<F16>",
  qpad_complete_down = "<F17>",
  qpad_complete_up = "<F18>",
  qpad_complete_accept = "<F19>",
  sidebar_close = "<F20>",
  editor_save = "<F21>",
  editor_save_alt = "<F22>",
  editor_cancel = "<F23>",
  editor_cancel_q = "<F24>",
  editor_cancel_insert = "<F25>",
  editor_open_url = "<F26>",
}
local target_actions = {}
for action in pairs(remaps) do target_actions[action] = true end

local opts = { open_sidebar = true }
if scenario == "remap" then
  opts.keymaps = remaps
elseif scenario == "disabled" then
  opts.keymaps = {}
  for action in pairs(target_actions) do opts.keymaps[action] = false end
  opts.completion = false
  opts.ai = false
end
grip.setup(opts)

local url = "sqlite:tests/seed_sqlite.db"
assert(connections.switch(url, "seed", "sqlite"))
assert(vim.wait(5000, function()
  return schema.is_open() and query_pad.get_pad_bufnr()
end, 10), "workspace did not open")

grip.open("users", url)
assert(vim.wait(5000, function() return vim.fn.bufnr("grip://users") ~= -1 end, 10),
  "grid did not open")

local buffers = {
  grid = vim.fn.bufnr("grip://users"),
  query_pad = query_pad.get_pad_bufnr(),
  sidebar = vim.fn.bufnr("grip://schema"),
}

local function normalize(key)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(key, true, true, true))
end

local function includes(values, wanted)
  for _, value in ipairs(values) do
    if value == wanted then return true end
  end
  return false
end

local function expected_for(surface, mode)
  local expected = {}
  for _, record in ipairs(keymaps.catalog) do
    local enabled = not record.requires or grip.get_opts()[record.requires]
    local key = keymaps.get(record.action)
    if enabled and key and includes(record.surfaces, surface) and includes(record.modes, mode) then
      local lhs = normalize(key)
      assert(not expected[lhs], string.format("duplicate expected %s %s mapping: %s and %s",
        surface, mode, expected[lhs], record.action))
      expected[lhs] = record.action
    end
  end
  return expected
end

local function assert_surface(surface, bufnr, modes)
  for _, mode in ipairs(modes) do
    local expected = expected_for(surface, mode)
    local registered = {}
    for _, mapping in pairs(observed) do
      if mapping.surface == surface and mapping.bufnr == bufnr and mapping.mode == mode then
        registered[normalize(mapping.key)] = mapping.action
      end
    end
    assert(vim.deep_equal(registered, expected), string.format(
      "%s %s registrations differ: expected %s, got %s",
      surface, mode, vim.inspect(expected), vim.inspect(registered)))

    local installed = {}
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      installed[normalize(mapping.lhs)] = true
    end
    for lhs, action in pairs(expected) do
      assert(installed[lhs], string.format("%s %s is missing %s (%s)", surface, mode, action, lhs))
    end
  end
end

assert_surface("grid", buffers.grid, { "n", "x" })
assert_surface("query_pad", buffers.query_pad, { "n", "i", "x" })
assert_surface("sidebar", buffers.sidebar, { "n" })

local function callback_for(bufnr, mode, key)
  local lhs = normalize(key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if normalize(mapping.lhs) == lhs then return mapping.callback end
  end
end

if scenario == "remap" then
  local left = assert(callback_for(buffers.grid, "n", ","), "remapped left callback missing")
  local right = assert(callback_for(buffers.grid, "n", ";"), "remapped right callback missing")
  local grid_picker = assert(callback_for(buffers.grid, "n", "zp"),
    "grid table-picker callback missing")
  local query_picker = assert(callback_for(buffers.query_pad, "n", "zp"),
    "query table-picker callback missing")
  local close_sidebar = assert(callback_for(buffers.sidebar, "n", "<F20>"),
    "remapped sidebar close callback missing")
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(scratch)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "0123456789" })
  vim.keymap.set("n", ",", left, { buffer = scratch })
  vim.keymap.set("n", ";", right, { buffer = scratch })
  local start = { 1, 8 }

  vim.api.nvim_win_set_cursor(0, start)
  vim.cmd("normal! 3h")
  local expected_left = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, start)
  vim.cmd("normal 3,")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), expected_left),
    "remapped left motion did not preserve the count")

  vim.api.nvim_win_set_cursor(0, start)
  vim.cmd("normal! 4l")
  local expected_right = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, start)
  vim.cmd("normal 4;")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), expected_right),
    "remapped right motion did not preserve the count")

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal 99,")
  assert(vim.api.nvim_win_get_cursor(0)[2] == 0, "left motion crossed the line boundary")
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  vim.cmd("normal 99;")
  assert(vim.api.nvim_win_get_cursor(0)[2] == 9, "right motion crossed the line boundary")

  local picker = require("dadbod-grip.picker")
  local real_pick_table = picker.pick_table
  local picked = 0
  picker.pick_table = function() picked = picked + 1 end
  grid_picker()
  query_picker()
  picker.pick_table = real_pick_table
  assert(picked == 2, "remapped short table picker did not run on grid and query pad")
  close_sidebar()
  assert(not schema.is_open(), "remapped sidebar close did not close the sidebar")
end

for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(win) == buffers.grid then
    vim.api.nvim_set_current_win(win)
    break
  end
end
local editor_result = "not called"
editor.open("Keymap contract", "value", function(value) editor_result = value end)
buffers.cell_editor = vim.api.nvim_get_current_buf()
assert_surface("cell_editor", buffers.cell_editor, { "n", "i" })

if scenario == "remap" then
  local cancel = assert(callback_for(buffers.cell_editor, "n", "<F23>"),
    "remapped cell-editor cancel callback missing")
  cancel()
  assert(editor_result == nil, "remapped cell-editor cancel did not cancel")
end

if scenario == "disabled" then
  local grid_normal = expected_for("grid", "n")
  local query_normal = expected_for("query_pad", "n")
  assert(grid_normal[normalize("A")] == "ai", "ai=false removed the grid AI key")
  assert(query_normal[normalize("gA")] == "qpad_ai", "ai=false removed the query-pad AI key")
end

vim.cmd("qall!")
