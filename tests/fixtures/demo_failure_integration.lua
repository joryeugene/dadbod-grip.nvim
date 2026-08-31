local demo = require("dadbod-grip.demo")
local grip = require("dadbod-grip")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

local notices = {}
vim.notify = function(message) notices[#notices + 1] = tostring(message) end

local spec = assert(demo.spec())
assert(spec.kind == "sqlite", "fake SQLite client was not selected")
grip.setup({})
vim.cmd("GripStart")

assert(not vim.g.db, "failed seed switched connections")
assert(not schema.is_open(), "failed seed opened the workspace")
assert(not query_pad.get_pad_bufnr(), "failed seed opened the walkthrough")
assert(vim.fn.getftype(spec.path) == "", "failed seed left a partial demo database")
assert(table.concat(notices, "\n"):find("fake seed failure", 1, true),
  "database client error was not shown")

vim.cmd("qall!")
