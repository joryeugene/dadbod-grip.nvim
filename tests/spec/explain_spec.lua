-- explain_spec.lua -- unit tests for Query Doctor EXPLAIN parsing and rendering
local init = require("dadbod-grip")

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

local function contains(s, frag, msg)
  assert(type(s) == "string" and s:find(frag, 1, true),
    (msg or "") .. ": expected to contain '" .. frag .. "', got '" .. tostring(s) .. "'")
end

-- ── parse_explain_nodes ──────────────────────────────────────────────────────

test("parse: postgresql cost extraction", function()
  local lines = {
    "Seq Scan on users  (cost=0.00..35.50 rows=2550 width=36)",
    "  ->  Index Scan using users_pkey on users  (cost=0.00..8.27 rows=1 width=36)",
  }
  local nodes = init._parse_explain_nodes(lines, "postgresql")
  eq(#nodes, 2, "two nodes")
  eq(nodes[1].cost, 35.50, "first node cost")
  eq(nodes[1].rows, 2550, "first node rows")
  eq(nodes[2].cost, 8.27, "second node cost")
  eq(nodes[2].rows, 1, "second node rows")
end)

test("parse: postgresql actual time extraction", function()
  local lines = {
    "Seq Scan on users  (cost=0.00..35.50 rows=2550) (actual time=0.010..0.135 rows=1000 loops=1)",
  }
  local nodes = init._parse_explain_nodes(lines, "postgresql")
  eq(nodes[1].time, 0.135, "actual time")
end)

test("parse: mysql cost and rows", function()
  local lines = {
    "-> Table scan on users  (cost=102 rows=1000)",
    "  -> Index lookup on orders  (cost=5.5 rows=10)",
  }
  local nodes = init._parse_explain_nodes(lines, "mysql")
  eq(nodes[1].cost, 102, "mysql cost")
  eq(nodes[1].rows, 1000, "mysql rows")
  eq(nodes[2].cost, 5.5, "index cost")
end)

test("parse: duckdb cardinality extraction", function()
  local lines = {
    "  SEQ_SCAN users",
    "  Estimated Cardinality: 5000",
  }
  local nodes = init._parse_explain_nodes(lines, "duckdb")
  eq(nodes[2].cost, 5000, "cardinality as cost")
end)

test("parse: sqlite returns nodes without cost", function()
  local lines = {
    "SCAN users",
    "SEARCH orders USING INDEX idx_user_id (user_id=?)",
  }
  local nodes = init._parse_explain_nodes(lines, "sqlite")
  eq(#nodes, 2, "two nodes")
  assert(nodes[1].cost == nil, "sqlite has no cost")
  eq(nodes[1].operation, "seq_scan", "detected scan operation")
  eq(nodes[2].operation, "index_scan", "detected index operation")
end)

test("parse: empty lines returns empty list", function()
  local nodes = init._parse_explain_nodes({}, "postgresql")
  eq(#nodes, 0, "empty")
end)

test("parse: detects operation types", function()
  local lines = {
    "Seq Scan on users",
    "  ->  Nested Loop",
    "    ->  Hash Join",
    "      ->  Sort",
    "        ->  Aggregate",
  }
  local nodes = init._parse_explain_nodes(lines, "postgresql")
  eq(nodes[1].operation, "seq_scan", "seq scan")
  eq(nodes[2].operation, "nested_loop", "nested loop")
  eq(nodes[3].operation, "hash_join", "hash join")
  eq(nodes[4].operation, "sort", "sort")
  eq(nodes[5].operation, "aggregate", "aggregate")
end)

-- ── render_query_doctor ─────────────────────────────────────────────────────

test("render: translates seq scan to plain English", function()
  local nodes = {
    { text = "Seq Scan on users", cost = 35.50, rows = 5000, time = nil, indent = 0, operation = "seq_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "SLOW", "shows SLOW label")
  contains(joined, "Reading every row", "plain English")
  contains(joined, "users", "mentions table")
end)

test("render: ok operation shows OK label", function()
  local nodes = {
    { text = "Index Scan on users", cost = 8.27, rows = 1, time = nil, indent = 0, operation = "index_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "OK", "shows OK label")
  contains(joined, "Looking up by index", "plain English")
end)

test("render: bottleneck node gets 100% bar", function()
  local nodes = {
    { text = "Seq Scan on users", cost = 100, rows = 5000, time = nil, indent = 0, operation = "seq_scan" },
    { text = "Index Scan on orders", cost = 10, rows = 5, time = nil, indent = 0, operation = "index_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "100%", "bottleneck at 100%")
  contains(joined, "bottleneck", "labeled as bottleneck")
end)

test("render: generates tip for slow operations", function()
  local nodes = {
    { text = "Seq Scan on users", cost = 100, rows = 5000, time = nil, indent = 0, operation = "seq_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "Tip:", "has tip")
  contains(joined, "index", "suggests index")
end)

test("render: summary line counts slow operations", function()
  local nodes = {
    { text = "Seq Scan on users", cost = 100, rows = 5000, time = nil, indent = 0, operation = "seq_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "1 slow operation", "counts slow ops")
end)

test("render: no issues when all ok", function()
  local nodes = {
    { text = "Index Scan on users", cost = 5, rows = 1, time = nil, indent = 0, operation = "index_scan" },
  }
  local lines = init._render_query_doctor(nodes, "postgresql")
  local joined = table.concat(lines, "\n")
  contains(joined, "No major issues", "all clear")
end)

test("render: handles nodes without operations (raw fallback)", function()
  local nodes = {
    { text = "some unknown plan text", cost = nil, rows = nil, time = nil, indent = 0, operation = nil },
  }
  local lines = init._render_query_doctor(nodes, "sqlite")
  local joined = table.concat(lines, "\n")
  contains(joined, "some unknown plan text", "raw text shown")
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nexplain_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
