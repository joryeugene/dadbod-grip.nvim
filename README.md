# dadbod-grip.nvim

<table><tr>
<td valign="middle">
<pre>
D   ███████╗███████╗██╗███████╗
A  ██╔═════╝██╔══██║██║██╔══██║
D  ██║  ███╗██████╔╝██║███████║
b  ██║   ██║██╔══██╗██║██╔════╝
o  ╚██████╔╝██║  ██║██║██║
d   ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝
</pre>
<p>
<a href="https://github.com/joryeugene/dadbod-grip.nvim/blob/main/LICENSE"><img src="https://img.shields.io/github/license/joryeugene/dadbod-grip.nvim.svg" alt="MIT License"></a>&nbsp;
<img src="https://img.shields.io/badge/Neovim-0.10%2B-green.svg" alt="Neovim 0.10+">&nbsp;
<img src="https://img.shields.io/badge/requires-vim--dadbod-blue.svg" alt="requires vim-dadbod">
</p>
<b>DataGrip-grade database editing, inside Neovim.</b><br>
Edit data like a GUI. Navigate like Vim. Never leave your editor.
</td>
<td align="center" valign="middle" width="180">
<img src="assets/mascot.gif" width="160" alt="Chonk the dadbod-grip mascot"><br>
<sub><b>Chonk</b> ᕦ( ᐛ )ᕤ</sub>
</td>
</tr></table>

**Edit database tables like Vim buffers.** Visual staging with color-coded rows: modified in blue, inserted green, deleted red. A live SQL float updates as you stage changes. Preview the full mutation SQL before it touches the DB, then apply in a single transaction. Follow foreign keys through a breadcrumb trail. Open Parquet files and remote CSVs as live tables. Profile column distributions with sparklines. Get plain-English EXPLAIN. Generate SQL from natural language across four AI providers. Undo committed transactions. Every Vim motion works. Nothing installs outside Neovim.

| **Editing** | **Analysis** | **Schema & AI** |
|---|---|---|
| **Inline cell editing** popup editor | **Data profiling** sparkline distributions | **FK navigation** breadcrumb trail |
| **Batch edit** visual-mode multi-row ops | **Query Doctor** plain-English EXPLAIN | **DDL** create · rename · drop via UI |
| **Mutation preview** full SQL before apply | **Visual staging** blue · green · red rows | **File as table** Parquet · CSV · remote URLs |
| **Transaction undo** reverse committed changes | **Live SQL preview** float updates as you stage | **AI SQL** Anthropic · OpenAI · Gemini · Ollama |

## Quickstart

```lua
-- lazy.nvim
{ "joryeugene/dadbod-grip.nvim", dependencies = { "tpope/vim-dadbod" } }
```

Then `:GripConnect` to pick your database. That's it. Schema sidebar + query pad open automatically.

## What it looks like

![Schema sidebar, 4 staged mutations, saved queries picker with SQL preview, and Live SQL float](grap.png)

**Left:** Schema browser with PK/FK markers and column types. **Grid:** 4 staged mutations: modified row highlighted blue, deleted row struck through red. **Float:** Saved queries picker with instant SQL preview. **Right:** Live SQL float showing the exact DELETE and UPDATE statements generated as you edit. The SQL is written for you. Nothing hits the database until you press `a`.

## Features

### Data Editing
- **Inline cell editing** with a popup editor, NULL handling, and type-aware display.
- **Visual change staging** with color-coded rows (blue=modified, red=deleted, green=inserted).
- **Pure SQL generation** with live preview before applying changes.
- **Transaction safety** wraps all DML in BEGIN/COMMIT with ROLLBACK on error.
- **Batch editing** in visual mode to set, delete, or NULL multiple rows at once.
- **Two-tier undo + redo**: local staging undo (50-deep) with `<C-r>` redo, plus transaction undo that reverses committed changes (10-deep, with confirmation).
- **Mutation preview**: `UPDATE`, `DELETE`, and `INSERT` from the query pad show affected rows before executing. SET values appear blue (modified), DELETE rows appear red, INSERT rows appear green. Press `a` to execute, `u` to cancel.

