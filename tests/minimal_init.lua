-- Minimal init for headless testing: loads plugin from repo root
vim.opt.rtp:prepend(".")
vim.g.grip_test_progpath = vim.v.progpath
-- Shared spec assertions live in tests/helpers.lua and are pulled in with
-- require("helpers"). The directory is resolved from this file's own path, so
-- the name works no matter which cwd nvim was launched from.
package.path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/?.lua;" .. package.path

if vim.env.GRIP_COVERAGE == "1" and not vim.g.grip_test_coverage_started then
  vim.g.grip_test_coverage_started = true
  local ok, err = pcall(require, "luacov")
  if not ok then error("GRIP_COVERAGE=1 but LuaCov could not start: " .. tostring(err)) end
end

-- Neovim reports scheduled callback errors without making the headless process
-- fail. That can turn a real async regression into "ALL TESTS PASSED". Install
-- this once because a few focused specs source minimal_init.lua themselves.
if not vim.g.grip_test_schedule_guard then
  vim.g.grip_test_schedule_guard = true
  local schedule = vim.schedule
  vim.schedule = function(callback)
    schedule(function()
      local ok, err = xpcall(callback, debug.traceback)
      if not ok then
        vim.api.nvim_err_writeln(err)
        vim.cmd("cquit 1")
      end
    end)
  end
end

-- An in-memory clipboard, so a test run cannot touch the developer's real one.
--
-- Copying to "+" is a deliberate feature of several keymaps -- json_tree's gy
-- (JSONPath), the sidebar yank, the grid exports -- and specs drive them through
-- feedkeys. Neovim's own provider shells out to pbcopy/xclip, so those specs
-- replaced whatever was on the system clipboard: json_tree_spec's gy assertion
-- left "$.nested.deep" there on every run, to surface in the developer's next
-- paste. Registers are kept per-selection rather than aliased, and the paste
-- handlers are wired up (cache_enabled = 0) so getreg("+") keeps reporting what
-- the plugin wrote and the assertions on it stay meaningful.
-- Guarded by tests/spec/clipboard_isolation_spec.lua.
local selections = { ["+"] = { { "" }, "v" }, ["*"] = { { "" }, "v" } }
local function copy_to(reg)
  return function(lines, regtype) selections[reg] = { lines, regtype } end
end
local function paste_from(reg)
  return function() return selections[reg][1], selections[reg][2] end
end
vim.g.clipboard = {
  name = "grip-tests-in-memory",
  copy = { ["+"] = copy_to("+"), ["*"] = copy_to("*") },
  paste = { ["+"] = paste_from("+"), ["*"] = paste_from("*") },
  cache_enabled = 0,
}

-- Do not call setup() for pure module tests
