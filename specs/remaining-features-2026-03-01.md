# Remaining Features Spec - dadbod-grip.nvim

## Overview

Seven features across three tiers plus ongoing work. Each has an
engineering spec, ASCII prototype where applicable, implementation
notes, and estimated scope.

```
Tier 1 - Grid Polish       (v1.4 completion)
  1. Column hide/show toggle
  2. Copy/paste between cells          DONE (b91f26b)

Tier 2 - Data Intelligence  (v2.0 completion)
  3. Data diff side-by-side

Tier 3 - Schema Operations  (v3.0 DDL)
  4. Table properties view
  5. Column rename
  6. Column add/drop
  7. Create/drop table

Ongoing
  8. Automated tests + CI
  9. Performance profiling
```

Remaining new code: ~1740 lines across 3 new modules + adapter extensions.

---

## 1. Column Hide/Show Toggle

**Keymap:** `gH` to open column picker, `-` to hide column under cursor.

**Session state:**
```lua
session.hidden_columns = {}  -- set of column names to hide
```

**Behavior:**
- `gH` opens vim.ui.select with multiselect showing all columns, checkmarked
  if visible. Toggling a column adds/removes from hidden set, then re-renders.
- `-` on a column hides it immediately. Cursor moves to next visible column.
- `g-` restores all hidden columns.
- Hidden columns are excluded from `build_render()` iteration but remain in
  state.columns (data is untouched, only display changes).
- Status line shows "N hidden" badge when columns are hidden.
- Export still includes hidden columns (export = full data, display != data).

**Prototype:**

```
Before:
╔══════════════════════════════════════════════════════╗
║ grip://users         postgresql://localhost/mydb     ║
╠════╤═══════╤═══════════════╤════════╤════════════════╣
║ id │ name  │ email         │ phone  │ created_at     ║
╠════╪═══════╪═══════════════╪════════╪════════════════╣
║  1 │ alice │ alice@ex.com  │ 555-01 │ 2024-01-15     ║
║  2 │ bob   │ bob@ex.com    │ 555-02 │ 2024-02-20     ║
╚════╧═══════╧═══════════════╧════════╧════════════════╝
 5 rows  Page 1/1

After hiding phone and created_at (cursor on phone, press -, then again):
╔════════════════════════════════════════════════╗
║ grip://users         2 hidden                  ║
╠════╤═══════╤═══════════════╤═══════════════════╣
║ id │ name  │ email         │                   ║
╠════╪═══════╪═══════════════╪═══════════════════╣
║  1 │ alice │ alice@ex.com  │                   ║
║  2 │ bob   │ bob@ex.com    │                   ║
╚════╧═══════╧═══════════════╧═══════════════════╝
 5 rows  Page 1/1  2 hidden

After gH picker:
┌─────────────────────────┐
│ Toggle columns          │
│                         │
│ [x] id                  │
│ [x] name                │
│ [x] email               │
│ [ ] phone         (hidden)
│ [ ] created_at    (hidden)
│                         │
│ <CR> toggle  q close    │
└─────────────────────────┘
```

**Implementation:**

```
view.lua  build_render()    ~30 lines  Filter columns list through hidden set
view.lua  keymaps           ~40 lines  gH picker, - hide, g- restore
view.lua  status badge      ~5 lines   Show hidden count
```

**Scope:** ~75 lines in view.lua. No new files.

---

## 2. Copy/Paste Between Cells - DONE (b91f26b)

**Keymaps implemented:**
- Visual `y`: yank selected cells in cursor's column, newline-separated to
  system clipboard.
- Normal `P`: paste multi-line clipboard into consecutive rows starting at
  cursor position, same column. Falls back to single-cell paste if clipboard
  has only one line.
- Normal `p`: unchanged, single cell paste.

**Design decision:** Uses system clipboard (`+` register) rather than an
internal clipboard. This means visual `y` in one grip buffer can `P` into
a different grip buffer, and values are also available outside Neovim.
No new session state needed.

Works in all visual modes (v, V, ctrl-v) via `"x"` mode keymaps.

---

## 3. Data Diff - `:GripDiff`

