local grip = require("dadbod-grip")
local connections = require("dadbod-grip.connections")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

local url = "sqlite:tests/seed_sqlite.db"
grip.setup({})
assert(connections.switch(url, "seed", "sqlite"))

assert(vim.wait(5000, function()
  local state = schema.get_state(url)
  local pad = query_pad.get_pad_bufnr()
  return schema.is_open()
    and state.items and #state.items > 0
    and pad and vim.api.nvim_buf_is_valid(pad)
    and vim.fn.bufnr("grip://welcome") ~= -1
end, 10), "the complete workspace did not finish opening")

local schema_buf = vim.fn.bufnr("grip://schema")
local lines = vim.api.nvim_buf_get_lines(schema_buf, 0, -1, false)
assert(table.concat(lines, "\n"):find("users", 1, true), "sidebar opened before it was populated")

vim.cmd("qall!")
