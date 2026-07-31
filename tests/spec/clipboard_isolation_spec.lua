-- clipboard_isolation_spec.lua: the harness must never reach the OS clipboard.
--
-- Several keymaps copy to the "+" register on purpose -- json_tree's gy
-- (JSONPath), the sidebar yank, the grid exports -- and specs drive those
-- keymaps through feedkeys. With Neovim's real provider that shells out to
-- pbcopy/xclip, so a plain `just test` replaced whatever the developer had
-- copied: json_tree_spec's gy assertion left "$.nested.deep" on the macOS
-- clipboard on every run, which then landed in the next paste.
--
-- Nothing inside nvim notices that, hence this spec. It pins the three
-- properties the in-memory provider in tests/minimal_init.lua has to hold:
-- it is in-process, it still round-trips so the "+"-asserting specs keep
-- passing, and a write to "+" does not leave the process.

local pass = 0
local fail = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, msg)
  assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function truthy(a, msg)
  assert(a, (msg or "") .. ": expected truthy, got " .. tostring(a))
end

--- Reads the real OS clipboard, bypassing Neovim entirely. Returns nil when the
--- platform has no reader on PATH -- the CI runner is a headless ubuntu image
--- with neither xclip nor a wayland socket, so the last test skips there.
--- @return string|nil
local function os_clipboard()
  local readers = {
    { "pbpaste" },                                  -- macOS
    { "xclip", "-selection", "clipboard", "-o" },   -- X11
    { "wl-paste", "--no-newline" },                 -- Wayland
  }
  for _, cmd in ipairs(readers) do
    if vim.fn.executable(cmd[1]) == 1 then
      local out = vim.fn.system(cmd)
      if vim.v.shell_error == 0 then return out end
      return nil -- reader present but unusable (no DISPLAY, no wayland socket)
    end
  end
  return nil
end

-- ── provider shape ───────────────────────────────────────────────────────────

test("harness installs a named in-memory clipboard provider", function()
  local cb = vim.g.clipboard
  truthy(cb, "tests/minimal_init.lua sets vim.g.clipboard")
  eq(cb.name, "grip-tests-in-memory", "provider name")
end)

test("provider handlers are Lua functions, not shell commands", function()
  local cb = vim.g.clipboard
  for _, reg in ipairs({ "+", "*" }) do
    -- A provider may also be declared as an argv table (e.g. { "pbcopy" }).
    -- That is exactly the shape that would leave the process, so assert the
    -- handlers are callables rather than merely non-nil.
    eq(type(cb.copy[reg]), "function", "copy handler for " .. reg)
    eq(type(cb.paste[reg]), "function", "paste handler for " .. reg)
  end
end)

-- ── still behaves like a clipboard ───────────────────────────────────────────

test("setreg/getreg round-trip through the provider", function()
  for _, reg in ipairs({ "+", "*" }) do
    vim.fn.setreg(reg, "round-trip via " .. reg)
    eq(vim.fn.getreg(reg), "round-trip via " .. reg, "round-trip for " .. reg)
  end
end)

-- Per-selection slots, the X11 model. macOS backs both registers with the one
-- pasteboard, but no plugin code writes to "*", so the harness picks the shape
-- that catches an implementation aliasing the two handlers onto one slot.
test("the two selection registers stay independent", function()
  vim.fn.setreg("+", "plus value")
  vim.fn.setreg("*", "star value")
  eq(vim.fn.getreg("+"), "plus value", "+ unaffected by a * write")
  eq(vim.fn.getreg("*"), "star value", "* holds its own value")
end)

test("linewise yanks keep their regtype", function()
  vim.fn.setreg("+", { "one", "two" }, "l")
  eq(vim.fn.getreg("+"), "one\ntwo\n", "linewise text")
  eq(vim.fn.getregtype("+"), "V", "linewise regtype survives the round-trip")
end)

-- ── the actual regression ────────────────────────────────────────────────────

test("a write to \"+\" does not reach the OS clipboard", function()
  local before = os_clipboard()
  if before == nil then
    print("clipboard_isolation_spec: SKIPPED os-clipboard check (no reader on PATH)")
    return
  end
  -- Asserted against the sentinel rather than against `before`, so a copy made
  -- by another app while this spec runs cannot flake it. If the provider ever
  -- shells out again, the sentinel is what shows up.
  local sentinel = "grip-clipboard-isolation-sentinel"
  vim.fn.setreg("+", sentinel)
  local after = os_clipboard()
  truthy(after ~= nil, "os clipboard still readable after the write")
  truthy(not vim.startswith(after, sentinel), "sentinel must not escape to the OS clipboard")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nclipboard_isolation_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