The most visually complex remaining feature. Opens two grids side by side
with diff highlighting showing row-level and cell-level changes.

**Command:** `:GripDiff source target`

Where source/target can be:
- Two table names: `:GripDiff users users_backup`
- Table + query: `:GripDiff users "SELECT * FROM users WHERE active"`
- Two connections: `:GripDiff users@prod users@staging` (future)

**Keymap:** `gD` from a grid to diff against the same table with a filter/sort
removed (compare current view vs unfiltered).

**New module:** `lua/dadbod-grip/diff.lua` (~250 lines)

### Algorithm

```
1. Run both queries in parallel (vim.system async)
2. Match rows by primary key values (PK = row identity)
3. For each PK:
   a. Present in both  -> compare cells, mark CHANGED or SAME
   b. Only in left     -> mark DELETED (red)
   c. Only in right    -> mark ADDED (green)
4. For changed rows, find which cells differ -> cell-level highlight
5. Render side-by-side in a single buffer (left | right)
```

### ASCII Prototype

```
╔══════════════════════════════════════════════════════════════════════════════╗
║ grip://diff   users vs users_backup   3 changed  1 added  1 deleted        ║
╠═══════════════════════════════════╦═══════════════════════════════════════════╣
║ LEFT: users                      ║ RIGHT: users_backup                      ║
╠════╤═══════╤═══════════════╤═════╬════╤═══════╤═══════════════╤═════════════╣
║ id │ name  │ email         │ age ║ id │ name  │ email         │ age         ║
╠════╪═══════╪═══════════════╪═════╬════╪═══════╪═══════════════╪═════════════╣
║  1 │ alice │ alice@new.com │  30 ║  1 │ alice │ alice@old.com │  30         ║
║    │       │ ^^^^^^^^^^^^^ │     ║    │       │ ^^^^^^^^^^^^^ │             ║
║  2 │ BOB   │ bob@ex.com    │  25 ║  2 │ bob   │ bob@ex.com    │  25         ║
║    │ ^^^^  │               │     ║    │ ^^^^  │               │             ║
║  3 │ carol │ carol@ex.com  │  35 ║  3 │ carol │ carol@ex.com  │  28         ║
║    │       │               │ ^^^ ║    │       │               │ ^^^         ║
║  4 │ dave  │ dave@ex.com   │  40 ║    │       │               │             ║
║ -- │ ----- │ ------------- │ --- ║    │  (row only in left)   │             ║
║    │       │               │     ║  5 │ eve   │ eve@ex.com    │  22         ║
║    │  (row only in right)  │     ║ ++ │ +++++ │ +++++++++++++ │ +++         ║
╚════╧═══════╧═══════════════╧═════╩════╧═══════╧═══════════════╧═════════════╝
 Summary: 5 rows compared | 3 changed | 1 only-left | 1 only-right

 Keymaps: ]c next change  [c prev change  q close  ? help
```

### Cell-Level Diff Coloring

```
Highlight Groups:
  GripDiffSame      -> default (no highlight)
  GripDiffChanged   -> yellow background  #f9e2af on changed cells
  GripDiffAdded     -> green background   #a6e3a1 on right-only rows
  GripDiffDeleted   -> red background     #f38ba8 on left-only rows
  GripDiffSep       -> bold dim           center separator column
```

### Compact Diff Mode (for narrow terminals)

When terminal width < 120 columns, render as unified diff instead:

```
╔══════════════════════════════════════════════╗
║ grip://diff   users vs users_backup          ║
╠════╤═══════╤═══════════════╤═════╤═══════════╣
║ id │ name  │ email         │ age │ status    ║
╠════╪═══════╪═══════════════╪═════╪═══════════╣
║  1 │ alice │ alice@new.com │  30 │ changed   ║
║  1 │ alice │ alice@old.com │  30 │   (was)   ║
║    │       │ ^^^^^         │     │           ║
║  2 │ BOB   │ bob@ex.com    │  25 │ changed   ║
║  2 │ bob   │ bob@ex.com    │  25 │   (was)   ║
║    │ ^^^^  │               │     │           ║
║  4 │ dave  │ dave@ex.com   │  40 │ deleted   ║
║  5 │ eve   │ eve@ex.com    │  22 │ added     ║
╚════╧═══════╧═══════════════╧═════╧═══════════╝
```

