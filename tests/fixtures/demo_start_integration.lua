local root = assert(vim.env.GRIP_REPO_ROOT, "GRIP_REPO_ROOT is required")
local db = require("dadbod-grip.db")
local grip = require("dadbod-grip")
local query_pad = require("dadbod-grip.query_pad")
local schema = require("dadbod-grip.schema")

local project_supplier = vim.fn.getcwd() .. "/.grip/supplier_intel.db"
vim.fn.mkdir(vim.fn.fnamemodify(project_supplier, ":h"), "p")
vim.fn.writefile({ "user-owned sentinel" }, project_supplier)

grip.setup({})
vim.cmd("GripStart")
assert(vim.wait(10000, function()
  return schema.is_open() and query_pad.get_pad_bufnr() and vim.g.db
end, 10), "GripStart did not open the complete workspace")

local url = vim.g.db
local full = url:match("^duckdb:") ~= nil
if vim.env.GRIP_REQUIRE_DUCKDB == "1" then assert(full, "GripStart did not prefer DuckDB") end

local counts = assert(db.query(table.concat({
  "SELECT",
  "(SELECT COUNT(*) FROM rolls) AS rolls,",
  "(SELECT COUNT(*) FROM suspicious_persons) AS people,",
  "(SELECT COUNT(*) FROM youtube_comments) AS comments,",
  "(SELECT COUNT(*) FROM youtube_comments WHERE conspiracy_adjacent IS NULL) AS unreviewed",
}, " "), url))
local expected = full and { 505, 200, 500, 193 } or { 35, 10, 15, 2 }
for index, value in ipairs(expected) do
  assert(tonumber(counts.rows[1][index]) == value, vim.inspect(counts.rows))
end

local pad = assert(query_pad.get_pad_bufnr())
local notebook = table.concat(vim.api.nvim_buf_get_lines(pad, 0, -1, false), "\n")
assert(notebook:find("Softrear Inc. Internal Operations Analysis", 1, true),
  "GripStart did not load the investigation notebook")

local blocks, current = {}, nil
for _, line in ipairs(vim.fn.readfile(root .. "/demo/softrear-internal.md")) do
  if line == "```sql" then
    current = {}
  elseif line == "```" and current then
    blocks[#blocks + 1] = table.concat(current, "\n")
    current = nil
  elseif current then
    current[#current + 1] = line
  end
end

local limit = full and #blocks or 12
for index = 1, limit do
  local result, err = db.query(blocks[index], url)
  assert(result and #result.rows > 0, string.format("notebook SQL block %d failed: %s", index, err or "empty"))
end

if full and vim.fn.executable("sqlite3") == 1 then
  local attachments = require("dadbod-grip.adapters.duckdb").get_attachments(url)
  assert(#attachments == 1 and attachments[1].alias == "supplier", vim.inspect(attachments))
end

assert(vim.deep_equal(vim.fn.readfile(project_supplier), { "user-owned sentinel" }),
  "GripStart changed the current project's supplier database")
vim.cmd("qall!")