### Query and Navigation
- **Sort, filter, and pagination** using `s`/`S` to sort, `f`/`<C-f>`/`F` to filter, `gp`/`gP` for saved filter presets, and `H`/`L` to page (or `]p`/`[p`).
- **Foreign key navigation** via `gf` to follow a FK to its referenced row, and `<C-o>` to go back.
- **Query history** via `gh` or `:GripHistory` browsing all executed queries with timestamp and SQL preview, stored in `.grip/history.jsonl`.
- **Data profiling** via `gR` or `:GripProfile` showing sparkline distributions, completeness, cardinality, and top values per column.
- **Column statistics** via `gS` showing count, distinct, nulls, min/max, and top values.
- **Aggregate on selection** via `ga` in visual mode showing count/sum/avg/min/max.
- **Query Doctor** via `:GripExplain` translating EXPLAIN plans into plain-English health checks with cost bars and index suggestions.
- **AI SQL generation** via `A` or `:GripAsk` turning natural language into SQL queries using Anthropic, OpenAI, Gemini, or local Ollama. AI reads existing query pad SQL to modify it rather than generating from scratch. Schema context cached per connection.

### Schema and Workflow
- **Schema browser** via `:GripSchema` or `gb` showing a sidebar tree with columns, types, and PK/FK markers. `gb` opens/focuses the browser from any buffer; pressing `gb` from inside closes it.
- **Table picker** via `:GripTables` or `gT` / `gt` providing a fuzzy finder with column preview. Available from all three buffers: grid, query pad, and sidebar. In the sidebar, `go` opens the table under cursor with `ORDER BY created_at / PK DESC` so the latest rows appear first.
- **SQL query pad** via `:GripQuery` or `q` opening a scratch buffer that pipes results into editable grids.
- **Saved queries** via `:GripSave` and `:GripLoad` persisting to project-local `.grip/queries/` files.
- **Connection profiles** via `:GripConnect` or `gC` storing connections in `.grip/connections.json` with `g:dbs` backward compatibility. Connections auto-persist globally (`~/.grip/connections.json`) so they're available from any project. Connecting opens the full workspace (schema sidebar + query pad) automatically.
- **Data diff** via `:GripDiff` or `gD` comparing two tables by primary key with color-coded change highlighting. Auto-switches to compact layout on narrow terminals (<120 cols), toggle with `gv`.

### Schema Operations (DDL)
- **Table properties** via `gI` or `:GripProperties` showing columns, indexes, row count, and table size.
- **Column rename** via `R` in properties view or `:GripRename` with DDL preview and confirmation.
- **Column add/drop** via `+` and `-` in properties view with type prompts and destructive confirmation.
- **Create table** via `:GripCreate` or `+` in schema browser with an interactive column designer.
- **Drop table** via `:GripDrop` or `D` in schema browser with typed confirmation and CASCADE awareness.

### Display
- **Conditional formatting** that colors negatives red, booleans green/red, past dates dim, and URLs underlined.
- **Column hide/show** using `-` to hide, `g-` to restore all, and `gH` for a visibility picker.
- **Smart column auto-fit** that distributes extra terminal width to truncated columns.
- **Export** in 6 formats via `gE`: CSV, TSV, JSON, SQL INSERT, Markdown, and Grip Table (box-drawing).