### Diff Engine (pure functions)

```lua
-- diff.lua

M.compute(left_state, right_state)
-- Returns:
{
  matched = {
    { pk = {id=1}, left_row = 1, right_row = 1,
      diffs = { email = {left="alice@new.com", right="alice@old.com"} }
    },
  },
  left_only = { {pk = {id=4}, row = 4} },
  right_only = { {pk = {id=5}, row = 1} },
  summary = { total=5, changed=3, added=1, deleted=1 },
}

M.render_side_by_side(diff_result, columns, widths)
-- Returns: {lines=[], marks=[], diff_rows=[]}

M.render_unified(diff_result, columns, widths)
-- Returns: {lines=[], marks=[]}
```

### Implementation Plan

```
diff.lua           NEW  ~250 lines  Diff engine + renderer
view.lua                ~40 lines   gD keymap, diff buffer keymaps
init.lua                ~50 lines   :GripDiff command, dual query dispatch
db.lua                  ~10 lines   Parallel query helper
```

**Scope:** ~350 lines. One new module.

---

## 4. Table Properties View

**Command:** `:GripProperties` or `gI` from grid (capital I, extends `gi`).

Opens a dedicated float showing full table metadata in a structured layout.
More detailed than `gi` (which shows a compact popup).

### ASCII Prototype

```
┌─────────────────────────────────────────────────────────┐
│  Table: users                                           │
│  Schema: public            Engine: InnoDB (MySQL)       │
│  Rows: ~1,420              Size: 256 KB                 │
│                                                         │
│  Columns                                                │
│  ┌────┬──────────────┬──────────────┬──────┬───────────┐│
│  │ #  │ Name         │ Type         │ Null │ Default   ││
│  ├────┼──────────────┼──────────────┼──────┼───────────┤│
│  │  1 │ id           │ integer      │ NO   │ nextval() ││
│  │  2 │ name         │ varchar(100) │ NO   │           ││
│  │  3 │ email        │ varchar(255) │ NO   │           ││
│  │  4 │ age          │ integer      │ YES  │           ││
│  │  5 │ created_at   │ timestamptz  │ NO   │ now()     ││
│  │  6 │ status       │ mood         │ YES  │ 'happy'   ││
│  └────┴──────────────┴──────────────┴──────┴───────────┘│
│                                                         │
│  Primary Key                                            │
│    (id)                                                 │
│                                                         │
│  Foreign Keys                                           │
│    department_id -> departments(id)                      │
│    manager_id    -> users(id)                            │
│                                                         │
│  Indexes                                                │
│    users_pkey ........... PRIMARY (id)                   │
│    users_email_key ...... UNIQUE (email)                 │
│    users_dept_idx ....... INDEX (department_id)          │
│                                                         │
│  q close   e edit column   + add column   - drop column │
└─────────────────────────────────────────────────────────┘
```

### Adapter Extension

New adapter method: `get_table_properties(table_name, url)`

```lua
-- Returns:
{
  schema = "public",
  engine = nil,           -- MySQL only
  row_estimate = 1420,    -- pg_class.reltuples / sqlite_stat1 / etc
  size_bytes = 262144,    -- pg_total_relation_size / page_count*page_size
  columns = {
    { name="id", type="integer", nullable=false, default="nextval('users_id_seq')",
      pk=true, fk=nil },
    { name="department_id", type="integer", nullable=true, default=nil,
      pk=false, fk={table="departments", column="id"} },
  },
  indexes = {
    { name="users_pkey", type="PRIMARY", columns={"id"} },
    { name="users_email_key", type="UNIQUE", columns={"email"} },
  },
}
```

Per-adapter queries:

| Adapter    | Row estimate             | Size              | Indexes                         |
|------------|--------------------------|-------------------|---------------------------------|
| PostgreSQL | pg_class.reltuples       | pg_total_relation_size() | pg_indexes                 |
| SQLite     | COUNT(*) or sqlite_stat1 | page_count * page_size | PRAGMA index_list + index_info |
| MySQL      | information_schema.tables| DATA_LENGTH + INDEX_LENGTH | SHOW INDEX FROM table    |
| DuckDB     | duckdb_tables()          | N/A               | duckdb_indexes()                |

