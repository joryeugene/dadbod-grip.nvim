-- conn_color_spec.lua -- a connection saved with "color" tints the accent
-- highlight groups, and a connection without one restores the defaults.
--
-- The assertions read the groups back through nvim_get_hl rather than
-- checking what set_connection_accent was called with: the failure this
-- guards against is a border left red after switching away from a red
-- connection, which only the resolved group can show.
local paths = require("dadbod-grip.paths")
local grip = require("dadbod-grip")

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

local function fg(group)
  return vim.api.nvim_get_hl(0, { name = group }).fg
end

-- GripBorder's definition from before per-connection colour existed. Every
-- "restores the default" assertion is against this number.
local DEFAULT_BORDER = 0xcba6f7

-- ── set_connection_accent ─────────────────────────────────────────────────

test("a palette name sets the accent groups", function()
  local view = require("dadbod-grip.view")
  view.set_connection_accent("red")
  local hl = vim.api.nvim_get_hl(0, { name = "GripConnAccent" })
  assert(hl.fg, "GripConnAccent has a foreground")
  -- The palette is the one already in ensure_highlights: red is GripNegative's.
  eq(hl.fg, 0xf38ba8, "red is the plugin's own red, not a second palette")
  eq(fg("GripConnAccentBold"), 0xf38ba8, "the bold variant follows it")
  eq(vim.api.nvim_get_hl(0, { name = "GripConnAccentBold" }).bold, true, "and is bold")
  eq(fg("GripBorder"), 0xf38ba8, "the border takes the accent too")
end)

test("a palette name is case-insensitive", function()
  local view = require("dadbod-grip.view")
  view.set_connection_accent("Green")
  eq(fg("GripConnAccent"), 0xa6e3a1, "Green resolves like green")
end)

test("every documented palette name resolves", function()
  local view = require("dadbod-grip.view")
  -- doc/dadbod-grip.txt lists exactly these six.
  for _, name in ipairs({ "green", "orange", "red", "blue", "violet", "yellow" }) do
    view.set_connection_accent(name)
    assert(fg("GripConnAccent"), name .. " resolves to a colour")
    if name ~= "violet" then
      assert(fg("GripConnAccent") ~= DEFAULT_BORDER,
        name .. " must not silently fall through to the default")
    end
  end
end)

test("a hex value is accepted", function()
  local view = require("dadbod-grip.view")
  view.set_connection_accent("#00ff00")
  eq(vim.api.nvim_get_hl(0, { name = "GripConnAccent" }).fg, 0x00ff00, "hex honoured")
end)

test("nil restores the default border", function()
  local view = require("dadbod-grip.view")
  view.set_connection_accent("red")
  view.set_connection_accent(nil)
  eq(vim.api.nvim_get_hl(0, { name = "GripBorder" }).fg, 0xcba6f7,
     "border back to its default after leaving a coloured connection")
  eq(fg("GripConnAccent"), DEFAULT_BORDER, "and so are the accent groups")
end)

test("an unknown colour name is ignored rather than raising", function()
  local view = require("dadbod-grip.view")
  local ok = pcall(view.set_connection_accent, "chartreuse-ish")
  eq(ok, true, "no error on a bad value")
  eq(fg("GripBorder"), DEFAULT_BORDER, "and it leaves the default look, not the last colour")
end)

test("a malformed hex is ignored rather than half-applied", function()
  local view = require("dadbod-grip.view")
  for _, bad in ipairs({ "#00ff0", "#gggggg", "00ff00", "#00ff00ff", 42, true }) do
    view.set_connection_accent("red")
    local ok = pcall(view.set_connection_accent, bad)
    eq(ok, true, "no error on " .. tostring(bad))
    eq(fg("GripBorder"), DEFAULT_BORDER, tostring(bad) .. " leaves the default look")
  end
end)

-- ── 256-colour terminals ──────────────────────────────────────────────────
-- Every group in view.lua pairs a gui hex with a ctermfg. An accent without
-- one would simply vanish on a terminal without truecolor.

test("an accent carries a ctermfg", function()
  local view = require("dadbod-grip.view")
  view.set_connection_accent("red")
  eq(vim.api.nvim_get_hl(0, { name = "GripConnAccent" }).ctermfg, 203,
    "the palette's own cterm index, matching GripNegative")
  view.set_connection_accent("#00ff00")
  eq(vim.api.nvim_get_hl(0, { name = "GripConnAccent" }).ctermfg, 46,
    "a user hex is approximated into the xterm cube (#00ff00 = bright green)")
  -- The cube's bottom two levels are 0 and 95, not 0 and 40: both channels
  -- below 115 here, and both would land a level too low on plain division.
  view.set_connection_accent("#3c50ff")
  eq(vim.api.nvim_get_hl(0, { name = "GripConnAccent" }).ctermfg, 63,
    "the cube's uneven low end is honoured")
  view.set_connection_accent(nil)
  eq(vim.api.nvim_get_hl(0, { name = "GripBorder" }).ctermfg, 147,
    "the default's cterm index is unchanged too")
end)

