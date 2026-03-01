# dadbod-grip.nvim

<p align="center">
  <a href="https://github.com/joryeugene/dadbod-grip.nvim/blob/main/LICENSE"><img src="https://img.shields.io/github/license/joryeugene/dadbod-grip.nvim.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/Neovim-0.10%2B-green.svg" alt="Neovim 0.10+">
  <img src="https://img.shields.io/badge/requires-vim--dadbod-blue.svg" alt="requires vim-dadbod">
</p>

<p align="center">

```
      ██████╗ ██████╗ ██╗██████╗
     ██╔════╝ ██╔══██╗██║██╔══██╗
     ██║  ███╗██████╔╝██║██████╔╝
     ██║   ██║██╔══██╗██║██╔═══╝
     ╚██████╔╝██║  ██║██║██║
      ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝

     DataGrip-style grids for Neovim
     powered by vim-dadbod
```

</p>


## Quickstart

```lua
-- lazy.nvim
{ "joryeugene/dadbod-grip.nvim", dependencies = { "tpope/vim-dadbod" } }
```

Then `:GripConnect` to set your database, `:GripSchema` to browse, and `:Grip` to open a table. Works standalone or alongside vim-dadbod-ui.

## What it looks like

### Editable data grid with staged changes

```
╔═ users [3 staged] ══════════════════════════════════════════╗
║ id   │ name          │ email                │ age ▲         ║
╠══════╪═══════════════╪══════════════════════╪═══════════════╣
║ 1    │ alice         │ alice@example.com    │ 30            ║
║ 2    │ bob_updated   │ bob@example.com      │ ·NULL·        ║
║ +    │ carol         │ carol@example.com    │ 28            ║
║ ×    │ dave          │ dave@example.com     │ 55            ║
╚══════╧═══════════════╧══════════════════════╧═══════════════╝
 Page 1/3 (75 rows)  │  3 staged  │  sorted: age ASC
 e:edit  o:insert  d:delete  a:apply  u:undo  r:refresh  ?:help
```

`bob_updated` = modified (blue), `+` = inserted (green), `×` = deleted (red), `·NULL·` = null (dim)

### Schema browser sidebar with grid

```
 mydb                ╔═ orders ═════════════════════════════╗
                     ║ id │ customer  │ total    │ status   ║
 Tables (5)          ╠════╪═══════════╪══════════╪══════════╣
 ▶ customers         ║ 1  │ Alice     │  99.50   │ active   ║
 ▼ orders            ║ 2  │ Bob       │ -12.00   │ pending  ║
   🔑 id       int   ║ 3  │ Carol     │ 250.00   │ active   ║
   🔗 cust_id  int   ╚════╧═══════════╧══════════╧══════════╝
 ▶ products           Page 1/2  │  filter: status='active'
```

Left: schema sidebar with PK/FK markers. Right: filtered grid. `-12.00` = negative (red).

### Foreign key navigation breadcrumb trail

```
╔═ users > orders > items ═══════════════════════════════════╗
║ id │ order_id │ product    │ qty │ price                   ║
╠════╪══════════╪════════════╪═════╪═════════════════════════╣
║ 1  │ 42       │ Widget     │ 3   │  9.99                   ║
║ 2  │ 42       │ Gadget     │ 1   │ 24.50                   ║
╚════╧══════════╧════════════╧═════╧═════════════════════════╝
 2 rows  │  read-only: no PK
 gf:follow FK  <C-o>:go back  q:close
```

Title bar shows the full navigation path. `gf` on any FK cell drills into the referenced table.

### Table properties float

```
╭────────────── Table Properties ──────────────╮
│                                              │
│  Table: users     Rows: ~12.5K  Size: 2.3MB  │
│                                              │
│  Columns                                     │
│  # Name       Type         Null Default      │
│  ─────────────────────────────────────────── │
│  1 id         integer      NO           PK   │
│  2 name       varchar(50)  NO                │
│  3 email      varchar(255) YES               │
│  4 org_id     integer      YES          FK   │
│                                              │
│  Primary Key: (id)                           │
│  Foreign Keys: org_id -> orgs(id)            │
│  Indexes: users_pkey ... PRIMARY (id)        │
│                                              │
│  q:close  R:rename  +:add  x:drop            │
╰──────────────────────────────────────────────╯
```

Full table metadata: columns, types, PKs, FKs, indexes, row estimates, and size.

## Features