### Implementation Plan

```
properties.lua     NEW  ~200 lines  Float renderer + interactive keymaps
adapters/*.lua          ~40 lines each (4 adapters)  get_table_properties()
db.lua                  ~5 lines    Facade method
init.lua                ~15 lines   :GripProperties command
view.lua                ~5 lines    gI keymap
```

**Scope:** ~380 lines. One new module + adapter extensions.

---

## 5. Column Rename

**Entry point:** `gI` properties view, cursor on column, press `R`.

Or `:GripRename old_name new_name` command.

### Flow

```
1. User presses R on a column in properties view
2. vim.ui.input prompt: "Rename 'email' to:"
3. User types new name, presses CR
4. Preview DDL in float:

   ┌──────────────────────────────────────────┐
   │  ALTER TABLE "users"                     │
   │    RENAME COLUMN "email" TO "user_email" │
   │                                          │
   │  Apply? [y/N]                            │
   └──────────────────────────────────────────┘

5. On confirm: execute DDL, refresh properties view + any open grids
```

### Adapter DDL

All four databases support `ALTER TABLE ... RENAME COLUMN`:

| Adapter    | Syntax                                                    |
|------------|-----------------------------------------------------------|
| PostgreSQL | `ALTER TABLE "t" RENAME COLUMN "old" TO "new"`            |
| SQLite     | `ALTER TABLE "t" RENAME COLUMN "old" TO "new"` (3.25.0+)  |
| MySQL      | `ALTER TABLE "t" RENAME COLUMN "old" TO "new"` (8.0+)     |
| DuckDB     | `ALTER TABLE "t" RENAME COLUMN "old" TO "new"`            |

New adapter method: `rename_column(table_name, old_name, new_name, url)`

**Scope:** ~60 lines across ddl.lua + adapters.

---

## 6. Column Add/Drop

**Entry point:** `gI` properties view, `+` to add, `-` to drop.

### Add Column Flow

```
1. User presses + in properties view
2. Multi-step prompt:

   ┌────────────────────────────────────────┐
   │  Add column to "users"                 │
   │                                        │
   │  Name:     [________________]          │
   │  Type:     [varchar(255)___]           │
   │  Nullable: [x] YES                     │
   │  Default:  [________________]          │
   │                                        │
   │  <CR> next field   <C-CR> confirm      │
   └────────────────────────────────────────┘

3. Preview DDL:

   ┌─────────────────────────────────────────────┐
   │  ALTER TABLE "users"                        │
   │    ADD COLUMN "phone" varchar(255) NULL      │
   │    DEFAULT '+1-000-000-0000'                 │
   │                                              │
   │  Apply? [y/N]                                │
   └─────────────────────────────────────────────┘

4. Execute, refresh
```

### Drop Column Flow

```
1. User presses - on a column in properties view
2. Confirmation with DDL preview:

   ┌─────────────────────────────────────────────┐
   │  ⚠ DROP COLUMN                              │
   │                                              │
   │  ALTER TABLE "users"                         │
   │    DROP COLUMN "phone"                       │
   │                                              │
   │  This will permanently delete all data       │
   │  in the "phone" column (1,420 rows).         │
   │                                              │
   │  Type "phone" to confirm: [___________]      │
   └─────────────────────────────────────────────┘

3. Requires typing column name to confirm (destructive)
4. Execute, refresh
```

### Adapter DDL

| Adapter    | ADD COLUMN                                         | DROP COLUMN                    |
|------------|----------------------------------------------------|--------------------------------|
| PostgreSQL | `ALTER TABLE "t" ADD COLUMN "c" type [NULL] [DEF]` | `ALTER TABLE "t" DROP COLUMN "c"` |
| SQLite     | `ALTER TABLE "t" ADD COLUMN "c" type`              | Not supported (rebuild table)  |
| MySQL      | `ALTER TABLE "t" ADD COLUMN "c" type [NULL] [DEF]` | `ALTER TABLE "t" DROP COLUMN "c"` |
| DuckDB     | `ALTER TABLE "t" ADD COLUMN "c" type [DEF]`        | `ALTER TABLE "t" DROP COLUMN "c"` |