-- The 240 indices above the ANSI 16 are the 6x6x6 cube plus a 24-step grey
-- ramp (8 + 10i). Each case below is the true nearest index, confirmed by
-- brute force against the whole palette; each is also a case an
-- exact-grey-only ramp test would get wrong.
test("a grey resolves to its nearest ramp step, not to the cube", function()
  local view = require("dadbod-grip.view")
  local bad = {}
  for _, case in ipairs({
    { "#808080", 244 },  -- an exact ramp hit: 8 + 10*12
    { "#080808", 232 },  -- the ramp's first step
    { "#ededed", 255 },  -- the last, where the cube's 231 is 30 away
    { "#2f2f30", 236 },  -- grey to within one unit: the cube answers dark blue
    { "#5f5f5f", 59  },  -- an exact *cube* hit, so here the cube must win
  }) do
    view.set_connection_accent(case[1])
    local got = vim.api.nvim_get_hl(0, { name = "GripConnAccent" }).ctermfg
    if got ~= case[2] then
      table.insert(bad, string.format("%s -> %s (want %d)", case[1], tostring(got), case[2]))
    end
  end
  view.set_connection_accent(nil)
  eq(#bad, 0, "every case lands on its true nearest index: " .. table.concat(bad, ", "))
end)

-- ── surviving a :colorscheme ──────────────────────────────────────────────
-- A colorscheme runs `hi clear`, which wipes every group this plugin defines.
-- ensure_highlights re-runs on ColorScheme; the accent has to be re-applied
-- from stored state there, not merely set once when the connection changed.

test("the accent survives a :colorscheme change", function()
  local view = require("dadbod-grip.view")
  local orig_scheme = vim.g.colors_name
  view.set_connection_accent("red")
  vim.cmd("colorscheme blue")
  eq(fg("GripConnAccent"), 0xf38ba8, "accent re-applied after the scheme wiped it")
  eq(fg("GripBorder"), 0xf38ba8, "and the border with it")
  view.set_connection_accent(nil)
  vim.cmd("colorscheme " .. (orig_scheme or "default"))
  eq(fg("GripBorder"), DEFAULT_BORDER, "an uncoloured connection survives it as the default")
end)

-- ── the sidebar title ─────────────────────────────────────────────────────
-- Driven through the real sidebar: the extmark on row 0 carries the group
-- name, so this asserts both that the title takes the accent group and that
-- the group follows the connection colour.

test("the sidebar title is drawn with the accent group", function()
  local view = require("dadbod-grip.view")
  local schema = require("dadbod-grip.schema")
  local db = require("dadbod-grip.db")
  local conns = require("dadbod-grip.connections")

  local orig = { lt = db.list_tables, lr = db.list_routines,
                 cur = conns.current, g_db = vim.g.db }
  db.list_tables   = function() return { { name = "users", type = "table" } } end
  db.list_routines = function() return {} end
  conns.current    = function() return nil end  -- title falls back to the url
  vim.g.db = nil

  local ok, err = pcall(function()
    view.set_connection_accent("red")
    schema.toggle("postgresql://u:p@h/appdb_accent_test")
    local win = schema.get_winid()
    assert(win and vim.api.nvim_win_is_valid(win), "the sidebar opened")
    local buf = vim.api.nvim_win_get_buf(win)
    local ns = vim.api.nvim_create_namespace("grip_schema")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, -1 },
      { details = true })
    assert(#marks > 0, "the title line carries a highlight")
    eq(marks[1][4].hl_group, "GripConnAccentBold", "and it is the accent group")
    eq(fg(marks[1][4].hl_group), 0xf38ba8, "which resolves red on a red connection")
    view.set_connection_accent(nil)
    eq(fg(marks[1][4].hl_group), DEFAULT_BORDER, "and back to the default without one")
  end)

  schema.close()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b)
       and vim.api.nvim_buf_get_name(b):find("grip://schema", 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  db.list_tables, db.list_routines = orig.lt, orig.lr
  conns.current, vim.g.db = orig.cur, orig.g_db
  view.set_connection_accent(nil)
  if not ok then error(err) end
end)