### Multi-Database
- **PostgreSQL, SQLite, MySQL/MariaDB, and DuckDB** adapters with adapter-specific metadata queries.
- **Multi-schema PostgreSQL**: all schemas visible in sidebar (not just `public`). Tables from other schemas appear as `schema.table`.
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
| `i`/`e` | Edit cell under cursor |
| `n` | Set cell to NULL |
| `p` | Paste clipboard into cell |
| `P` | Paste multi-line clipboard into consecutive rows |
| `o` | Insert new row after cursor |
| `d` | Toggle delete on current row |
| `u` | Undo last edit (multi-level) |
| `<C-r>` | Redo |
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
| `H` / `L` | Previous / next page |
| `]p` / `[p` | Previous / next page (alternate) |
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
| `gR` | Table profile (sparkline distributions) |
| `gx` | Query Doctor (plain-English EXPLAIN) |
| `gD` | Diff against another table |
| `gv` | Toggle compact/wide diff layout |
| `gE` | Export table (CSV, TSV, JSON, SQL INSERT, Markdown, Grip Table) |

### Inspection

| Key | Action |
|-----|--------|
| `gs` | Preview staged SQL in float |
| `gc` | Copy staged SQL to clipboard |
| `gi` | Table info (columns, types, PKs) |
| `gI` | Table properties (columns, indexes, stats) |
| `ge` | Explain cell under cursor |

### Schema & Workflow

| Key | Action |
|-----|--------|
| `go` / `gT` / `gt` | Pick table (fuzzy finder) |
| `gb` | Schema browser (focus if open; close from inside) |
| `gC` / `<C-g>` | Switch database connection |
| `gO` | Open read-only query result as editable table |
| `gN` | Rename column under cursor |
| `q` | Open query pad (pre-filled with current query) |
| `gw` | Jump to grid (from query pad or sidebar) |
| `gh` | Query history browser |
| `A` | AI SQL generation (natural language) |

### Advanced

| Key | Action |
|-----|--------|
| `gl` | Toggle live SQL floating preview |
| `T` | Toggle column type annotations |
| `r` | Refresh (re-run query) |
| `:q` | Close grip buffer |
| `?` | Show help |

### Query Pad

| Key | Action |
|-----|--------|
| `<C-CR>` | Execute buffer (normal/insert) or selection (visual) into grip grid |
| `<C-s>` | Save query with `:GripSave` |
| `gq` | Load saved query (picker with SQL preview) |
| `gA` | AI SQL generation (natural language) |
| `go` / `gT` / `gt` | Table picker |
| `gh` | Query history (with SQL preview) |
| `gw` | Jump to grid window |
| `gb` | Schema browser (focus if open; close from inside) |
| `gC` / `<C-g>` | Switch database connection |

### Schema Sidebar

| Key | Action |
|-----|--------|
| `<CR>` | Open table in grid |
| `<S-CR>` | Open table in new split |
| `l` / `zo` | Expand columns |
| `h` / `zc` | Collapse |
| `L` | Expand all |
| `H` | Collapse all |
| `/` | Filter by name |
| `F` | Clear filter |
| `n` / `N` | Next / previous table match |
| `y` | Yank table or column name |
| `r` | Refresh schema |
| `go` | Open table under cursor, ORDER BY latest (created_at / PK DESC) |
| `gT` / `gt` | Table picker (fuzzy finder) |
| `gb` / `<Esc>` | Close sidebar |
| `gw` | Jump to grid |
| `gC` / `gc` / `<C-g>` | Switch connection |
| `gh` | Query history |
| `gq` | Saved queries |
| `q` | Open query pad |
| `D` | Drop table (with confirmation) |
| `+` | Create table |
| `?` | Show help |

### Commands

