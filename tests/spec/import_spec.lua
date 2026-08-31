-- import_spec.lua: clipboard/pipe parsing and staged-insert command contract.

local data = require("dadbod-grip.data")
local db = require("dadbod-grip.db")
local grip = require("dadbod-grip")
local importer = require("dadbod-grip.importer")
local ui = require("dadbod-grip.ui")
local view = require("dadbod-grip.view")
local adapters = require("dadbod-grip.adapters")

local pass, fail = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected),
    (message or "") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local columns = { "id", "name", "email", "active", "profile" }

test("CSV headers map by name and empty cells become explicit NULL", function()
  local parsed = assert(importer.parse("name,email\nAlice,alice@example.com\nBob,\n", columns))
  eq(parsed.format, "CSV")
  eq(parsed.columns, { "name", "email" })
  eq(parsed.rows[1], { name = "Alice", email = "alice@example.com" })
  eq(parsed.rows[2], { name = "Bob", email = data.NULL_SENTINEL })
end)

test("TSV and quoted fields reuse the delimited parser", function()
  local parsed = assert(importer.parse('name\temail\n"Doe, Jane"\tjane@example.com\n', columns))
  eq(parsed.format, "TSV")
  eq(parsed.rows[1], { name = "Doe, Jane", email = "jane@example.com" })
end)

test("JSON objects map in table-column order and preserve null", function()
  local parsed = assert(importer.parse(
    ' [{"email":"a@example.com","name":"Alice","active":true,"profile":{"role":"admin"}},'
      .. '{"name":"Bob","email":null}] ', columns))
  eq(parsed.format, "JSON")
  eq(parsed.columns, { "name", "email", "active", "profile" })
  eq(parsed.rows[1].name, "Alice")
  eq(parsed.rows[1].active, "true")
  eq(vim.json.decode(parsed.rows[1].profile), { role = "admin" })
  eq(parsed.rows[2].email, data.NULL_SENTINEL)
end)

