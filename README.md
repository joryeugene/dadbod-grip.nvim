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
-- lazy.nvim — this is all you need:
{ "joryeugene/dadbod-grip.nvim", dependencies = { "tpope/vim-dadbod" } }
```

Then `:Grip` from any DBUI buffer. That's it.

## Features

- **Inline cell editing** with a popup editor, NULL handling, and type-aware display
- **Immutable state management** with full undo (per-row and global)
- **Stage changes visually** with color-coded rows (blue=modified, red=deleted, green=inserted)
- **Pure SQL generation** with preview before apply
- **Sort, filter, pagination** — `s`/`S` sort, `f`/`<C-f>`/`F` filter, `]p`/`[p` pages
- **Foreign key navigation** — `gf` follows FK to referenced row, `<C-o>` goes back
- **Column statistics** — `gS` shows count, distinct, nulls, min/max, top values
- **Aggregate on selection** — `ga` in visual mode shows count/sum/avg/min/max
- **Export formats** — `gE` picker: CSV, TSV, JSON, SQL INSERT, Markdown
- **EXPLAIN plan viewer** — `:GripExplain` renders color-coded query plans
- **Column pinning** — `1`-`9` freezes leftmost N columns with thick separator, `0` unpins
- **Conditional formatting** — negatives red, booleans colored, past dates dimmed, URLs underlined
- **Multi-database** — PostgreSQL, SQLite, MySQL/MariaDB, DuckDB adapters
- **File-as-table** — `:Grip /path/to/data.parquet` opens Parquet/CSV/JSON/XLSX via DuckDB
- **Composite primary key support** for multi-column WHERE clauses
- **Read-only mode** auto-detected when no primary key exists
- **DBUI integration** via `open_smart()` for seamless two-pane workflow
- **Live SQL floating preview** (`gl`) shows real-time SQL as you stage changes
- **Column type annotations** (`T`) overlays type info on headers
- **Row view transpose** (`K`) vertical column-by-column view of current row
- **Vim-native grid navigation** (`gg`/`G`/`0`/`$`/`{`/`}`/`p`)
- **Enterable info floats** with `Esc` dismiss and scroll support

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
| `o` | Insert new row after cursor |
| `d` | Toggle delete on current row |
| `u` | Undo changes on current row |
| `U` | Undo all staged changes |
| `a` | Apply all staged changes to DB |

### Sort / Filter / Pagination

| Key | Action |
|-----|--------|
| `s` | Toggle sort on column (ASC → DESC → off) |
| `S` | Stack secondary sort on column |
| `f` | Quick filter by cell value |
| `<C-f>` | Freeform WHERE clause filter |
| `F` | Clear all filters |
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
| `gE` | Export table (CSV, TSV, JSON, SQL INSERT, Markdown) |

### Inspection

| Key | Action |
|-----|--------|
| `gs` | Preview staged SQL in float |
| `gc` | Copy staged SQL to clipboard |
| `gi` | Table info (columns, types, PKs) |
| `ge` | Explain cell under cursor |

### Column Pinning

| Key | Action |
|-----|--------|
| `1`-`9` | Pin/freeze N leftmost columns |
| `0` | Unpin all (or first column if none pinned) |

### Advanced

| Key | Action |
|-----|--------|
| `gl` | Toggle live SQL floating preview |
| `T` | Toggle column type annotations |
| `r` | Refresh (re-run query) |
| `q` | Close grip buffer |
| `?` | Show help |

### Commands

| Command | Description |
|---------|-------------|
| `:GripExplain` | Render EXPLAIN plan for current query or given SQL |

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
  -- Optional: override defaults
  -- opts = { limit = 100, max_col_width = 40, timeout = 10000 },
}
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

### Commands

| Command | Description |
|---------|-------------|
| `:Grip` | Smart open: detects DBUI context or uses word under cursor |
| `:Grip users` | Open a specific table |
| `:Grip SELECT * FROM users WHERE active` | Run arbitrary SQL |
| `:Grip /path/to/data.parquet` | Open file as table via DuckDB (Parquet, CSV, JSON, XLSX) |
| `:GripExplain` | Show EXPLAIN plan for current grid's query |
| `:GripExplain SELECT ...` | Show EXPLAIN plan for arbitrary SQL |

### DBUI Integration

For the best experience with [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), use `open_smart()`:

```lua
vim.keymap.set("n", "<leader>lg", function()
  require("dadbod-grip").open_smart()
end, { desc = "Grip: open table grid" })
```

`open_smart()` detects three contexts:

1. **DBUI SQL buffer** (`b:dbui_table_name` set): opens that table, reuses the dbout window
2. **dbout result buffer** (`b:db` is a dict): traces back to the source table name
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

Nine modules with strict boundaries:

```
init.lua    → Entry point. Parses args, wires callbacks, orchestrates modules.
view.lua    → Buffer rendering, keymaps, highlights. One buffer per session.
editor.lua  → Float cell editor. Minimal: one purpose, no state leaked.
data.lua    → Immutable state transforms. All functions: state in, state out.
query.lua   → Pure query composition. Spec (value) → SQL string. No I/O.
db.lua      → I/O boundary + adapter dispatch. Delegates to adapters by URL scheme.
sql.lua     → Pure SQL generation. No DB calls, no state, pure string builders.
adapters/   → Per-database implementations (postgresql, sqlite, mysql, duckdb).
```

Design principles:
- **Immutable state**: `data.lua` never mutates. Every operation returns a new state table.
- **Query as value**: `query.lua` treats query specs as plain Lua tables composed by pure functions.
- **I/O at the boundary**: Only `db.lua` and adapters run shell commands. Everything else is pure.
- **Adapter pattern**: URL scheme → adapter module. Each adapter implements query, execute, get_primary_keys, get_column_info, get_foreign_keys, and explain.

## Testing

### PostgreSQL

```bash
createdb grip_test
psql grip_test < tests/seed.sql
```

### SQLite

```bash
sqlite3 tests/grip_test.db < tests/seed_sqlite.sql
```

### MySQL

```bash
mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
mysql -u root grip_test < tests/seed_mysql.sql
```

### DuckDB

```bash
duckdb tests/grip_test.duckdb < tests/seed_duckdb.sql
```

Test tables cover: normal CRUD, composite PKs, JSON/JSONB, unicode, FK relationships (users → orders → order_items → products), 150+ rows for pagination, and SQL injection attempts. All four seed files have identical table structure for cross-adapter verification.

Open each table with `:Grip <table_name>` and verify rendering, editing, sort/filter/pagination, and FK navigation.

## Related

- [vim-dadbod](https://github.com/tpope/vim-dadbod) — Database adapter layer (`:DB` command, connection URLs, raw query output)
- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui) — Sidebar tree browser, saved queries, two-pane SQL workflow
- [nvim-dadbod-bg](https://github.com/napisani/nvim-dadbod-bg) — Browser-based result viewer (Go webserver + React UI)

dadbod-grip is a **data editor**, not a viewer. The rest of the ecosystem displays query results as read-only text. Grip lets you edit cells, stage changes, preview the SQL, and apply it back to the database.

### Ecosystem Comparison

| Feature | dadbod-grip | [neosql.nvim](https://github.com/h4kbas/neosql.nvim) | [nvim-dbee](https://github.com/kndndrj/nvim-dbee) | [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui) | [lazysql](https://github.com/jorgerojas26/lazysql) | [nvim-dadbod-bg](https://github.com/napisani/nvim-dadbod-bg) |
|---|---|---|---|---|---|---|
| **Cell editing** | Yes | Yes | No | No | Yes (TUI) | No |
| **Change staging** | Yes (visual) | Yes | No | No | No | No |
| **SQL preview** | Yes (live) | No | No | No | No | No |
| **Sort/filter** | Yes | No | No | No | Yes (TUI) | No |
| **Pagination** | Yes | No | No | No | Yes (TUI) | No |
| **FK navigation** | Yes | No | No | No | No | No |
| **Column stats** | Yes | No | No | No | No | No |
| **EXPLAIN viewer** | Yes | No | No | No | No | No |
| **Export formats** | 5 formats | No | No | No | CSV | No |
| **Grid view** | Unicode box | Markdown table | Columnar | Raw text | TUI grid | React table |
| **Column pinning** | Yes (1-9) | No | No | No | No | No |
| **Cell formatting** | Yes (auto) | No | No | No | No | No |
| **File-as-table** | Yes (DuckDB) | No | No | No | No | No |
| **Multi-DB** | PG, SQLite, MySQL, DuckDB | PG only | Yes (Go) | Yes (dadbod) | 3 DBs | Yes (dadbod) |
| **Backend** | Pure Lua | Lua | Go binary | Vimscript | Go TUI | Go + React |
| **Dependencies** | vim-dadbod | psql | None | vim-dadbod | lazysql | vim-dadbod |

## License

[MIT](LICENSE)