SQLite does not support DROP COLUMN in older versions (added in 3.35.0).
For older SQLite, the adapter returns an error: "DROP COLUMN requires
SQLite 3.35.0 or later."

New adapter methods:
- `add_column(table_name, col_name, col_type, nullable, default_val, url)`
- `drop_column(table_name, col_name, url)`

**Scope:** ~120 lines across ddl.lua + adapters.

---

## 7. Create/Drop Table

**Commands:** `:GripCreate` and `:GripDrop table_name`

### Create Table Flow

```
1. :GripCreate opens an interactive table designer:

   ┌──────────────────────────────────────────────────────────┐
   │  Create Table                                            │
   │                                                          │
   │  Table name: [________________]                          │
   │                                                          │
   │  Columns:                                                │
   │  ┌────┬──────────────┬──────────────┬──────┬───────────┐ │
   │  │ #  │ Name         │ Type         │ Null │ Default   │ │
   │  ├────┼──────────────┼──────────────┼──────┼───────────┤ │
   │  │  1 │ id           │ SERIAL       │ NO   │ (auto)    │ │
   │  │  2 │ [name______] │ [type______] │ [x]  │ [_______] │ │
   │  │    │              │              │      │           │ │
   │  │  + add column                                       │ │
   │  └────┴──────────────┴──────────────┴──────┴───────────┘ │
   │                                                          │
   │  Primary Key: [id_________]                              │
   │                                                          │
   │  <C-CR> preview SQL   <C-s> create   q cancel            │
   └──────────────────────────────────────────────────────────┘

2. <C-CR> previews generated DDL:

   ┌──────────────────────────────────────────────┐
   │  CREATE TABLE "projects" (                   │
   │    "id" SERIAL PRIMARY KEY,                  │
   │    "name" varchar(100) NOT NULL,             │
   │    "description" text,                       │
   │    "created_at" timestamptz NOT NULL          │
   │      DEFAULT now()                            │
   │  );                                           │
   │                                               │
   │  Create? [y/N]                                │
   └──────────────────────────────────────────────┘

3. Execute, open new table in grip grid
```

### Drop Table Flow

```
1. :GripDrop users (or from schema browser, press D on table)

   ┌──────────────────────────────────────────────┐
   │  ⚠ DROP TABLE                                │
   │                                               │
   │  DROP TABLE "users"                           │
   │                                               │
   │  This will permanently delete the table       │
   │  and all 1,420 rows of data.                  │
   │                                               │
   │  Dependents:                                  │
   │    orders.user_id -> users.id (FK)            │
   │    profiles.user_id -> users.id (FK)          │
   │                                               │
   │  Type "users" to confirm: [___________]       │
   └──────────────────────────────────────────────┘

2. Shows FK dependents so user knows what will break
3. Requires typing table name to confirm
4. Execute with CASCADE option if dependents exist:

   ┌──────────────────────────────────────────────┐
   │  Table has dependents. Choose:               │
   │                                               │
   │  [1] DROP TABLE "users" CASCADE              │
   │      (also drops dependent FKs)               │
   │                                               │
   │  [2] DROP TABLE "users" RESTRICT             │
   │      (fail if dependents exist)               │
   │                                               │
   │  [3] Cancel                                   │
   └──────────────────────────────────────────────┘
```

### Adapter DDL

| Adapter    | CREATE TABLE                     | DROP TABLE          | CASCADE  |
|------------|----------------------------------|---------------------|----------|
| PostgreSQL | Standard SQL                     | `DROP TABLE "t"`    | Yes      |
| SQLite     | Standard SQL (no SERIAL, use INTEGER PK) | `DROP TABLE "t"` | No  |
| MySQL      | `AUTO_INCREMENT` instead of SERIAL | `DROP TABLE "t"`  | No (FK checks) |
| DuckDB     | Standard SQL                     | `DROP TABLE "t"`    | Yes      |

Type mapping for CREATE TABLE:

