-- explain.lua: Query Doctor — turns EXPLAIN output into plain English.
--
-- Parsing and rendering only; the :GripExplain float stays in init.lua. These
-- used to be declared inside setup(), which rebuilt them on every setup() call
-- and kept them out of reach of tests until the first one.

local M = {}

--- Detect adapter type from connection URL.
--- Resolves a "${VAR}" template first: parse_nodes gates every extraction on
--- this value, so an unresolved template would silently return a plan with no
--- cost, rows or time.
function M.detect_adapter(url)
  local resolved = require("dadbod-grip.db").resolved_url(url)
  return require("dadbod-grip.adapters").kind(resolved) or "unknown"
end

--- Parse EXPLAIN output into structured nodes.
function M.parse_nodes(lines, adapter_type)
  local nodes = {}
  for i, line in ipairs(lines) do
    local node = { text = line, cost = nil, rows = nil, time = nil, indent = 0, operation = nil }

    -- Detect indent level
    node.indent = #(line:match("^(%s*)") or "")

    if adapter_type == "postgresql" then
      -- cost=0.00..35.50
      local cost_end = line:match("cost=[%d.]+%.%.([%d.]+)")
      if cost_end then node.cost = tonumber(cost_end) end
      local rows_val = line:match("rows=(%d+)")
      if rows_val then node.rows = tonumber(rows_val) end
      local actual_time = line:match("actual time=[%d.]+%.%.([%d.]+)")
      if actual_time then node.time = tonumber(actual_time) end
    elseif adapter_type == "mysql" then
      local cost_val = line:match("cost=([%d.]+)")
      if cost_val then node.cost = tonumber(cost_val) end
      local rows_val = line:match("rows=(%d+)")
      if rows_val then node.rows = tonumber(rows_val) end
    elseif adapter_type == "duckdb" then
      local card = line:match("Estimated Cardinality:%s*(%d+)")
      if card then node.cost = tonumber(card) end
    end

    -- Detect operation type
    local lt = line:lower()
    if lt:match("seq scan") or lt:match("full scan") or lt:match("table scan") or lt:match("scan table")
      or lt:match("^%s*scan ") then
      node.operation = "seq_scan"
    elseif lt:match("index scan") or lt:match("index lookup") or lt:match("using index")
      or lt:match("search.*using") then
      node.operation = "index_scan"
    elseif lt:match("bitmap") then
      node.operation = "bitmap_scan"
    elseif lt:match("nested loop") then
      node.operation = "nested_loop"
    elseif lt:match("hash join") or lt:match("hash match") then
      node.operation = "hash_join"
    elseif lt:match("sort") or lt:match("filesort") then
      node.operation = "sort"
    elseif lt:match("filter") then
      node.operation = "filter"
    elseif lt:match("aggregate") or lt:match("group") then
      node.operation = "aggregate"
    elseif lt:match("limit") then
      node.operation = "limit"
    end

    table.insert(nodes, node)
  end
  return nodes
end

--- Translation table: operation -> plain English description + severity rules.
local TRANSLATIONS = {
  seq_scan     = { label = "Reading every row in %s", tip = "Consider adding an index on the filtered column", severity = "slow" },
  index_scan   = { label = "Looking up by index on %s", tip = nil, severity = "ok" },
  bitmap_scan  = { label = "Partial index scan on %s", tip = nil, severity = "ok" },
  nested_loop  = { label = "Comparing every row pair (nested loop)", tip = "Large nested loop; check if a hash join would help", severity = "slow" },
  hash_join    = { label = "Matching rows by hash", tip = nil, severity = "ok" },
  sort         = { label = "Sorting results (no index)", tip = "Consider a covering index to avoid this sort", severity = "warn" },
  filter       = { label = "Filtering rows before output", tip = "Index on filter column may help", severity = "warn" },
  aggregate    = { label = "Computing aggregate (GROUP BY)", tip = nil, severity = "ok" },
  limit        = { label = "Limiting results", tip = nil, severity = "ok" },
}

