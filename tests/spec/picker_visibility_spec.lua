-- Real picker windows: key hints must be visible, not just present off-screen.
dofile("tests/minimal_init.lua")
local picker, ui = require("dadbod-grip.grip_picker"), require("dadbod-grip.ui")
local pass, fail = 0, 0
local function close()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
  end
end
local function test(name, fn)
  close(); local ok, err = xpcall(fn, debug.traceback); close()
  if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. name .. ": " .. err) end
end
local function press(key)
  local buf = vim.api.nvim_get_current_buf()
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == key then assert(map.callback); map.callback(); return end
  end
  error("missing map " .. key)
end
local function visible_footer()
  local win = vim.api.nvim_get_current_win(); local buf = vim.api.nvim_win_get_buf(win)
  local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local top = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
  local text = {}
  for i = top, math.min(#lines, top + height - 1) do
    assert(vim.fn.strdisplaywidth(lines[i]) <= width, "line clips horizontally: " .. lines[i])
    text[#text + 1] = lines[i]
  end
  return table.concat(text, "\n"), height, #lines
end
local function hints(text)
  assert(text:find("Enter:select", 1, true), "selection hint hidden")
  assert(text:find("/:filter", 1, true), "filter hint hidden")
  assert(text:find("q:close", 1, true), "close hint hidden")
end
test("short table names still show all basic hints", function()
  picker.open({ title = "Tables", items = { "a", "b" } })
  hints(visible_footer())
end)
test("connection actions wrap instead of clipping filter and close", function()
  picker.open({ title = "Connections", items = { "demo" }, on_delete = function() end,
    actions = { { key = "!", label = "!:write", fn = function() end },
      { key = "M", label = "M:mask", fn = function() end },
      { key = "T", label = "T:retest", fn = function() end },
      { key = "W", label = "W:watch", fn = function() end } } })
  local text = visible_footer(); hints(text)
  for _, label in ipairs({ "D:delete", "!:write", "M:mask", "T:retest", "W:watch" }) do
    assert(text:find(label, 1, true), label .. " hidden")
  end
end)
test("long lists keep hints visible while selecting the actual last item", function()
  local items = {}; for i = 1, 50 do items[i] = string.format("row %02d", i) end
  local selected
  picker.open({ title = "Many tables", items = items, on_select = function(item) selected = item end })
  hints(visible_footer())
  for _ = 1, 49 do press("j") end
  local text = visible_footer(); hints(text); assert(text:find("row 50", 1, true))
  press("<CR>"); vim.wait(20, function() return selected ~= nil end)
  assert(selected == "row 50", "viewport changed selection identity")
end)
test("filtering to zero results keeps discoverable escape controls", function()
  local input = ui.input; ui.input = function() return "absent" end
  picker.open({ title = "Filtered", items = { "one", "two" } })
  press("/"); ui.input = input
  local text = visible_footer(); hints(text); assert(text:find("(no items)", 1, true))
  press("F"); hints(visible_footer())
end)
test("long filter stays on one display row without hiding key hints", function()
  local input = ui.input; ui.input = function() return string.rep("資料_table_filter_", 8) end
  picker.open({ title = "Filtered", items = { "one", "two" } })
  press("/"); ui.input = input
  local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  assert(vim.fn.strdisplaywidth(first) <= vim.api.nvim_win_get_width(0), "filter indicator wraps")
  local text = visible_footer(); hints(text); assert(text:find("(no items)", 1, true))
  press("F"); hints(visible_footer())
end)
print(string.format("picker_visibility_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
