-- tests/spec/er_diagram_spec.lua
-- Tests for the tree-spine ER diagram layout (antifragile design).
--
-- Every table owns exactly one unique line. Navigation uses
-- line_to_node[row]: pure row lookup, no column arithmetic.
--
-- build_content returns: lines, {}, line_to_node, table_lines
--   line_to_node[1idx] = {name, kind, prefix_len}
--   table_lines        = sorted 1-indexed line numbers of table nodes
dofile("tests/minimal_init.lua")
local er         = require("dadbod-grip.er_diagram")
local schema_mod = require("dadbod-grip.schema")

local pass, fail = 0, 0

local function eq(a, b, msg)
  if a == b then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL: %s\n  expected: %s\n  got:      %s",
          msg or "eq", tostring(b), tostring(a)))
  end
end

local function ok(v, msg)
  if v then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL: " .. (msg or "expected truthy"))
  end
end

-- 5-table FK chain:
--   consumer_incidents(d4) → rolls(d3) → production_batches(d2)
--   → facilities(d1) → bamboo_cartel_members(d0)
-- All five are in a single linear chain so tree renders them as:
--   bamboo_cartel_members          (root, depth 0)
--   └── facilities                 (depth 1)
--       └── production_batches     (depth 2)
--             └── rolls            (depth 3)
--                   └── consumer_incidents  (depth 4)
local mock_state = {
  items = {
    { type = "table", name = "bamboo_cartel_members" },
    { type = "table", name = "facilities" },
    { type = "table", name = "production_batches" },
    { type = "table", name = "rolls" },
    { type = "table", name = "consumer_incidents" },
  },
  col_cache = {
    bamboo_cartel_members = { { column_name = "id",           data_type = "integer" } },
    facilities            = { { column_name = "id",           data_type = "integer" },
                               { column_name = "bamboo_id",   data_type = "integer" } },
    production_batches    = { { column_name = "id",           data_type = "integer" },
                               { column_name = "facility_id", data_type = "integer" } },
    rolls                 = { { column_name = "sku",          data_type = "text"    },
                               { column_name = "batch_id",    data_type = "integer" } },
    consumer_incidents    = { { column_name = "id",           data_type = "integer" },
                               { column_name = "roll_sku",    data_type = "text"    } },
  },
  pk_cache = {
    bamboo_cartel_members = { id = true },
    facilities            = { id = true },
    production_batches    = { id = true },
    rolls                 = { sku = true },
    consumer_incidents    = { id = true },
  },
  fk_cache = {
    bamboo_cartel_members = {},                                          -- depth 0
    facilities            = { bamboo_id   = "bamboo_cartel_members" },  -- depth 1
    production_batches    = { facility_id = "facilities"            },  -- depth 2
    rolls                 = { batch_id    = "production_batches"    },  -- depth 3
    consumer_incidents    = { roll_sku    = "rolls"                 },  -- depth 4
  },
}

local function with_mock_schema(fn)
  local orig = schema_mod.get_state
  schema_mod.get_state = function() return mock_state end
  local ok_run, err = pcall(fn)
  schema_mod.get_state = orig
  if not ok_run then error(err, 2) end
end

-- ── Antifragile: every table on a unique line ──────────────────────────────