| Command | Description |
|---------|-------------|
| `:Grip [table\|SQL\|file]` | Open table, run query, or open file as table |
| `:GripSchema` | Toggle schema browser sidebar |
| `:GripTables` | Open table picker with column preview |
| `:GripQuery [sql]` | Open SQL query pad |
| `:GripSave [name]` | Save query pad content to `.grip/queries/` |
| `:GripLoad [name]` | Load a saved query (picker if no name) |
| `:GripHistory` | Browse query history (timestamp + SQL preview) |
| `:GripConnect [url]` | Connect and open workspace (schema + query pad) |
| `:GripExplain [sql]` | Query Doctor: plain-English EXPLAIN with tips |
| `:GripProfile [table]` | Profile columns with sparkline distributions |
| `:GripAsk [question]` | AI SQL generation from natural language |
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
  cmd = { "Grip", "GripSchema", "GripQuery", "GripConnect" },
  keys = {
    { "<leader>db", "<cmd>GripConnect<cr>", desc = "Database" },
  },
  opts = {},
}
```

**Recommended extras:**

```lua
-- SQL completion in query pad (auto-completes table/column names)
{ "kristijanhusak/vim-dadbod-completion", ft = { "sql" } }
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
  timeout       = 30000, -- query timeout in ms (default: 10000; raise for slow tunnels)
})
```

AI SQL generation (optional):

```lua
require("dadbod-grip").setup({
  ai = {
    provider = nil,       -- nil = auto-detect, or "anthropic"/"openai"/"gemini"/"ollama"
    model = nil,          -- nil = provider default
    api_key = nil,        -- nil = env var, "env:VAR", "cmd:op read ...", or direct string
    base_url = nil,       -- override for ollama or proxy
  }
})
```

Provider auto-detection priority: `ANTHROPIC_API_KEY` > `OPENAI_API_KEY` > `GEMINI_API_KEY` > ollama (local). Explicit `provider` setting always wins.

No default keymaps are set outside the grip buffer. Add one if you want:

```lua
vim.keymap.set("n", "<leader>lg", "<cmd>Grip<cr>", { desc = "Open Grip grid" })
```

## Usage

### Standalone Workflow (no DBUI needed)

```
:GripConnect    → pick a database → schema sidebar + query pad open automatically
```

That's the whole setup. One command. From there:
- `<CR>` on a table in the schema sidebar opens the grid
- `<C-CR>` in the query pad runs SQL into a grid
- `A` in the query pad generates SQL from natural language

Everything else (`:GripSchema`, `:GripQuery`, `:GripTables`) still works individually if you prefer.

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

Twenty modules with strict boundaries:

```
init.lua        → Entry point. Commands, callbacks, orchestration.
view.lua        → Buffer rendering, keymaps, highlights. One buffer per session.
editor.lua      → Float cell editor. One purpose, no state leaked.
data.lua        → Immutable state transforms. State in, state out.
query.lua       → Pure query composition. Spec (value) → SQL string.
db.lua          → I/O boundary + adapter dispatch by URL scheme.
sql.lua         → Pure SQL generation. No DB calls, no state.
schema.lua      → Sidebar tree browser. Tables, columns, PK/FK markers, DDL.
picker.lua      → Table picker. grip_picker float with column preview.
query_pad.lua   → SQL scratch buffer → grip grid results.
saved.lua       → Query persistence in .grip/queries/*.sql.
connections.lua → Connection profiles. .grip/connections.json + g:dbs.
filters.lua     → Saved filter presets. .grip/filters.json per table.
properties.lua  → Table properties float. Columns, indexes, stats, DDL keymaps.
ddl.lua         → Schema operations. Rename, add/drop column, create/drop table.
diff.lua        → Data diff engine. PK-matched row comparison with color coding.
history.lua     → Query history. JSONL storage, recording, grip_picker browser.
profile.lua     → Data profiling. Sparkline distributions, column stats.
ai.lua          → AI SQL generation. Multi-provider, schema context assembly.
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
- **[vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)** is a sidebar tree browser with saved queries and two-pane SQL workflow. Optional since grip has its own schema browser and query pad.

---

<p align="center"><pre>
╔══╦══════════╦══════════════════╦═════╗
║  ║ name     ║ email            ║ age ║
╠══╬══════════╬══════════════════╬═════╣
║  ║ chonk    ║ chonk@dadbod.vim ║  37 ║
╚══╩══════════╩══════════════════╩═════╝
</pre>
<sub><b>dadbod-grip.nvim</b> · edit data like a vim buffer · <a href="https://github.com/joryeugene/dadbod-grip.nvim">github</a></sub></p>
