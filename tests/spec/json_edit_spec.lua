-- Drive the real float and split editors against a disposable SQLite fixture.
-- Decoding for syntax detection must never replace the text that gets staged.
local grip = require("dadbod-grip")
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")
local cell_buffer = require("dadbod-grip.cell_buffer")
local paths = require("dadbod-grip.paths")

local pass, fail = 0, 0
local original_opts = grip.get_opts()
local original_root = paths.project_root
local original_notify = vim.notify
local fixture = vim.fn.tempname() .. "_json_edit"
vim.fn.mkdir(fixture, "p")
paths.project_root = function() return fixture end
vim.notify = function() end
grip.setup({})

local samples = {
  '{"z":12345678901234567890,"safe":9007199254740993,"a":1.2300,"exp":1.00e+02,"flag":false}',
  '[\n {"z":-9223372036854775809,"a":1.2300,"flag":false},\n null, true, []\n]',
  ' \n\t{"z":1,"z":2, "escaped":"\\u0041", "a":9007199254740993,"flag":false}\t \n',
}
local invalid = '{"z":12345678901234567890,"flag":false,}'

local function quote(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local seed = { "CREATE TABLE docs (id INTEGER PRIMARY KEY, payload TEXT, notes TEXT);" }
for i, raw in ipairs(samples) do
  seed[#seed + 1] = "INSERT INTO docs VALUES (" .. i .. "," .. quote(raw) .. ",'unchanged');"
end
seed[#seed + 1] = "INSERT INTO docs VALUES (4," .. quote(invalid) .. ",'unchanged');"
seed[#seed + 1] = "INSERT INTO docs VALUES (5,NULL,'unchanged');"
local db_file = fixture .. "/docs.db"
vim.fn.system({ "sqlite3", db_file }, table.concat(seed, "\n"))
assert(vim.v.shell_error == 0, "could not create JSON editor fixture")

local function eq(actual, expected, message)
  assert(actual == expected, (message or "") .. ": expected "
    .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function invoke(buf, key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == key then
      assert(type(mapping.callback) == "function", "expected callback for " .. key)
      mapping.callback()
      return
    end
  end
  error("missing keymap " .. key)
end

local function cleanup()
  vim.cmd("stopinsert")
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    local wins = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_win_close(wins[#wins], true)
  end
  local buffers = {}
  for buf in pairs(view._sessions) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do
    view._sessions[buf] = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  vim.wait(10, function() return false end, 1)
end

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  cleanup()
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function open_grid(id, column)
  grip.open("SELECT id, payload, notes FROM docs WHERE id = " .. id,
    "sqlite:" .. db_file, { from_pad = true })
  local buf, session = next(view._sessions)
  assert(buf and session, "expected fixture grid")
  local render = session._render
  vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf),
    { render.data_start, render.byte_positions[1][column or "payload"].start })
  return buf, session
end

local function open_editor(surface, grid)
  if surface == "float" then
    invoke(grid, "<CR>")
    local buf = vim.api.nvim_get_current_buf()
    assert(buf ~= grid, "expected cell float")
    return buf
  end
  return assert(cell_buffer.open(grid), "expected cell split")
end

local function save(surface, buf)
  if surface == "float" then invoke(buf, "<CR>") else vim.cmd("write") end
end

for _, surface in ipairs({ "float", "split" }) do
  for id, raw in ipairs(samples) do
    test(surface .. ": JSON " .. id .. " opens and saves byte-for-byte", function()
      local grid, session = open_grid(id)
      local buf = open_editor(surface, grid)
      eq(text(buf), raw, "editor pre-fill")
      eq(vim.bo[buf].filetype, "json", "JSON highlighting")
      save(surface, buf)
      eq(data.has_changes(session.state), false, "no-op save stages nothing")
      eq(data.effective_value(session.state, 1, "payload"), raw, "stored text")
    end)

    test(surface .. ": JSON " .. id .. " preserves text outside an edited field", function()
      local grid, session = open_grid(id)
      local buf = open_editor(surface, grid)
      local edited, count = text(buf):gsub('"flag"%s*:%s*false', '"flag":true', 1)
      eq(count, 1, "changed only the flag field")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(edited, "\n", { plain = true }))
      save(surface, buf)
      eq(data.effective_value(session.state, 1, "payload"),
        (raw:gsub('"flag":false', '"flag":true', 1)), "all other JSON bytes survive")
      eq(data.has_changes(session.state), true, "explicit edit staged")
    end)
  end

  test(surface .. ": editing a different column leaves JSON untouched", function()
    local grid, session = open_grid(1, "notes")
    local buf = open_editor(surface, grid)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed note" })
    save(surface, buf)
    eq(data.effective_value(session.state, 1, "notes"), "changed note", "note staged")
    eq(data.effective_value(session.state, 1, "payload"), samples[1], "JSON unchanged")
  end)

  test(surface .. ": invalid JSON opens unchanged and stages explicit text edits", function()
    local grid, session = open_grid(4)
    local buf = open_editor(surface, grid)
    eq(text(buf), invalid, "invalid JSON preserved")
    eq(vim.bo[buf].filetype, "", "invalid JSON stays plain")
    local edited = invalid:gsub('"flag":false', '"flag":true')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { edited })
    save(surface, buf)
    eq(data.effective_value(session.state, 1, "payload"), edited, "no coercion")
  end)

  test(surface .. ": NULL no-op stays NULL", function()
    local grid, session = open_grid(5)
    local buf = open_editor(surface, grid)
    eq(text(buf), "", "NULL opens empty")
    eq(vim.bo[buf].filetype, "", "NULL has no JSON filetype")
    save(surface, buf)
    eq(data.has_changes(session.state), false, "no change to NULL")
    eq(data.effective_value(session.state, 1, "payload"), nil, "still NULL")
  end)

  test(surface .. ": clearing a JSON cell stages empty text", function()
    local grid, session = open_grid(1)
    local buf = open_editor(surface, grid)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    save(surface, buf)
    eq(data.has_changes(session.state), true, "empty text staged")
    eq(data.effective_value(session.state, 1, "payload"), "", "empty text")
  end)

  test(surface .. ": cancel leaves the original JSON untouched", function()
    local grid, session = open_grid(1)
    local buf = open_editor(surface, grid)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "discard this" })
    if surface == "float" then invoke(buf, "q") else vim.cmd("quit!") end
    eq(data.has_changes(session.state), false, "cancel stages nothing")
    eq(data.effective_value(session.state, 1, "payload"), samples[1], "JSON unchanged")
  end)

  test(surface .. ": read-only grids preserve JSON and cannot edit it", function()
    local grid, session = open_grid(1)
    session.state.readonly = true
    if surface == "float" then
      local windows = #vim.api.nvim_list_wins()
      invoke(grid, "<CR>")
      eq(vim.api.nvim_get_current_buf(), grid, "editor refused")
      eq(#vim.api.nvim_list_wins(), windows, "no editor window")
    else
      local buf = open_editor(surface, grid)
      eq(text(buf), samples[1], "read-only JSON preserved")
      eq(vim.bo[buf].filetype, "json", "JSON highlighting")
      eq(vim.bo[buf].modifiable, false, "view cannot modify text")
      eq(vim.bo[buf].readonly, true, "view is read-only")
      eq(#vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = buf }), 0,
        "view cannot stage writes")
    end
    eq(data.has_changes(session.state), false, "no read-only changes")
  end)
end

cleanup()
paths.project_root = original_root
vim.notify = original_notify
grip.setup(original_opts)
vim.fn.delete(fixture, "rf")
print(string.format("json_edit_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