with_mock_schema(function()
  local lines, _, line_to_node, table_lines = er._build_content("sqlite:test.db")

  ok(table_lines ~= nil, "table_lines returned as 4th value")
  eq(#table_lines, 5,    "table_lines has 5 entries (one per table)")

  -- All table line numbers must be unique (no two tables share a line)
  local seen_lines = {}
  for _, ln in ipairs(table_lines) do
    ok(not seen_lines[ln], "line " .. ln .. " is unique (no shared rows)")
    seen_lines[ln] = true
  end

  ok(line_to_node ~= nil, "line_to_node returned as 3rd value")

  -- Build by-name lookup
  local by_name = {}
  for ln, node in pairs(line_to_node) do
    if node.kind == "table" then by_name[node.name] = { line = ln, node = node } end
  end

  -- All 5 tables present in line_to_node
  ok(by_name["bamboo_cartel_members"] ~= nil, "bamboo_cartel_members in line_to_node")
  ok(by_name["facilities"]            ~= nil, "facilities in line_to_node")
  ok(by_name["production_batches"]    ~= nil, "production_batches in line_to_node")
  ok(by_name["rolls"]                 ~= nil, "rolls in line_to_node")
  ok(by_name["consumer_incidents"]    ~= nil, "consumer_incidents in line_to_node")

  -- Parent appears before child in tree order
  if by_name["bamboo_cartel_members"] and by_name["facilities"] then
    ok(by_name["bamboo_cartel_members"].line < by_name["facilities"].line,
       "bamboo (root) appears before facilities (depth 1)")
  end
  if by_name["facilities"] and by_name["production_batches"] then
    ok(by_name["facilities"].line < by_name["production_batches"].line,
       "facilities appears before production_batches")
  end
  if by_name["production_batches"] and by_name["rolls"] then
    ok(by_name["production_batches"].line < by_name["rolls"].line,
       "production_batches appears before rolls")
  end
  if by_name["rolls"] and by_name["consumer_incidents"] then
    ok(by_name["rolls"].line < by_name["consumer_incidents"].line,
       "rolls appears before consumer_incidents (deepest)")
  end

  -- Root table (bamboo) has no tree connector in its line
  if by_name["bamboo_cartel_members"] then
    local ln = by_name["bamboo_cartel_members"].line
    local line_str = lines[ln] or ""
    ok(line_str:find("├──", 1, true) == nil and line_str:find("└──", 1, true) == nil,
       "bamboo_cartel_members (root) has no tree connector")
  end

  -- Child tables have a tree connector
  if by_name["facilities"] then
    local ln = by_name["facilities"].line
    local line_str = lines[ln] or ""
    ok(line_str:find("├──", 1, true) ~= nil or line_str:find("└──", 1, true) ~= nil,
       "facilities has a tree connector (├── or └──)")
  end

  -- Column summaries are aligned: all start at the same column
  -- Verify by checking that bamboo and consumer_incidents (widest gap) both
  -- have their column summary at the same display position.
  if by_name["bamboo_cartel_members"] and by_name["consumer_incidents"] then
    local bamb_line = lines[by_name["bamboo_cartel_members"].line] or ""
    local cons_line = lines[by_name["consumer_incidents"].line]    or ""
    -- Find the byte position of '●' in each line
    local bamb_pk = bamb_line:find("●", 1, true)
    local cons_pk = cons_line:find("●", 1, true)
    ok(bamb_pk ~= nil, "bamboo line contains ● PK indicator")
    ok(cons_pk ~= nil, "consumer_incidents line contains ● PK indicator")
    if bamb_pk and cons_pk then
      -- Both '●' symbols should appear at the same display column (visually aligned).
      -- Box-drawing chars (└──) are 3 UTF-8 bytes but 1 display column each,
      -- so byte offsets differ; compare display widths instead.
      local strdw = vim.fn.strdisplaywidth
      local bamb_disp = strdw(bamb_line:sub(1, bamb_pk - 1))
      local cons_disp = strdw(cons_line:sub(1, cons_pk - 1))
      eq(bamb_disp, cons_disp,
         "column summaries aligned: ● at same display column in bamboo and consumer_incidents")
    end
  end
end)

-- ── table_lines sorted top-to-bottom ────────────────────────────────────────

with_mock_schema(function()
  local _, _, _, table_lines = er._build_content("sqlite:test.db")
  if not table_lines then return end
  for i = 2, #table_lines do
    ok(table_lines[i - 1] < table_lines[i],
       "table_lines sorted: entry " .. (i - 1) .. " (" .. table_lines[i-1] ..
       ") < entry " .. i .. " (" .. table_lines[i] .. ")")
  end
end)

-- ── scroll_to finds table by name (row-only lookup) ──────────────────────────

with_mock_schema(function()
  local _, _, line_to_node, _ = er._build_content("sqlite:test.db")
  local found_line = nil
  for ln, node in pairs(line_to_node) do
    if node.name == "bamboo_cartel_members" then found_line = ln; break end
  end
  ok(found_line ~= nil, "scroll_to: bamboo_cartel_members found in line_to_node")
  ok(found_line ~= nil and found_line > 0, "scroll_to: line number is positive")
end)

-- ── Long column name truncation ───────────────────────────────────────────────
-- A table with a very long column name should have it truncated to ≤12 display
-- chars (+ 1 for the "…" suffix), keeping each column slot narrow.

do
  local long_col_state = {
    items = { { type = "table", name = "t" } },
    col_cache = { t = {
      { column_name = "id",                     data_type = "integer" },
      { column_name = "unanimous_winner_sku",   data_type = "text"    },
      { column_name = "softness_tier_controlled", data_type = "text"  },
    }},
    pk_cache  = { t = { id = true } },
    fk_cache  = { t = {} },
  }

  local function with_state(fn)
    local orig = require("dadbod-grip.schema").get_state
    require("dadbod-grip.schema").get_state = function() return long_col_state end
    local ok_r, err = pcall(fn)
    require("dadbod-grip.schema").get_state = orig
    if not ok_r then error(err, 2) end
  end

  with_state(function()
    local lines, _, line_to_node, _ = er._build_content("sqlite:x.db")
    local found_line = nil
    for ln, node in pairs(line_to_node) do
      if node.kind == "table" and node.name == "t" then found_line = ln end
    end
    ok(found_line ~= nil, "truncation: table t found in diagram")
    if found_line then
      local line_str = lines[found_line] or ""
      -- "unanimous_winner_sku" (20 chars) should be truncated; "…" must appear
      ok(line_str:find("…", 1, true) ~= nil,
         "truncation: long column name contains … suffix")
      -- No column name segment should exceed 13 display chars (12 + "…")
      -- Split on the double-space separator and check each part after the icon
      for part in line_str:gmatch("%S+") do
        -- parts like "unanimous_wi…": extract just the name portion (after icon byte)
        if part ~= "●" and part ~= "⬡" and part ~= "○" and
           part ~= "t" and not part:match("^%+%d") then
          ok(vim.fn.strdisplaywidth(part) <= 13,
             "truncation: column token '" .. part .. "' is ≤13 display cols")
        end
      end
    end
  end)
end

-- ── summary ───────────────────────────────────────────────────────────────────

print(string.format("\ner_diagram_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