-- ── end to end: switching connections ─────────────────────────────────────
-- The harness is connections_fields_spec.lua's with_real_file, verbatim
-- except for the name -- see that file for why each patch exists. view is
-- deliberately NOT stubbed: the accent it applies is the assertion.

local connections = require("dadbod-grip.connections")

local function with_real_file(fn)
  local project_dir = vim.fn.tempname() .. "_grip_conn_color_test"
  local fake_home = project_dir .. "_home"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(fake_home, "p")

  local orig_project_root = paths.project_root
  local orig_expand = vim.fn.expand
  local orig_notify = vim.notify
  local orig_g_db = vim.g.db
  local orig_opts = grip.get_opts()
  local orig_open = grip.open
  local orig_open_welcome = grip.open_welcome
  local orig_schema = package.loaded["dadbod-grip.schema"]
  local orig_query_pad = package.loaded["dadbod-grip.query_pad"]
  local orig_completion = package.loaded["dadbod-grip.completion"]
  local orig_connections = package.loaded["dadbod-grip.connections"]

  paths.project_root = function() return project_dir end
  vim.fn.expand = function(a, ...)
    if a == "~" then return fake_home end
    return orig_expand(a, ...)
  end
  vim.notify = function() end
  grip.setup({})
  grip.open = function() end
  grip.open_welcome = function() end
  package.loaded["dadbod-grip.schema"] = {
    is_open = function() return true end,
    refresh = function() end,
    toggle = function() end,
    prefetch = function() return {} end,
    get_winid = function() return nil end,
  }
  package.loaded["dadbod-grip.query_pad"] = { open = function() end }
  package.loaded["dadbod-grip.completion"] = { invalidate = function() end, warm_schema = function() end }
  package.loaded["dadbod-grip.connections"] = nil
  connections = require("dadbod-grip.connections")

  local ok, err = pcall(fn, project_dir .. "/.grip")
  vim.wait(50) -- flush any vim.schedule() callbacks queued by switch()

  paths.project_root = orig_project_root
  vim.fn.expand = orig_expand
  vim.notify = orig_notify
  vim.g.db = orig_g_db
  grip.setup(orig_opts)
  grip.open = orig_open
  grip.open_welcome = orig_open_welcome
  package.loaded["dadbod-grip.schema"] = orig_schema
  package.loaded["dadbod-grip.query_pad"] = orig_query_pad
  package.loaded["dadbod-grip.completion"] = orig_completion
  package.loaded["dadbod-grip.connections"] = orig_connections
  connections = orig_connections
  require("dadbod-grip.view").set_connection_accent(nil)

  vim.fn.delete(project_dir, "rf")
  vim.fn.delete(fake_home, "rf")
  if not ok then error(err) end
end

local PROD  = "postgresql://u:p@h/prod"
local LOCAL = "postgresql://u:p@h/local"

--- A connections.json with one red entry and one uncoloured one.
local function write_conns(local_grip)
  paths.ensure_dir(local_grip)
  vim.fn.writefile({ vim.fn.json_encode({
    { name = "prod",  url = PROD,  type = "postgresql", color = "red" },
    { name = "local", url = LOCAL, type = "postgresql" },
  }) }, local_grip .. "/connections.json")
end

test("switching to a coloured connection tints the accent", function()
  with_real_file(function(local_grip)
    write_conns(local_grip)
    connections.switch(PROD, "prod", "postgresql")
    eq(fg("GripConnAccent"), 0xf38ba8, "the entry's colour reached the highlight groups")
    eq(fg("GripBorder"), 0xf38ba8, "so the grid border and sidebar title are red")
  end)
end)

test("switching back to an uncoloured connection restores the defaults", function()
  with_real_file(function(local_grip)
    write_conns(local_grip)
    connections.switch(PROD, "prod", "postgresql")
    connections.switch(LOCAL, "local", "postgresql")
    eq(fg("GripBorder"), DEFAULT_BORDER,
      "leaving a red prod connection must not leave the border red")
    eq(fg("GripConnAccent"), DEFAULT_BORDER, "and the accent with it")
  end)
end)

test("switching to a connection that was never saved restores the defaults", function()
  with_real_file(function(local_grip)
    write_conns(local_grip)
    connections.switch(PROD, "prod", "postgresql")
    -- ~ Connect once: no entry at all, so no colour.
    connections.switch("postgresql://u:p@h/adhoc", nil, "postgresql")
    eq(fg("GripBorder"), DEFAULT_BORDER, "an ad-hoc connection is uncoloured")
  end)
end)

-- ── summary ─────────────────────────────────────────────────────────────────

print(string.format("\nconn_color_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