```lua
-- Common type aliases resolved per adapter
SERIAL     -> PG: SERIAL          SQLite: INTEGER PRIMARY KEY
                  MySQL: INT AUTO_INCREMENT   DuckDB: INTEGER (explicit IDs)
BOOLEAN    -> PG: BOOLEAN         SQLite: INTEGER
                  MySQL: TINYINT(1)           DuckDB: BOOLEAN
TIMESTAMP  -> PG: TIMESTAMPTZ     SQLite: TEXT
                  MySQL: TIMESTAMP            DuckDB: TIMESTAMP
```

### Implementation Plan

```
ddl.lua            NEW  ~300 lines  DDL generation, type mapping, prompts
properties.lua     NEW  ~200 lines  Table properties float (from spec #4)
adapters/*.lua          ~30 lines each  get_table_properties, rename, add, drop, create, drop_table
db.lua                  ~15 lines   DDL facade methods
init.lua                ~40 lines   :GripCreate, :GripDrop, :GripRename, :GripProperties
schema.lua              ~20 lines   D keymap for drop, + for create, R for rename
view.lua                ~10 lines   gI keymap
```

**Scope:** ~700 lines. Two new modules (ddl.lua, properties.lua) + adapter extensions.

---

## 8. Automated Tests + CI

### Test Framework

Use **busted** (Lua test framework) with **plenary.nvim** test harness for
Neovim-specific tests. Two tiers:

**Tier 1: Pure module unit tests (no Neovim needed)**

Run with `busted` directly. Tests for:
- `data.lua` - state transitions, undo, effective_value, NULL sentinel
- `query.lua` - SQL composition, sort/filter/page, spec immutability
- `sql.lua` - quote_value, quote_ident, build_update/insert/delete
- `db.lua` - CSV parser (parse_csv)

**Tier 2: Integration tests (Neovim + plenary)**

Run with `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec"`.
Tests for:
- `view.lua` - render output, cell positioning, byte positions
- `init.lua` - command parsing, resolve_query
- `connections.lua` - profile loading, dedup
- `saved.lua` - save/load round-trip

### File Structure

```
tests/
  minimal_init.lua          -- minimal Neovim config for test runner
  spec/
    data_spec.lua           -- ~150 lines, 20+ test cases
    query_spec.lua          -- ~120 lines, 15+ test cases
    sql_spec.lua            -- ~100 lines, 15+ test cases
    csv_parser_spec.lua     -- ~80 lines, 10+ test cases (from existing test_csv.lua)
    connections_spec.lua    -- ~60 lines
    saved_spec.lua          -- ~60 lines
```

### CI (GitHub Actions)

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: v0.10.0
      - run: |
          git clone --depth 1 https://github.com/nvim-lua/plenary.nvim /tmp/plenary
          git clone --depth 1 https://github.com/tpope/vim-dadbod /tmp/vim-dadbod
      - run: |
          nvim --headless -u tests/minimal_init.lua \
            -c "PlenaryBustedDirectory tests/spec {minimal_init='tests/minimal_init.lua'}"
