local result = vim.system({
  vim.g.grip_test_progpath,
  "--headless",
  "-u", "tests/minimal_init.lua",
  "-l", "tests/fixtures/schedule_failure.lua",
}, { text = true }):wait()

assert(result.code ~= 0, "a scheduled callback failure must make Neovim exit nonzero")
assert(
  ((result.stdout or "") .. (result.stderr or "")):find(
    "intentional scheduled callback failure", 1, true
  ),
  "the scheduled callback traceback must remain visible"
)

for _, path in ipairs(vim.fn.glob("tests/**/*.lua", false, true)) do
  for line_number, source in ipairs(vim.fn.readfile(path)) do
    for _, option in ipairs({ "columns", "lines" }) do
      local _, equals = source:find("vim%.o%." .. option .. "%s*=")
      local is_assignment = equals and source:sub(equals + 1, equals + 1) ~= "="
      assert(not is_assignment,
        string.format("%s:%d assigns display geometry inside a headless test", path, line_number))
    end
  end
end

print("test_harness_spec: 3 passed, 0 failed")