### Data Editing
- **Inline cell editing** with a popup editor, NULL handling, and type-aware display.
- **Visual change staging** with color-coded rows (blue=modified, red=deleted, green=inserted).
- **Pure SQL generation** with live preview before applying changes.
- **Transaction safety** wraps all DML in BEGIN/COMMIT with ROLLBACK on error.
- **Batch editing** in visual mode to set, delete, or NULL multiple rows at once.
- **Immutable state management** with multi-level undo (50-deep stack).

### Query and Navigation
- **Sort, filter, and pagination** using `s`/`S` to sort, `f`/`<C-f>`/`F` to filter, `gp`/`gP` for saved filter presets, and `]p`/`[p` to page.
- **Foreign key navigation** via `gf` to follow a FK to its referenced row, and `<C-o>` to go back.
- **Query history** via `gh` or `:GripHistory` browsing all executed queries with Telescope search, stored in `.grip/history.jsonl`.
- **Column statistics** via `gS` showing count, distinct, nulls, min/max, and top values.
- **Aggregate on selection** via `ga` in visual mode showing count/sum/avg/min/max.
- **EXPLAIN plan viewer** via `:GripExplain` rendering color-coded query plans.

### Schema and Workflow
- **Schema browser** via `:GripSchema` or `go` showing a sidebar tree with columns, types, and PK/FK markers.
- **Table picker** via `:GripTables` or `gT` providing a fuzzy finder with column preview.
- **SQL query pad** via `:GripQuery` or `gQ` opening a scratch buffer that pipes results into editable grids.
- **Saved queries** via `:GripSave` and `:GripLoad` persisting to project-local `.grip/queries/` files.
- **Connection profiles** via `:GripConnect` storing connections in `.grip/connections.json` with `g:dbs` backward compatibility.
- **Data diff** via `:GripDiff` or `gD` comparing two tables by primary key with color-coded change highlighting. Auto-switches to compact layout on narrow terminals (<120 cols), toggle with `gv`.

### Schema Operations (DDL)
- **Table properties** via `gI` or `:GripProperties` showing columns, indexes, row count, and table size.
- **Column rename** via `R` in properties view or `:GripRename` with DDL preview and confirmation.
- **Column add/drop** via `+` and `-` in properties view with type prompts and destructive confirmation.
- **Create table** via `:GripCreate` or `+` in schema browser with an interactive column designer.
- **Drop table** via `:GripDrop` or `D` in schema browser with typed confirmation and CASCADE awareness.

### Display
- **Column pinning** using `1`-`9` to freeze leftmost N columns with a thick separator, and `0` to unpin.
- **Conditional formatting** that colors negatives red, booleans green/red, past dates dim, and URLs underlined.
- **Column hide/show** using `-` to hide, `g-` to restore all, and `gH` for a visibility picker.
- **Smart column auto-fit** that distributes extra terminal width to truncated columns.
- **Export** in 6 formats via `gE`: CSV, TSV, JSON, SQL INSERT, Markdown, and Grip Table (box-drawing).

### Multi-Database
- **PostgreSQL, SQLite, MySQL/MariaDB, and DuckDB** adapters with adapter-specific metadata queries.
- **File-as-table** support where `:Grip /path/to/data.parquet` opens Parquet/CSV/JSON/XLSX files via DuckDB.
- **Remote file querying** where `:Grip https://example.com/data.csv` opens remote files via DuckDB httpfs.

### Additional
- **Composite primary key support** for multi-column WHERE clauses.
- **Read-only mode** is auto-detected when no primary key exists.
- **DBUI integration** via `open_smart()` is optional since grip works standalone.
- **Live SQL floating preview** via `gl` shows real-time SQL as you stage changes.
- **Column type annotations** via `T` overlays type info on headers.
- **Row view transpose** via `K` shows a vertical column-by-column view of the current row.

## Keybindings

All keybindings are buffer-local to the grip grid. Press `?` for in-buffer help.

### Navigation

| Key | Action |
|-----|--------|
| `j`/`k` | Move between rows |
| `h`/`l` | Move cursor within row |
| `w`/`b` | Next / previous column |
| `Tab`/`S-Tab` | Next / previous column |
| `gg` | First data row |
| `G` | Last data row |
| `0`/`^` | First column |
| `$` | Last column |
| `-` | Hide column under cursor |
| `g-` | Restore all hidden columns |
| `gH` | Column visibility picker |
| `{`/`}` | Previous / next modified row |
| `<CR>` | Expand cell value in popup |
| `K` | Row view (vertical transpose) |
| `y` | Yank cell value to clipboard |
| `Y` | Yank row as CSV |
| `gY` | Yank entire table as CSV |

### Editing

