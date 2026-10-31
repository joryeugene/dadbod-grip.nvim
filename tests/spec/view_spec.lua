-- view_spec.lua: unit tests for view rendering helpers
local view = require("dadbod-grip.view")
local data = require("dadbod-grip.data")

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

local function cleanup()
  for bufnr, _ in pairs(view._sessions) do
    view._sessions[bufnr] = nil
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  while #vim.api.nvim_tabpage_list_wins(0) > 1 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(0)[#vim.api.nvim_tabpage_list_wins(0)], true)
  end
end

local classify = view._classify_cell

-- ── display width padding/truncation ────────────────────────────────────────

test("format_cell: pads Korean text to exact display width", function()
  local cell = view._format_cell("개념 삼각비의 값", 12)
  eq(vim.fn.strdisplaywidth(cell), 12)
end)

test("format_cell: truncates Korean text to exact display width", function()
  local cell = view._format_cell("수선에 의해 나누어진 두 직각삼각형", 11)
  eq(vim.fn.strdisplaywidth(cell), 11)
end)

test("render: Korean cell content keeps table lines aligned", function()
  cleanup()
  local st = data.new({
    columns = { "id", "hints", "comment" },
    rows = {
      { "1", "수선에 의해 나누어진 두 직각삼각형", "중3학년 삼각형 내부 수선" },
      { "2", "먼저 직각삼각형에서 tan 값을 이용", "한글 폭 정렬 확인" },
    },
    primary_keys = { "id" },
    table_name = "problem_hint",
    url = "mysql://localhost/local_db",
  })
  local bufnr = view.open(st, st.url, "SELECT * FROM problem_hint", { max_col_width = 12 })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 6, false)
  local expected = vim.fn.strdisplaywidth(lines[1])
  for i = 2, 6 do
    eq(vim.fn.strdisplaywidth(lines[i]), expected, "line " .. i .. " display width")
  end
  cleanup()
end)

-- ── boolean detection (no type) ──────────────────────────────────────────────

test("classify_cell: 'true' returns GripBoolTrue", function()
  eq(classify("true", nil), "GripBoolTrue")
end)

test("classify_cell: 'false' returns GripBoolFalse", function()
  eq(classify("false", nil), "GripBoolFalse")
end)

test("classify_cell: 't' returns GripBoolTrue", function()
  eq(classify("t", nil), "GripBoolTrue")
end)

test("classify_cell: 'f' returns GripBoolFalse", function()
  eq(classify("f", nil), "GripBoolFalse")
end)

-- ── boolean detection (with type) ────────────────────────────────────────────

test("classify_cell: '1' with tinyint(1) returns GripBoolTrue", function()
  eq(classify("1", "tinyint(1)"), "GripBoolTrue")
end)

test("classify_cell: '0' with boolean returns GripBoolFalse", function()
  eq(classify("0", "boolean"), "GripBoolFalse")
end)

test("classify_cell: 'yes' with bool returns GripBoolTrue", function()
  eq(classify("yes", "bool"), "GripBoolTrue")
end)

test("classify_cell: 'no' with boolean returns GripBoolFalse", function()
  eq(classify("no", "boolean"), "GripBoolFalse")
end)

-- ── negative numbers ─────────────────────────────────────────────────────────

test("classify_cell: '-12.50' returns GripNegative", function()
  eq(classify("-12.50", nil), "GripNegative")
end)

test("classify_cell: '-1' returns GripNegative", function()
  eq(classify("-1", nil), "GripNegative")
end)

test("classify_cell: '0' without type returns nil", function()
  eq(classify("0", nil), nil)
end)

test("classify_cell: '100' returns nil", function()
  eq(classify("100", nil), nil)
end)

-- ── URLs and emails ──────────────────────────────────────────────────────────

test("classify_cell: https URL returns GripUrl", function()
  eq(classify("https://example.com", nil), "GripUrl")
end)

test("classify_cell: http URL returns GripUrl", function()
  eq(classify("http://insecure.com", nil), "GripUrl")
end)

test("classify_cell: email returns GripUrl", function()
  eq(classify("user@example.com", nil), "GripUrl")
end)

test("classify_cell: non-URL returns nil", function()
  eq(classify("not_a_url", nil), nil)
end)

-- ── past dates ───────────────────────────────────────────────────────────────

test("classify_cell: past date with date type returns GripDatePast", function()
  eq(classify("2020-01-01", "date"), "GripDatePast")
end)

test("classify_cell: future date with timestamp returns nil", function()
  eq(classify("2099-12-31", "timestamp"), nil)
end)

test("classify_cell: past date without type returns nil", function()
  eq(classify("2020-01-01", nil), nil)
end)

-- ── edge cases ───────────────────────────────────────────────────────────────

test("classify_cell: nil returns nil", function()
  eq(classify(nil, nil), nil)
end)

test("classify_cell: empty string returns nil", function()
  eq(classify("", nil), nil)
end)

test("classify_cell: '-0.5' is negative not bool", function()
  eq(classify("-0.5", nil), "GripNegative")
end)

-- ── precedence ───────────────────────────────────────────────────────────────

test("classify_cell: 'true' with tinyint(1) returns GripBoolTrue (type-gated)", function()
  eq(classify("true", "tinyint(1)"), "GripBoolTrue")
end)

test("classify_cell: '1' without type returns nil (not bool)", function()
  eq(classify("1", nil), nil)
end)

-- ── get_cell: NULL originals surface as nil ─────────────────────────────────
-- grid_fk_follow guards on cell.value == nil before building
-- "ref_column = <value>" SQL. Original NULLs arrive as vim.NIL and must
-- surface as nil so the guard fires instead of querying for = ''.

test("get_cell: value is nil for NULL original cell (fk-follow NULL guard)", function()
  cleanup()
  local st = data.new({
    columns = { "id", "ref_id" },
    rows = { { "1", vim.NIL } },  -- typed NULL
    primary_keys = { "id" },
    table_name = "orders",
    url = "sqlite:tests/seed_sqlite.db",
  })
  local bufnr = view.open(st, st.url, "SELECT * FROM orders", {})
  local session = view._sessions[bufnr]
  local r = session._render
  local bp = r.byte_positions[1]["ref_id"]
  vim.api.nvim_win_set_cursor(0, { r.data_start or 4, bp.start })
  local cell = view.get_cell(bufnr)
  assert(cell, "cursor should be on a data cell")
  eq(cell.col_name, "ref_id", "cursor column")
  eq(cell.value, nil, "NULL original must surface as nil so the FK NULL guard fires")
  cleanup()
end)

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\nview_spec: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