--- Render parsed nodes as plain-English Query Doctor output.
--- adapter_type is taken for symmetry with parse_nodes and not read: severity
--- comes from the cost/row numbers alone.
function M.render(nodes, adapter_type)
  local display_lines = {}
  local hl_marks = {}

  local function add(s) table.insert(display_lines, s) end
  local function mark(hl)
    table.insert(hl_marks, { line = #display_lines, hl = hl })
  end

  add("  Query Health")
  add("  " .. string.rep("\xe2\x94\x80", 28))
  mark("GripProfileHeader")
  add("")

  -- Find max cost for bar sizing
  local max_cost = 0
  local total_cost = 0
  local root_rows = nil
  for _, n in ipairs(nodes) do
    if n.cost then
      max_cost = math.max(max_cost, n.cost)
      total_cost = total_cost + n.cost
    end
    if not root_rows and n.rows then root_rows = n.rows end
  end

  -- Render each node with an operation
  local slow_count = 0
  local has_content = false

  for _, n in ipairs(nodes) do
    if n.operation then
      local tr = TRANSLATIONS[n.operation]
      if tr then
        has_content = true
        -- Extract table name from text
        local tbl_name = n.text:match("on%s+(%S+)") or n.text:match("table%s+(%S+)") or ""
        tbl_name = tbl_name:gsub("[%(%)]", "")

        -- Determine actual severity
        local sev = tr.severity
        if sev == "slow" and n.rows and n.rows < 1000 then sev = "ok" end
        if sev == "warn" and n.cost and n.cost < 500 then sev = "ok" end
        if n.operation == "nested_loop" and (not n.rows or n.rows < 1000) then sev = "ok" end

        -- Build label
        local label = tr.label
        if label:match("%%s") then
          label = string.format(label, tbl_name ~= "" and tbl_name or "table")
        end

        -- Severity prefix
        local prefix
        if sev == "slow" then
          prefix = "  SLOW"
          slow_count = slow_count + 1
        elseif sev == "warn" then
          prefix = "  WARN"
        else
          prefix = "  OK"
        end

        add(prefix .. ": " .. label)
        if sev == "slow" then mark("DiagnosticError")
        elseif sev == "warn" then mark("DiagnosticWarn")
        else mark("DiagnosticOk")
        end

        -- Cost bar
        if n.cost and max_cost > 0 then
          local bar_w = math.max(1, math.floor((n.cost / max_cost) * 20))
          local bar = string.rep("\xe2\x96\x88", bar_w) .. string.rep("\xe2\x96\x91", 20 - bar_w)
          local pct = math.floor(n.cost / max_cost * 100)
          local bar_label = n.cost == max_cost and "  (bottleneck)" or "  (fast)"
          if sev == "warn" then bar_label = "" end
          add("  " .. bar .. "  " .. pct .. "%" .. bar_label)
        end

        -- Description with row count
        if n.rows then
          add("  This processes ~" .. n.rows .. " rows.")
        end

        -- Tip
        if sev ~= "ok" and tr.tip then
          add("  Tip: " .. tr.tip)
        end

        add("")
      end
    end
  end

  -- If no operations detected, show raw plan
  if not has_content then
    for _, n in ipairs(nodes) do
      add("  " .. n.text)
    end
    add("")
  end

  -- Summary
  add("  " .. string.rep("\xe2\x94\x80", 28))
  local summary_parts = {}
  if slow_count > 0 then
    table.insert(summary_parts, slow_count .. " slow operation(s) found")
  else
    table.insert(summary_parts, "No major issues detected")
  end
  if total_cost > 0 then
    table.insert(summary_parts, "Est. cost: " .. string.format("%.1f", total_cost))
  end
  if root_rows then
    table.insert(summary_parts, "Est. rows: " .. root_rows)
  end
  add("  " .. table.concat(summary_parts, "  |  "))
  if slow_count > 0 then mark("DiagnosticError")
  else mark("DiagnosticOk")
  end

  return display_lines, hl_marks
end

return M