| Key | Action |
|-----|--------|
| `e` | Edit cell under cursor |
| `n` | Set cell to NULL |
| `p` | Paste clipboard into cell |
| `P` | Paste multi-line clipboard into consecutive rows |
| `o` | Insert new row after cursor |
| `d` | Toggle delete on current row |
| `u` | Undo last edit (multi-level) |
| `U` | Undo all (reset to original) |
| `a` | Apply all staged changes to DB |

### Batch Editing (visual mode)

| Key | Action |
|-----|--------|
| `e` | Set all selected cells in column to same value |
| `d` | Toggle delete on all selected rows |
| `n` | Set all selected cells in column to NULL |
| `y` | Yank selected cells in column (newline-separated) |

### Sort / Filter / Pagination

| Key | Action |
|-----|--------|
| `s` | Toggle sort on column (ASC → DESC → off) |
| `S` | Stack secondary sort on column |
| `f` | Quick filter by cell value |
| `<C-f>` | Freeform WHERE clause filter |
| `F` | Clear all filters |
| `gp` | Load saved filter preset |
| `gP` | Save current filter as preset |
| `X` | Reset view (clear sort/filter/page) |
| `]p` / `[p` | Next / previous page |
| `]P` / `[P` | Last / first page |

### FK Navigation

| Key | Action |
|-----|--------|
| `gf` | Follow foreign key under cursor |
| `<C-o>` | Go back in FK navigation stack |

### Analysis & Export

| Key | Action |
|-----|--------|
| `ga` | Aggregate selected cells (visual mode) |
| `gS` | Column statistics popup |
| `gx` | Explain current query plan |
| `gD` | Diff against another table |
| `gh` | Query history browser |
| `gE` | Export table (CSV, TSV, JSON, SQL INSERT, Markdown, Grip Table) |

### Inspection

| Key | Action |
|-----|--------|
| `gs` | Preview staged SQL in float |
| `gc` | Copy staged SQL to clipboard |
| `gi` | Table info (columns, types, PKs) |
| `gI` | Table properties (columns, indexes, stats) |
| `ge` | Explain cell under cursor |

### Column Pinning

| Key | Action |
|-----|--------|
| `1`-`9` | Pin/freeze N leftmost columns |
| `0` | Unpin all (or first column if none pinned) |

### Schema & Workflow

| Key | Action |
|-----|--------|
| `go` | Toggle schema browser sidebar |
| `gT` | Pick table (fuzzy finder) |
| `gQ` | Open query pad (pre-filled with current query) |
| `gh` | Query history browser |

### Advanced

| Key | Action |
|-----|--------|
| `gl` | Toggle live SQL floating preview |
| `T` | Toggle column type annotations |
| `r` | Refresh (re-run query) |
| `q` | Close grip buffer |
| `?` | Show help |

### Query Pad

| Key | Action |
|-----|--------|
| `<C-CR>` | Execute buffer into grip grid (normal/insert) |
| `<C-CR>` | Execute visual selection into grip grid (visual) |
| `<C-s>` | Save query with `:GripSave` |

### Commands

| Command | Description |
|---------|-------------|
| `:Grip [table\|SQL\|file]` | Open table, run query, or open file as table |
| `:GripSchema` | Toggle schema browser sidebar |
| `:GripTables` | Open table picker (telescope/fzf-lua/native) |
| `:GripQuery [sql]` | Open SQL query pad |
| `:GripSave [name]` | Save query pad content to `.grip/queries/` |
| `:GripLoad [name]` | Load a saved query (picker if no name) |
| `:GripHistory` | Browse query history (telescope/fzf-lua/native) |
| `:GripConnect [url]` | Switch database connection (picker if no arg) |
| `:GripExplain [sql]` | Render EXPLAIN plan for current or given query |
| `:GripProperties [table]` | Show table properties (columns, indexes, stats) |
| `:GripRename old new` | Rename a column in the current table |
| `:GripCreate` | Create a new table interactively |
| `:GripDiff {table1} {table2}` | Compare two tables by PK (compact/wide, toggle `gv`) |
| `:GripDrop [table]` | Drop a table with typed confirmation |

## Requirements

