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

print("test_harness_spec: 2 passed, 0 failed")
