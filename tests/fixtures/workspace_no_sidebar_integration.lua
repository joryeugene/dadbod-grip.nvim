local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

local url = "sqlite:tests/seed_sqlite.db"
grip.setup({ open_sidebar = false })
assert(connections.switch(url, "seed", "sqlite"))

assert(vim.wait(5000, function()
  local pad = query_pad.get_pad_bufnr()
  return pad and vim.api.nvim_buf_is_valid(pad)
    and vim.fn.bufnr("grip://welcome") ~= -1
end, 10), "the main workspace did not finish opening")
assert(not schema.is_open(), "open_sidebar=false unexpectedly opened the schema sidebar")
assert(vim.api.nvim_get_current_buf() == query_pad.get_pad_bufnr(),
  "workspace did not focus the main query pad")

vim.cmd("qall!")