test("a single JSON object imports as one row", function()
  local parsed = assert(importer.parse('\239\187\191{"name":"Alice"}', columns))
  eq(#parsed.rows, 1)
  eq(parsed.rows[1].name, "Alice")
end)

test("unknown, duplicate, oversized, and malformed input is rejected", function()
  local cases = {
    { "unknown CSV column", "wat\nvalue\n", "unknown column" },
    { "duplicate CSV column", "name,name\nA,B\n", "duplicate column" },
    { "too many CSV cells", "name\nA,B\n", "2 fields" },
    { "too few CSV cells", "name,email\nA\n", "1 fields" },
    { "unterminated CSV quote", 'name\n"Alice\n', "unterminated quoted field" },
    { "invalid JSON", '[{"name":]', "invalid JSON" },
    { "non-object JSON row", '["Alice"]', "row 1 must be an object" },
    { "empty input", "  \n", "no rows" },
  }
  for _, case in ipairs(cases) do
    local parsed, err = importer.parse(case[2], columns)
    eq(parsed, nil, case[1])
    assert(tostring(err):find(case[3], 1, true), case[1] .. ": " .. tostring(err))
  end
end)

grip.setup({})

local function with_grid(opts, fn)
  opts = opts or {}
  local previous = vim.api.nvim_get_current_buf()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  local state = data.new({
    rows = { { "1", "Existing", "old@example.com", "1", "" } },
    columns = columns,
    primary_keys = { "id" },
    table_name = "users",
    url = "sqlite:tests/seed_sqlite.db",
  })
  if opts.readonly then state.readonly = true end
  view._sessions[bufnr] = { state = state, url = state.url }

  local real = {
    apply_edit = view.apply_edit,
    confirm = ui.confirm,
    notify = vim.notify,
    run_cmd = adapters.run_cmd,
    execute = db.execute,
    is_readonly = db.is_readonly,
  }
  local notices, prompt, applied, executed = {}, nil, nil, false
  view.apply_edit = function(got_buf, new_state)
    eq(got_buf, bufnr, "target buffer")
    local session = view._sessions[bufnr]
    session._undo_stack = session._undo_stack or {}
    table.insert(session._undo_stack, session.state)
    applied = new_state
    session.state = new_state
  end
  ui.confirm = function(message)
    prompt = message
    return opts.confirm ~= false
  end
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  db.execute = function() executed = true; return nil, "must not execute" end

  local ok, err = pcall(fn, {
    bufnr = bufnr,
    state = state,
    notices = notices,
    prompt = function() return prompt end,
    applied = function() return applied end,
    executed = function() return executed end,
    set_run_cmd = function(replacement) adapters.run_cmd = replacement end,
    set_adapter_readonly = function(value) db.is_readonly = function() return value end end,
    undo_depth = function() return #(view._sessions[bufnr]._undo_stack or {}) end,
  })

  view.apply_edit = real.apply_edit
  ui.confirm = real.confirm
  vim.notify = real.notify
  adapters.run_cmd = real.run_cmd
  db.execute = real.execute
  db.is_readonly = real.is_readonly
  view._sessions[bufnr] = nil
  vim.api.nvim_set_current_buf(previous)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then error(err) end
end

test(":GripImport previews clipboard columns and stages rows without writing", function()
  with_grid({}, function(ctx)
    vim.fn.setreg("+", "name,email\nAlice,a@example.com\nBob,b@example.com\n")
    vim.cmd("GripImport")

    local staged = assert(ctx.applied(), "state was not applied")
    eq(data.count_staged(staged), 2, "two inserts staged")
    eq(data.get_inserts(staged)[1].values.name, "Alice", "source order preserved")
    eq(data.get_inserts(staged)[2].values.name, "Bob", "source order preserved")
    assert(ctx.prompt():find("2 CSV rows", 1, true), "row-count preview missing: " .. ctx.prompt())
    assert(ctx.prompt():find("name, email", 1, true), "column preview missing: " .. ctx.prompt())
    eq(ctx.executed(), false, "import must not write to the database")
    eq(ctx.undo_depth(), 1, "the whole batch must create one undo state")
    assert(ctx.notices[#ctx.notices]:find("staged 2 rows", 1, true), "success notice missing")
  end)
end)

test("invalid sources and adapter read-only mode stage nothing", function()
  with_grid({}, function(ctx)
    vim.cmd("GripImport rows.csv")
    vim.cmd("GripImport !")
    eq(ctx.applied(), nil, "invalid source must not apply")
    local notices = table.concat(ctx.notices, "\n")
    assert(notices:find("use no argument", 1, true), "non-pipe source reason missing")
    assert(notices:find("provide a command", 1, true), "empty pipe reason missing")
  end)

  with_grid({}, function(ctx)
    ctx.set_adapter_readonly(true)
    vim.fn.setreg("+", "name\nBlocked\n")
    vim.cmd("GripImport")
    eq(ctx.applied(), nil, "read-only adapter must not apply")
    assert(ctx.notices[1]:find("adapter is read-only", 1, true), "adapter reason missing")
  end)

  with_grid({}, function(ctx)
    ctx.state.table_name = nil
    vim.fn.setreg("+", "name\nBlocked\n")
    vim.cmd("GripImport")
    eq(ctx.applied(), nil, "non-table grid must not apply")
    assert(ctx.notices[1]:find("editable table grid", 1, true), "non-table reason missing")
  end)
end)

test(":GripImport !command sends producer text through stdin with constant argv", function()
  with_grid({}, function(ctx)
    local captured
    ctx.set_run_cmd(function(args, timeout, opts)
      captured = { args = args, timeout = timeout, stdin = opts.stdin }
      return "name\nPiped\n", "", 0
    end)
    vim.cmd("GripImport !printf pipe_secret_42")
    eq(captured.args, { "sh", "-s" }, "pipe argv")
    eq(captured.stdin, "printf pipe_secret_42\n", "producer command stdin")
    assert(captured.timeout > 0, "configured timeout forwarded")
    eq(data.get_inserts(ctx.applied())[1].values.name, "Piped")
  end)
end)

test("parent shell argv exposes neither producer script nor imported values", function()
  if vim.fn.has("linux") ~= 1 then return end
  with_grid({}, function(ctx)
    local path = vim.fn.tempname()
    local sensitive = "imported_argv_secret_6d92"
    local command = "tr '\\000' '\\n' < /proc/$$/cmdline > " .. vim.fn.shellescape(path)
      .. "; printf 'name\\n" .. sensitive .. "\\n'"
    vim.cmd("GripImport !" .. command)

    local cmdline = table.concat(vim.fn.readfile(path), " ")
    vim.fn.delete(path)
    assert(not cmdline:find(sensitive, 1, true), "imported value leaked into argv: " .. cmdline)
    assert(not cmdline:find("printf", 1, true), "producer command leaked into argv: " .. cmdline)
    eq(data.get_inserts(ctx.applied())[1].values.name, sensitive, "stdout reached the importer")
  end)
end)

test("cancel, malformed input, and read-only grids leave state unchanged", function()
  with_grid({ confirm = false }, function(ctx)
    vim.fn.setreg("+", "name\nCancelled\n")
    vim.cmd("GripImport")
    eq(ctx.applied(), nil, "cancel must not apply")
    eq(data.count_staged(ctx.state), 0, "cancel must not stage")
  end)

  with_grid({}, function(ctx)
    vim.fn.setreg("+", "unknown\nvalue\n")
    vim.cmd("GripImport")
    eq(ctx.applied(), nil, "malformed input must not apply")
    assert(ctx.notices[1]:find("unknown column", 1, true), "parse error missing")
  end)

  with_grid({ readonly = true }, function(ctx)
    vim.fn.setreg("+", "name\nBlocked\n")
    vim.cmd("GripImport")
    eq(ctx.applied(), nil, "read-only import must not apply")
    assert(ctx.notices[1]:find("editable table", 1, true), "read-only reason missing")
  end)
end)

test("pipe failures reveal neither producer text nor stderr", function()
  with_grid({}, function(ctx)
    ctx.set_run_cmd(function()
      return "", "remote_stderr_secret_91", 7
    end)
    vim.cmd("GripImport !printf producer_secret_73")
    eq(ctx.applied(), nil, "failed pipe must not apply")
    local notice = table.concat(ctx.notices, "\n")
    assert(not notice:find("producer_secret_73", 1, true), "producer leaked: " .. notice)
    assert(not notice:find("remote_stderr_secret_91", 1, true), "stderr leaked: " .. notice)
    assert(notice:find("exit 7", 1, true), "exit status missing: " .. notice)
  end)
end)

print(string.format("\nimport_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
