-- globals_spec.lua: no module may read or write an undeclared global.
--
-- Guards a whole class of bug that only surfaces at runtime, on the one code
-- path that touches it: a refactor swaps `vim.fn.input` for `ui.input` but
-- forgets `local ui = require("dadbod-grip.ui")` at the top of the file. Lua
-- happily compiles `ui.input(...)` as a global read, so nothing complains
-- until a user opens that prompt and gets "attempt to index global 'ui'".
-- (Exactly what shipped in v3.8.0 for connections.lua's new-connection prompt.)
--
-- Every lua/ file is compiled and its bytecode walked for GGET/GSET — global
-- reads and writes — including inside nested functions, which is the whole
-- point: a plain `grep` cannot tell `ui.input` from a local `ui`.
--
-- Uses jit.util only (a builtin C module). jit.bc/jit.vmdef are Lua files
-- resolved through the LuaJIT build prefix, which does not exist on the CI
-- runners, so opcode numbers are calibrated here from a throwaway chunk.
dofile("tests/minimal_init.lua")

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then pass = pass + 1
  else fail = fail + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

-- Globals the plugin is allowed to touch: Lua/LuaJIT stdlib, Neovim's `vim`,
-- and globals owned by optional third-party plugins we integrate with.
local allowed = {}
for _, name in ipairs({
  "vim",
  "assert", "collectgarbage", "dofile", "error", "getfenv", "getmetatable",
  "ipairs", "load", "loadfile", "loadstring", "module", "next", "pairs",
  "pcall", "print", "rawequal", "rawget", "rawlen", "rawset", "require",
  "select", "setfenv", "setmetatable", "tonumber", "tostring", "type",
  "unpack", "xpcall", "_G", "_VERSION",
  "bit", "coroutine", "debug", "io", "jit", "math", "os", "package",
  "string", "table",
  "Snacks", -- folke/snacks.nvim, probed by pickers/snacks.lua
}) do
  allowed[name] = true
end

local util = require("jit.util")

local function opcode(ins) return bit.band(ins, 0xff) end
-- `return zzz` compiles to GGET, RET1; `zzz = 1` to KSHORT, GSET, RET0.
local GGET = opcode(util.funcbc(loadstring("return zzz"), 1))
local GSET = opcode(util.funcbc(loadstring("zzz = 1"), 2))

--- Collect every global name touched by `f` and its nested functions.
--- @param f function|userdata  a function or a proto
--- @param found table          name -> first line it appears on
local function collect_globals(f, found)
  local info = util.funcinfo(f)
  local pc = 0 -- pc 0 is the FUNCF/FUNCV header; funcbc returns nil past the end
  while true do
    local ins = util.funcbc(f, pc)
    if ins == nil then break end
    local op = opcode(ins)
    if op == GGET or op == GSET then
      local name = util.funck(f, -1 - bit.rshift(ins, 16))
      if type(name) == "string" and not found[name] then
        found[name] = util.funcinfo(f, pc).currentline
      end
    end
    pc = pc + 1
  end
  if info.children then
    for i = 1, info.gcconsts do
      local k = util.funck(f, -i)
      if type(k) == "proto" then collect_globals(k, found) end
    end
  end
end

local files = {}
for _, pattern in ipairs({ "lua/dadbod-grip/**/*.lua", "plugin/*.lua", "lazy.lua" }) do
  vim.list_extend(files, vim.fn.glob(vim.fn.fnamemodify(pattern, ":p"), false, true))
end
table.sort(files)

test("the plugin has files to scan", function()
  assert(#files > 20, "expected the whole plugin, globbed " .. #files .. " file(s)")
end)

local offenders = {}
for _, path in ipairs(files) do
  local short = vim.fn.fnamemodify(path, ":.")
  local chunk, err = loadfile(path)
  if not chunk then
    offenders[#offenders + 1] = short .. ": does not compile: " .. tostring(err)
  else
    local found = {}
    collect_globals(chunk, found)
    local names = {}
    for name in pairs(found) do
      if not allowed[name] then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      offenders[#offenders + 1] = string.format("%s:%d: global '%s'", short, found[name], name)
    end
  end
end

test("no module touches an undeclared global", function()
  assert(#offenders == 0, "\n  " .. table.concat(offenders, "\n  ")
    .. "\n  (add `local x = require(...)`, or whitelist it in this spec if it is"
    .. " genuinely a third-party global)")
end)

-- ── sanity: the scan really does catch a missing require ───────────────────

test("scan detects a global read inside a nested function", function()
  local chunk = assert(loadstring("local function f() return ui.input({}) end return f"))
  local found = {}
  collect_globals(chunk, found)
  assert(found.ui, "expected 'ui' to be reported")
end)

test("scan ignores a properly declared local", function()
  local chunk = assert(loadstring("local ui = {} local function f() return ui.input({}) end return f"))
  local found = {}
  collect_globals(chunk, found)
  assert(not found.ui, "'ui' is a local here, must not be reported")
end)

test("scan detects a global write", function()
  local chunk = assert(loadstring("local function f() leaked = 1 end return f"))
  local found = {}
  collect_globals(chunk, found)
  assert(found.leaked, "expected 'leaked' to be reported")
end)

-- ── summary ───────────────────────────────────────────────────────────────

print(string.format("globals_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
