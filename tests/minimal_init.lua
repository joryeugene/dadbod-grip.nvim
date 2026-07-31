-- Minimal init for headless testing: loads plugin from repo root
vim.opt.rtp:prepend(".")
-- Shared spec assertions live in tests/helpers.lua and are pulled in with
-- require("helpers"). The directory is resolved from this file's own path, so
-- the name works no matter which cwd nvim was launched from.
package.path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  .. "/?.lua;" .. package.path

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
