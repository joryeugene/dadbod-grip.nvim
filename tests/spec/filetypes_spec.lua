local filetypes = require("dadbod-grip.filetypes")

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

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected),
    "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

test("registry lists every supported file format", function()
  eq(filetypes.extensions, {
    ".parquet", ".csv", ".tsv", ".json", ".ndjson",
    ".jsonl", ".xlsx", ".orc", ".arrow", ".ipc",
  })
end)

test("every registry extension is recognized", function()
  for _, ext in ipairs(filetypes.extensions) do
    assert(filetypes.has_supported_extension("/tmp/data" .. ext), ext)
  end
end)

test("matching ignores case, URL queries, and fragments", function()
  eq(filetypes.has_supported_extension("https://example.test/DATA.ORC?token=x#row=2"), true)
end)

test("unsupported and malformed values are rejected", function()
  eq(filetypes.has_supported_extension("/tmp/data.txt"), false)
  eq(filetypes.has_supported_extension(nil), false)
  eq(filetypes.has_supported_extension({}), false)
end)

test("write formats are explicit and never fall back to CSV", function()
  eq(filetypes.write_format("/tmp/data.parquet"), "PARQUET")
  eq(filetypes.write_format("/tmp/data.tsv"), "CSV")
  eq(filetypes.write_format("/tmp/data.jsonl"), "JSON")
  eq(filetypes.write_format("/tmp/data.ipc"), "ARROW")
  eq(filetypes.write_format("/tmp/data.xlsx"), nil)
  eq(filetypes.write_format("/tmp/data.orc"), nil)
  eq(filetypes.write_format("https://example.test/data.csv"), nil)
  eq(filetypes.write_format("s3://bucket/data.parquet"), nil)
end)

print(string.format("\nfiletypes_spec: %d passed, %d failed", pass, fail))
if fail > 0 then vim.cmd("cquit 1") end
