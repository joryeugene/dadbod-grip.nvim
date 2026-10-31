-- Lossless cell transports: strings remain strings; SQL NULL is vim.NIL.
local M = {}
local function entity_decode(s)
  return (s:gsub('&([^;]+);', function(entity)
    local known = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'" }
    if known[entity] then return known[entity] end
    local n = entity:match('^#x(%x+)$')
    n = n and tonumber(n, 16) or tonumber(entity:match('^#(%d+)$'))
    assert(n and n >= 0 and n <= 0x10ffff, 'invalid XML entity')
    if n == 0 then return '\0' end
    return vim.fn.nr2char(n)
  end))
end

-- mysql --xml marks NULL with xsi:nil, independently of text such as 'NULL'.
-- No DTD/entity expansion, numeric decoding, or whitespace normalization.
function M.mysql_xml(raw)
  if not raw or raw == '' then return { columns = {}, rows = {} } end
  if raw:find('<!DOCTYPE', 1, true) or not raw:find('<resultset', 1, true) then
    return nil, 'invalid typed MySQL result'
  end
  local ok, result = pcall(function()
    local columns, rows = {}, {}
    for body in raw:gmatch('<row>(.-)</row>') do
      local row, names, pos = {}, {}, 1
      while true do
        local start, stop, attrs = body:find('<field%s+([^>]-)>', pos)
        if not start then break end
        local name = attrs:match('name="(.-)"')
        assert(name, 'missing MySQL field name')
        names[#names + 1] = entity_decode(name)
        if attrs:match('/%s*$') then
          assert(attrs:match('xsi:nil="true"'), 'unknown self-closing MySQL field')
          row[#row + 1] = vim.NIL
          pos = stop + 1
        else
          local close, finish = body:find('</field>', stop + 1, true)
          assert(close, 'unterminated MySQL field')
          row[#row + 1] = entity_decode(body:sub(stop + 1, close - 1))
          pos = finish + 1
        end
      end
      assert(#row > 0, 'empty MySQL row')
      if #columns == 0 then columns = names end
      assert(vim.deep_equal(columns, names), 'inconsistent MySQL columns')
      rows[#rows + 1] = row
    end
    return { columns = columns, rows = rows }
  end)
  if not ok then return nil, 'invalid typed MySQL result: ' .. tostring(result) end
  return result
end

function M.duckdb_values(parsed)
  for _, row in ipairs(parsed.rows) do
    for i, value in ipairs(row) do
      if value == 'N' then row[i] = vim.NIL
      elseif value:sub(1, 1) == 'V' then row[i] = value:sub(2)
      else return nil, 'invalid typed DuckDB cell' end
    end
  end
  return parsed
end

local function unhex(hex)
  assert(type(hex) == 'string' and #hex % 2 == 0 and hex:match('^%x*$'), 'invalid hex cell')
  return (hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
end
M.unhex = unhex
function M.hex(value)
  return (value:gsub('.', function(ch) return string.format('%02X', ch:byte()) end))
end

function M.sqlite_values(parsed)
  local types, exact = {}, {}
  local names = { I = 'integer', R = 'real', T = 'text', B = 'blob', N = 'null' }
  local ok, err = pcall(function()
    for ri, row in ipairs(parsed.rows) do
      types[ri], exact[ri] = {}, {}
      for ci, value in ipairs(row) do
        local tag, body = value:sub(1, 1), value:sub(2)
        assert(names[tag], 'invalid typed SQLite cell')
        types[ri][ci] = names[tag]
        if tag == 'N' then assert(body == ''); row[ci] = vim.NIL
        elseif tag == 'R' then
          local display, precise = body:match('^(%x*):(%x*)$')
          row[ci], exact[ri][ci] = unhex(display), unhex(precise)
        else row[ci] = unhex(body) end
      end
    end
  end)
  if not ok then return nil, tostring(err) end
  parsed.cell_types, parsed.cell_exact = types, exact
  return parsed
end

-- A race-safe private directory and pre-created 0600 file. Cleanup uses only
-- libuv, so the child's completion callback can run it after pipes are reaped.
function M.private_script()
  local dir, err = vim.uv.fs_mkdtemp(vim.fn.tempname() .. '_grip_read_XXXXXX')
  if not dir then return nil, nil, err end
  local path = dir .. '/read.sql'
  local fd, open_err = vim.uv.fs_open(path, 'wx', 384)
  if not fd then vim.uv.fs_rmdir(dir); return nil, nil, open_err end
  vim.uv.fs_close(fd)
  local function cleanup() vim.uv.fs_unlink(path); vim.uv.fs_rmdir(dir) end
  return path, cleanup
end

function M.cli_path(path)
  assert(not path:find('[\r\n]'), 'unsupported temporary path')
  return '"' .. path:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

return M
