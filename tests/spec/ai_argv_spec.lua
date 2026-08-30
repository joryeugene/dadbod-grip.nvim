-- ai_argv_spec.lua: provider credentials and request content must never enter argv.
local ai = require("dadbod-grip.ai")
local db = require("dadbod-grip.db")

if vim.uv.os_uname().sysname ~= "Linux" then
  print("SKIP: ai_argv_spec (/proc cmdline inspection requires Linux)")
  return
end

local dir = vim.fn.tempname() .. "_ai_argv"
local executable = dir .. "/curl"
vim.fn.mkdir(dir, "p")
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s' \"$$\" > \"$GRIP_AI_PID_FILE\"",
  "cat > \"$GRIP_AI_STDIN_FILE\"",
  ": > \"$GRIP_AI_READY_FILE\"",
  "while [ ! -f \"$GRIP_AI_RELEASE_FILE\" ]; do sleep 0.02; done",
  "if grep -q '/v1/messages' \"$GRIP_AI_STDIN_FILE\"; then",
  "  printf '%s\\n' '{\"content\":[{\"text\":\"SELECT 1\"}]}'",
  "elif grep -q '/v1/chat/completions' \"$GRIP_AI_STDIN_FILE\"; then",
  "  printf '%s\\n' '{\"choices\":[{\"message\":{\"content\":\"SELECT 1\"}}]}'",
  "elif grep -q ':generateContent' \"$GRIP_AI_STDIN_FILE\"; then",
  "  printf '%s\\n' '{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"SELECT 1\"}]}}]}'",
  "else",
  "  printf '%s\\n' '{\"message\":{\"content\":\"SELECT 1\"}}'",
  "fi",
}, executable)
assert(vim.fn.setfperm(executable, "rwx------") == 1, "could not create fake curl")

local old_env = {
  path = vim.env.PATH,
  pid = vim.env.GRIP_AI_PID_FILE,
  stdin = vim.env.GRIP_AI_STDIN_FILE,
  ready = vim.env.GRIP_AI_READY_FILE,
  release = vim.env.GRIP_AI_RELEASE_FILE,
}
local old_path = old_env.path
vim.env.PATH = dir .. ":" .. (old_path or "")

local real = {
  list_tables = db.list_tables,
  get_schema_batch = db.get_schema_batch,
  get_primary_keys = db.get_primary_keys,
  get_foreign_keys = db.get_foreign_keys,
  notify = vim.notify,
}
local provider
db.list_tables = function() return { { name = "private_table" } } end
db.get_schema_batch = function()
  return {
    private_table = {
      { column_name = "schema_secret_" .. provider, data_type = "text", is_nullable = "NO" },
    },
  }
end
db.get_primary_keys = function() return {} end
db.get_foreign_keys = function() return {} end
vim.notify = function() end

local release_files, pids = {}, {}
local ok, err = xpcall(function()
  for _, name in ipairs({ "anthropic", "openai", "gemini", "ollama" }) do
    provider = name
    local prefix = dir .. "/" .. name
    local pid_file = prefix .. ".pid"
    local stdin_file = prefix .. ".stdin"
    local ready_file = prefix .. ".ready"
    local release_file = prefix .. ".release"
    release_files[#release_files + 1] = release_file
    vim.env.GRIP_AI_PID_FILE = pid_file
    vim.env.GRIP_AI_STDIN_FILE = stdin_file
    vim.env.GRIP_AI_READY_FILE = ready_file
    vim.env.GRIP_AI_RELEASE_FILE = release_file

    local key = name == "ollama" and "" or ("api_key_secret_" .. name)
    local question = "prompt_secret_" .. name
    local existing_sql = "SELECT 'existing_sql_secret_" .. name .. "'"
    local callback_done, callback_err = false, nil
    ai.setup({ provider = name, api_key = key, model = "model-" .. name })
    ai.generate_sql(question, "test://argv-" .. name, function(_, cb_err)
      callback_done, callback_err = true, cb_err
    end, existing_sql)

    assert(vim.wait(3000, function() return vim.fn.filereadable(ready_file) == 1 end, 1),
      "fake curl did not reach the process-inspection barrier for " .. name)
    local pid = assert(vim.fn.readfile(pid_file)[1], "fake curl did not record its pid")
    pids[#pids + 1] = pid
    local cmdline_file = assert(io.open("/proc/" .. pid .. "/cmdline", "rb"))
    local cmdline = cmdline_file:read("*a")
    cmdline_file:close()

    for _, forbidden in ipairs({
      key, question, "schema_secret_" .. name, existing_sql,
      "api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com",
      "localhost:11434", "Content-Type: application/json",
    }) do
      if forbidden ~= "" then
        assert(not cmdline:find(forbidden, 1, true),
          string.format("curl argv exposed %q for %s: %s", forbidden, name, cmdline:gsub("%z", " ")))
      end
    end

    local stdin = table.concat(vim.fn.readfile(stdin_file), "\n")
    assert(stdin:find(question, 1, true), "prompt missing from curl stdin for " .. name)
    assert(stdin:find("schema_secret_" .. name, 1, true), "schema missing from curl stdin for " .. name)
    assert(stdin:find("existing_sql_secret_" .. name, 1, true), "existing SQL missing from curl stdin for " .. name)
    if key ~= "" then assert(stdin:find(key, 1, true), "API key missing from curl stdin for " .. name) end

    vim.fn.writefile({ "release" }, release_file)
    assert(vim.wait(3000, function() return callback_done end, 1), "AI callback never fired for " .. name)
    assert(callback_err == nil, tostring(callback_err))
  end
end, debug.traceback)

for _, release_file in ipairs(release_files) do
  if vim.fn.filereadable(release_file) == 0 then vim.fn.writefile({ "release" }, release_file) end
end
vim.wait(3000, function()
  for _, pid in ipairs(pids) do
    if vim.fn.filereadable("/proc/" .. pid .. "/cmdline") == 1 then return false end
  end
  return true
end, 1)
ai.setup({})
db.list_tables = real.list_tables
db.get_schema_batch = real.get_schema_batch
db.get_primary_keys = real.get_primary_keys
db.get_foreign_keys = real.get_foreign_keys
vim.notify = real.notify
vim.env.PATH = old_env.path
vim.env.GRIP_AI_PID_FILE = old_env.pid
vim.env.GRIP_AI_STDIN_FILE = old_env.stdin
vim.env.GRIP_AI_READY_FILE = old_env.ready
vim.env.GRIP_AI_RELEASE_FILE = old_env.release
vim.fn.delete(dir, "rf")

if not ok then error(err, 0) end
print("ai_argv_spec: 4 passed, 0 failed")