```

### Test Cases (data_spec.lua example)

```lua
describe("data", function()
  local data = require("dadbod-grip.data")

  describe("new", function()
    it("creates readonly state when no PKs", function()
      local st = data.new({ rows = {}, columns = {"a"}, primary_keys = {} })
      assert.is_true(st.readonly)
    end)

    it("creates editable state with PKs", function()
      local st = data.new({ rows = {}, columns = {"id"}, primary_keys = {"id"}, table_name = "t" })
      assert.is_false(st.readonly)
    end)
  end)

  describe("add_change", function()
    it("stages a cell change without mutating original", function()
      local st = data.new({ rows = {{"1", "alice"}}, columns = {"id", "name"},
                            primary_keys = {"id"}, table_name = "t" })
      local st2 = data.add_change(st, 1, "name", "bob")
      assert.equals("alice", data.effective_value(st, 1, "name"))
      assert.equals("bob", data.effective_value(st2, 1, "name"))
    end)

    it("stores NULL as sentinel", function()
      local st = data.new({ rows = {{"1", "alice"}}, columns = {"id", "name"},
                            primary_keys = {"id"}, table_name = "t" })
      local st2 = data.add_change(st, 1, "name", nil)
      assert.is_nil(data.effective_value(st2, 1, "name"))
    end)
  end)

  describe("undo_row", function()
    it("removes staged changes for a row", function()
      local st = data.new({ rows = {{"1", "a"}}, columns = {"id", "name"},
                            primary_keys = {"id"}, table_name = "t" })
      local st2 = data.add_change(st, 1, "name", "b")
      local st3 = data.undo_row(st2, 1)
      assert.equals("a", data.effective_value(st3, 1, "name"))
    end)
  end)
end)
```

**Scope:** ~570 lines of test code + CI config. No production code changes.

---

## 9. Performance Profiling

### Approach

No new user-facing features. Internal instrumentation + optimization.

**Profiling targets:**
1. `build_render()` on 1000+ rows - currently O(rows * cols) per render
2. `deep_copy()` on large state - currently copies entire state on every edit
3. `parse_csv()` on large result sets - currently builds string per field
4. `calc_col_widths()` on 50+ columns - iterates all rows per column

**Optimization strategies:**

| Bottleneck | Current | Optimized |
|------------|---------|-----------|
| deep_copy on edit | Copies all 1000 rows | Copy-on-write: only copy changed subtrees |
| build_render | Rebuilds all lines | Incremental: only re-render changed rows |
| calc_col_widths | Scans all rows | Sample first 100 + last 10 rows |
| Highlight application | Per-cell extmark | Batch extmark ranges by row |

**Measurement:**
```lua
-- Add to view.lua, gated behind GRIP_PROFILE env var
local function profile(name, fn)
  if not os.getenv("GRIP_PROFILE") then return fn() end
  local start = vim.loop.hrtime()
  local result = fn()
  local elapsed = (vim.loop.hrtime() - start) / 1e6
  print(string.format("[grip] %s: %.1fms", name, elapsed))
  return result
end
```

**Copy-on-write for data.lua** (biggest win):
```lua
-- Instead of deep_copy(state), use structural sharing:
local function cow_copy(state)
  return setmetatable({}, {
    __index = state,
    __newindex = function(t, k, v)
      rawset(t, k, type(v) == "table" and deep_copy(v) or v)
    end,
  })
end
```

For 1000 rows with 10 columns, this reduces per-edit copy from ~10K table
entries to ~20 (only the changed subtree).

**Scope:** ~100 lines of instrumentation, ~50 lines of optimization in data.lua.
No new modules.

---

## Implementation Priority

For a 3-hour sprint, recommended order:

```
1. Column hide/show     ~75 lines   30 min   Completes v1.4
2. Copy/paste cells     ~60 lines   20 min   Completes v1.4
3. Table properties     ~380 lines  60 min   Foundation for DDL
4. Automated tests      ~570 lines  45 min   Confidence for future work
5. Column rename        ~60 lines   15 min   First DDL operation
6. Column add/drop      ~120 lines  20 min   Builds on properties
7. Data diff            ~350 lines  (next session)
8. Create/drop table    ~300 lines  (next session)
9. Performance          ~150 lines  (ongoing)
```

Items 1-6 fit in 3 hours. Items 7-9 are next session.

## Files Created/Modified Summary

| File | Action | Lines |
|------|--------|-------|
| `lua/dadbod-grip/diff.lua` | NEW | ~250 |
| `lua/dadbod-grip/properties.lua` | NEW | ~200 |
| `lua/dadbod-grip/ddl.lua` | NEW | ~300 |
| `lua/dadbod-grip/view.lua` | MODIFY | ~175 |
| `lua/dadbod-grip/init.lua` | MODIFY | ~80 |
| `lua/dadbod-grip/schema.lua` | MODIFY | ~20 |
| `lua/dadbod-grip/db.lua` | MODIFY | ~30 |
| `lua/dadbod-grip/adapters/*.lua` | MODIFY | ~160 total |
| `tests/spec/*.lua` | NEW | ~570 |
| `.github/workflows/test.yml` | NEW | ~25 |
| `doc/dadbod-grip.txt` | MODIFY | ~100 |

**Total new code: ~1,910 lines**