- **Neovim 0.10+**
- **[vim-dadbod](https://github.com/tpope/vim-dadbod)**
- One or more database CLI tools in PATH:
  - **PostgreSQL**: `psql`
  - **SQLite**: `sqlite3`
  - **MySQL/MariaDB**: `mysql` (8.0.3+ for `--csv`, or MariaDB 10.5+)
  - **DuckDB**: `duckdb`

## Install

### lazy.nvim (recommended)

```lua
{
  "joryeugene/dadbod-grip.nvim",
  dependencies = { "tpope/vim-dadbod" },
  cmd = { "Grip", "GripSchema", "GripTables", "GripQuery", "GripConnect" },
  keys = {
    { "<leader>lg", function() require("dadbod-grip").open_smart() end, desc = "Grip: Open grid" },
    { "<leader>gs", "<cmd>GripSchema<cr>", desc = "Grip: Schema browser" },
    { "<leader>gt", "<cmd>GripTables<cr>", desc = "Grip: Table picker" },
    { "<leader>gq", "<cmd>GripQuery<cr>", desc = "Grip: Query pad" },
    { "<leader>gc", "<cmd>GripConnect<cr>", desc = "Grip: Connect" },
  },
  opts = {},
}
```

**Recommended extras:**

```lua
-- SQL completion in query pad (auto-completes table/column names)
{ "kristijanhusak/vim-dadbod-completion", ft = { "sql" } }

-- Better picker UX (optional, grip falls back to vim.ui.select)
{ "nvim-telescope/telescope.nvim" }  -- or { "ibhagwan/fzf-lua" }
```

### packer.nvim

```lua
use {
  "joryeugene/dadbod-grip.nvim",
  requires = { "tpope/vim-dadbod" },
}
```

## Configuration

`setup()` is called automatically by the plugin loader with sensible defaults. Override if needed:

```lua
require("dadbod-grip").setup({
  limit         = 100,   -- default row limit for SELECT queries
  max_col_width = 40,    -- max display width per column
  timeout       = 10000, -- psql timeout in milliseconds
})
```

No default keymaps are set outside the grip buffer. Add one if you want:

```lua
vim.keymap.set("n", "<leader>lg", "<cmd>Grip<cr>", { desc = "Open Grip grid" })
```

## Usage

### Standalone Workflow (no DBUI needed)

```
:GripConnect                   → pick or add a database connection
:GripSchema  (or go in grid)   → browse tables with columns + types
:GripTables  (or gT in grid)   → fuzzy-pick a table → opens grid
:GripQuery   (or gQ in grid)   → open SQL scratch pad → C-CR runs → grid
:GripSave name                 → save query to .grip/queries/
:GripLoad                      → pick and load a saved query
```

### Quick Examples

```
:Grip users                           → open table in editable grid
:Grip SELECT * FROM orders LIMIT 50   → run arbitrary SQL
:Grip /path/to/data.parquet           → open file via DuckDB
:Grip https://example.com/data.csv   → open remote file via httpfs
:GripExplain                          → EXPLAIN current query
```

### DBUI Integration (optional)

If you also use [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), `open_smart()` detects DBUI context:

1. **DBUI SQL buffer**: opens that table, reuses the dbout window
2. **dbout result buffer**: traces back to the source table name
3. **Normal buffer**: uses the word under cursor as a table name

### Public API

```lua
local grip = require("dadbod-grip")

-- Optional config override (auto-called with defaults by plugin loader)
grip.setup(opts)

-- Direct open: table name or SQL, connection URL, view options
grip.open("users", "postgresql://localhost/mydb", { reuse_win = winid })

-- Smart open: auto-detects DBUI context
grip.open_smart()
```

## Architecture

Eighteen modules with strict boundaries:

```
init.lua        → Entry point. Commands, callbacks, orchestration.
view.lua        → Buffer rendering, keymaps, highlights. One buffer per session.
editor.lua      → Float cell editor. One purpose, no state leaked.
data.lua        → Immutable state transforms. State in, state out.
query.lua       → Pure query composition. Spec (value) → SQL string.
db.lua          → I/O boundary + adapter dispatch by URL scheme.
sql.lua         → Pure SQL generation. No DB calls, no state.
schema.lua      → Sidebar tree browser. Tables, columns, PK/FK markers, DDL.
picker.lua      → Table picker. Telescope → fzf-lua → vim.ui.select.
query_pad.lua   → SQL scratch buffer → grip grid results.
saved.lua       → Query persistence in .grip/queries/*.sql.
connections.lua → Connection profiles. .grip/connections.json + g:dbs.
filters.lua     → Saved filter presets. .grip/filters.json per table.
properties.lua  → Table properties float. Columns, indexes, stats, DDL keymaps.
ddl.lua         → Schema operations. Rename, add/drop column, create/drop table.
diff.lua        → Data diff engine. PK-matched row comparison with color coding.
history.lua     → Query history. JSONL storage, recording, 3-tier picker.
adapters/       → Per-database: postgresql, sqlite, mysql, duckdb.
```

Design principles:
- **Immutable state**: `data.lua` never mutates. Every operation returns a new state table.
- **Query as value**: `query.lua` treats query specs as plain Lua tables composed by pure functions.
- **I/O at the boundary**: Only `db.lua` and adapters run shell commands. Everything else is pure.
- **Adapter pattern**: URL scheme → adapter module. Each adapter implements query, execute, get_primary_keys, get_column_info, get_foreign_keys, get_indexes, get_table_stats, list_tables, and explain.
- **Transaction safety**: Apply wraps all DML in BEGIN/COMMIT with ROLLBACK on error.

## Testing

### PostgreSQL

```bash
createdb grip_test
psql grip_test < tests/seed_pg.sql
```

### SQLite

```bash
sqlite3 tests/seed_sqlite.db < tests/seed_sqlite.sql
```

### MySQL

```bash
mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
mysql -u root grip_test < tests/seed_mysql.sql
```

### DuckDB

```bash
duckdb tests/seed_duckdb.duckdb < tests/seed_duckdb.sql
```

The SQLite DB (`tests/seed_sqlite.db`) is committed to the repo for zero-setup testing. Seed files share the same 13 tables + 1 view but each has adapter-specific types in `type_zoo` (e.g. PostgreSQL TSVECTOR/RANGE/MACADDR, MySQL SET/YEAR/GEOMETRY, DuckDB HUGEINT/STRUCT/MAP/UNION, SQLite type affinity coercion).

Open each table with `:Grip <table_name>` and verify rendering, editing, sort/filter/pagination, and FK navigation.

## Ecosystem

### Required

- **[vim-dadbod](https://github.com/tpope/vim-dadbod)** provides the database adapter layer (`:DB` command, connection URLs).

### Recommended

- **[vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion)** adds SQL table and column completion in the query pad.
- **[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)** or **[fzf-lua](https://github.com/ibhagwan/fzf-lua)** for better fuzzy picker UX in `:GripTables` and `:GripLoad`.

### Other tools in the ecosystem

- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui) is a sidebar tree browser with saved queries and two-pane SQL workflow. Optional since grip has its own schema browser and query pad.
- [nvim-dadbod-bg](https://github.com/napisani/nvim-dadbod-bg) is a browser-based result viewer built with Go and React.
- [neosql.nvim](https://github.com/h4kbas/neosql.nvim) is a Lua-based cell editor for PostgreSQL only.
- [nvim-dbee](https://github.com/kndndrj/nvim-dbee) uses a Go binary backend with columnar display.
- [lazysql](https://github.com/jorgerojas26/lazysql) is a standalone Go TUI database client.

### Comparison

| Feature | dadbod-grip | neosql.nvim | nvim-dbee | vim-dadbod-ui | lazysql |
|---|---|---|---|---|---|
| **Cell editing** | Yes | Yes | No | No | Yes (TUI) |
| **Change staging** | Yes (visual) | Yes | No | No | No |
| **SQL preview** | Yes (live) | No | No | No | No |
| **Sort/filter** | Yes | No | No | No | Yes (TUI) |
| **FK navigation** | Yes | No | No | No | No |
| **Schema browser** | Yes (columns+types) | No | No | Yes (names only) | Yes |
| **Query pad** | Yes (→ grid) | No | No | Yes (→ text) | Yes |
| **Saved queries** | Yes | No | No | Yes | No |
| **Connections** | Yes | No | No | Yes | Yes |
| **Column stats** | Yes | No | No | No | No |
| **EXPLAIN** | Yes (colored) | No | No | No | No |
| **Export** | 6 formats | No | No | No | CSV |
| **Column pinning** | Yes (1-9) | No | No | No | No |
| **Batch edit** | Yes (visual) | No | No | No | No |
| **Multi-level undo** | Yes (50-deep) | No | No | No | No |
| **Cell formatting** | Yes (auto) | No | No | No | No |
| **Table properties** | Yes | No | No | No | No |
| **DDL operations** | Yes (5 ops) | No | No | No | No |
| **Data diff** | Yes (PK-matched) | No | No | No | No |
| **File-as-table** | Yes (DuckDB) | No | No | No | No |
| **Transactions** | Yes (atomic) | No | No | No | No |
| **Multi-DB** | PG, SQLite, MySQL, DuckDB | PG only | Yes (Go) | Yes (dadbod) | 3 DBs |
| **Backend** | Pure Lua | Lua | Go binary | Vimscript | Go TUI |

## License

[MIT](LICENSE)
