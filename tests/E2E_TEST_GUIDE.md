# dadbod-grip.nvim -- E2E Test Guide

Manual QA checklist for v2 release. Run through each section against at least
SQLite (fastest) and one client-server DB (PostgreSQL or MySQL).

## TLDR

```bash
just seed-sqlite              # seed test DB (30 seconds)
just dev-sqlite               # launch Neovim connected to it
:Grip users                   # open grid -- you should see 15 rows
```

Then work through the checklists below. Each section is independent.

---

## 1. Setup

### Prerequisites

| Tool | Check | Install |
|------|-------|---------|
| Neovim 0.10+ | `nvim --version` | https://neovim.io |
| vim-dadbod | lazy.nvim dep | `tpope/vim-dadbod` |
| sqlite3 | `sqlite3 --version` | `apt install sqlite3` |
| psql | `psql --version` | `apt install postgresql-client` |
| mysql | `mysql --version` | `apt install mysql-client` |
| duckdb | `duckdb --version` | https://duckdb.org |
| just | `just --version` | `cargo install just` |

### Seed Databases

```bash
just seed-sqlite                # -> tests/grip_test.db
just seed-pg                    # -> grip_test database
just seed-mysql                 # -> grip_test database
just seed-duckdb                # -> tests/grip_test.duckdb
```

All seeds create the same 13 tables + 1 view:

| Table | Rows | Tests |
|-------|------|-------|
| `users` | 15 | CRUD, sort, filter, FK parent |
| `products` | 10 | FK parent for orders |
| `orders` | 12 | FK middle, references users and products |
| `order_items` | 20 | FK leaf, composite PK |
| `composite_pk` | 5 | Two-column PK editing |
| `json_data` | 5 | JSON/JSONB cell display |
| `unicode_fun` | 5 | Multibyte characters, emoji |
| `wide_table` | 10 | 15+ columns, horizontal scroll |
| `binary_blobs` | 3 | Binary display, read-only cells |
| `empty_table` | 0 | Empty state rendering |
| `type_zoo` | 5 | Every data type the adapter supports |
| `long_values` | 5 | Truncation, cell expand |
| `no_pk_view` | 15 | Read-only mode (view, no PK) |

### Connection URLs

| DB | URL |
|----|-----|
| SQLite | `sqlite:tests/grip_test.db` |
| PostgreSQL | `postgresql://localhost/grip_test` |
| MySQL | `mysql://root@localhost/grip_test` |
| DuckDB | `duckdb:tests/grip_test.duckdb` |

---

## 2. Unit Tests

```bash
just test                       # run all 197 specs
```

Expected: `RESULT: ALL TESTS PASSED` with 8 spec files:

| Spec | Tests | What it covers |
|------|-------|----------------|
| adapter_spec | 29 | URL parsing, affected-row patterns, PRAGMA quoting |
| csv_parser_spec | 15 | RFC 4180 parsing, multiline, escaping |
| data_spec | 33 | Immutable state transforms, undo, staging |
| ddl_spec | 18 | DDL SQL generation, module scoping |
| init_spec | 22 | Query routing, file-as-table detection |
| query_spec | 37 | Query composition, sort/filter/pagination |
| sql_spec | 19 | SQL quoting, UPDATE/INSERT/DELETE generation |
| view_spec | 24 | Cell classification, conditional formatting |

---

## 3. Grid View Checklist

Open a table: `:Grip users`

### Navigation
- [ ] `j`/`k` move between rows
- [ ] `h`/`l` move cursor within row
- [ ] `w`/`b` jump to next/prev column
- [ ] `Tab`/`S-Tab` jump to next/prev column
- [ ] `gg` jumps to first data row
- [ ] `G` jumps to last data row
- [ ] `^` jumps to first column
- [ ] `$` jumps to last column
- [ ] `0` jumps to first column (or unpins if pinned)
- [ ] `{`/`}` jump to prev/next modified row
- [ ] `K` opens row view (vertical transpose)
- [ ] `CR` expands cell value in popup

### Editing (on `users` table, has PK)
- [ ] `e` on a cell opens float editor, type new value, `CR` saves
- [ ] `Esc` in editor cancels without saving
- [ ] Modified cell turns blue in grid
- [ ] `n` sets cell to NULL (shows `*NULL*` dim)
- [ ] `o` inserts a new row (green highlight)
- [ ] `d` toggles delete on a row (red strikethrough)
- [ ] `u` undoes the last edit
- [ ] `U` undoes all edits back to original
- [ ] `p` pastes clipboard into cell
- [ ] `a` applies staged changes (confirm dialog), then refreshes

### Read-Only (on `no_pk_view`)
- [ ] `:Grip no_pk_view` opens with `[read-only: no PK]` in title
- [ ] `e`, `o`, `d`, `n`, `a` all show "Read-only" notification
- [ ] Navigation still works normally

### Sort
- [ ] `s` on `age` column: first press sorts ASC (arrow up in header)
- [ ] `s` again: sorts DESC (arrow down)
- [ ] `s` again: removes sort
- [ ] `S` adds a secondary sort (shows numbered arrows)

### Filter
- [ ] `f` on a cell filters by that cell's value
- [ ] `C-f` opens freeform WHERE input, type `age > 25`, confirm
- [ ] Status line shows filter description
- [ ] `F` clears all filters
- [ ] `X` resets view (clears sort + filter)

### Pagination
- [ ] Status line shows `Page 1/N (rows)`
- [ ] `]p` goes to next page
- [ ] `[p` goes to previous page
- [ ] `]P` goes to last page
- [ ] `[P` goes to first page

### Column Pinning
- [ ] `1` pins the first column (thick `|` separator appears)
- [ ] `3` pins the first 3 columns
- [ ] `0` unpins all columns
- [ ] Title bar shows `N pinned`

### Column Hide/Show
- [ ] `-` hides the column under cursor
- [ ] `g-` restores all hidden columns
- [ ] `gH` opens column visibility picker
- [ ] Title bar shows `N hidden`

### Type Annotations
- [ ] `T` toggles a type row under the header

### Conditional Formatting
- [ ] Negative numbers appear red (test with `orders.total` if negative)
- [ ] Boolean `true`/`false` appears green/red (test with `type_zoo`)
- [ ] URLs appear underlined blue
- [ ] Past dates appear dim italic

### Copy/Export
- [ ] `y` yanks cell value to clipboard
- [ ] `Y` yanks row as CSV
- [ ] `gY` yanks entire table as CSV
- [ ] `gE` opens export format picker (CSV, TSV, JSON, SQL INSERT, Markdown)

### Inspection
- [ ] `gs` shows staged SQL preview in float
- [ ] `gc` copies staged SQL to clipboard
- [ ] `gi` shows table info (columns, types, PKs)
- [ ] `ge` explains the cell under cursor (type, nullable, default)
- [ ] `gl` toggles live SQL preview float (updates as you edit)

### Visual Mode Batch Editing
- [ ] Select rows with `V`, then `e` sets all selected cells to a value
- [ ] Select rows with `V`, then `d` toggles delete on all selected
- [ ] Select rows with `V`, then `n` sets all selected cells to NULL
- [ ] Select rows with `V`, then `y` yanks selected cells

### Help
- [ ] `?` opens help popup with ASCII art and all keymaps
- [ ] `q` or `Esc` closes it

---

## 4. FK Navigation Checklist

- [ ] `:Grip orders` to open orders table
- [ ] Move to a `user_id` cell, press `gf`
- [ ] Should open `users` table filtered to that FK value
- [ ] Title bar shows breadcrumb: `orders > users`
- [ ] `C-o` goes back to `orders`
- [ ] Navigate deeper: `gf` from `orders` to `order_items`
- [ ] Breadcrumb shows `orders > order_items`
- [ ] `C-o` twice returns to original `orders` view

---

## 5. Schema Browser Checklist

- [ ] `go` (from grid) or `:GripSchema` opens left sidebar
- [ ] Connection name shown at top
- [ ] `Tables (N)` header with all tables listed
- [ ] `Views (N)` header with views listed
- [ ] `CR` on a table opens it in the grid
- [ ] `l` or `zo` expands a table to show columns
- [ ] Column markers: key emoji for PK, link emoji for FK
- [ ] `h` or `zc` collapses table
- [ ] `L` expands all, `H` collapses all
- [ ] `/` filters tables by name
- [ ] `r` refreshes schema
- [ ] `D` on a table prompts to drop it
- [ ] `+` opens `:GripCreate`
- [ ] `q` or `Esc` closes sidebar
- [ ] `go` again closes sidebar (toggle)

---

## 6. Query Pad Checklist

- [ ] `gQ` (from grid) or `:GripQuery` opens SQL scratch buffer
- [ ] Buffer has `ft=sql` (syntax highlighting works)
- [ ] Type `SELECT * FROM users WHERE age > 30`
- [ ] `C-CR` in normal mode runs the query, results open in grip grid
- [ ] `C-CR` in insert mode stops insert and runs
- [ ] Visual select part of a query, `C-CR` runs only the selection
- [ ] `C-s` or `:w` prompts to save the query
- [ ] `:GripLoad` loads a saved query back into the pad

---

## 7. Table Properties Checklist

- [ ] `:GripProperties users` or `gI` from a users grid
- [ ] Float shows: table name, row estimate, size
- [ ] Columns table with #, Name, Type, Null, Default
- [ ] PK and FK markers on relevant columns
- [ ] Primary Key section lists PK columns
- [ ] Foreign Keys section lists FK relationships
- [ ] Indexes section with dotted alignment
- [ ] `R` on a column row prompts to rename
- [ ] `+` prompts to add a new column
- [ ] `x` on a column row prompts to drop it (typed confirmation)
- [ ] `gI` refreshes the properties view
- [ ] `q` or `Esc` closes

---

## 8. DDL Operations Checklist

### Create Table
- [ ] `:GripCreate` prompts for table name
- [ ] Enter column names and types (blank name finishes)
- [ ] Shows DDL preview, press `y` to confirm
- [ ] Table appears in schema browser after refresh

### Drop Table
- [ ] `:GripDrop test_table` prompts for typed confirmation
- [ ] Must type the exact table name to confirm
- [ ] Table is removed, schema browser refreshes

### Rename Column
- [ ] `:GripRename old_name new_name` on a table
- [ ] Or `R` in properties view on a column row
- [ ] Column name changes in schema and grid

---

## 9. Data Diff Checklist

- [ ] `:GripDiff users users` (diff table against itself)
- [ ] Should show "0 changed, 0 only-left, 0 only-right"
- [ ] All rows shown as unchanged (hidden by default)
- [ ] `q` closes diff
- [ ] Make a change to `users`, then diff against a copy to see highlights

---

## 10. EXPLAIN Plan Checklist

- [ ] `:GripExplain SELECT * FROM users WHERE age > 30`
- [ ] Float opens with query plan
- [ ] Cost-based color coding: green (low), yellow (medium), red (high)
- [ ] `q` closes

---

## 11. Connection Profiles Checklist

- [ ] `:GripConnect sqlite:tests/grip_test.db` switches connection
- [ ] `:GripConnect` with no arg opens connection picker
- [ ] Saved connections persist in `.grip/connections.json`
- [ ] `vim.g.db` and `g:dbs` are respected as fallbacks

---

## 12. Adapter-Specific Tests

Run each adapter through the core flow: open table, edit, apply, verify.

### SQLite
```
:GripConnect sqlite:tests/grip_test.db
:Grip users
```
- [ ] Grid renders 15 rows
- [ ] Edit a cell, apply, refresh -- change persists
- [ ] `gf` on `orders.user_id` navigates to `users`
- [ ] `:GripProperties users` shows PRAGMA-derived metadata
- [ ] `:GripExplain SELECT * FROM users` shows EXPLAIN QUERY PLAN

### PostgreSQL
```
:GripConnect postgresql://localhost/grip_test
:Grip users
```
- [ ] Grid renders 15 rows
- [ ] Edit, apply, refresh -- change persists
- [ ] FK navigation works (information_schema)
- [ ] Properties shows indexes, row estimate, size
- [ ] EXPLAIN shows cost-colored plan with timing

### MySQL
```
:GripConnect mysql://root@localhost/grip_test
:Grip users
```
- [ ] Grid renders 15 rows
- [ ] Edit, apply, refresh -- change persists
- [ ] `INSERT` with all defaults works (DEFAULT VALUES rewrite)
- [ ] FK navigation works
- [ ] Properties shows indexes and stats

### DuckDB
```
:GripConnect duckdb:tests/grip_test.duckdb
:Grip users
```
- [ ] Grid renders 15 rows
- [ ] Edit, apply, refresh -- change persists
- [ ] FK navigation works
- [ ] File-as-table: `:Grip /path/to/file.parquet` opens read-only grid

### DuckDB File-as-Table
```
:Grip ./tests/sample.csv
```
- [ ] Opens with `duckdb::memory:` connection
- [ ] Grid shows file contents
- [ ] Title shows `[read-only]`
- [ ] Supported extensions: .parquet, .csv, .tsv, .json, .ndjson, .jsonl, .xlsx

---

## 13. Edge Cases

- [ ] `:Grip empty_table` shows "(empty result)" centered
- [ ] `:Grip unicode_fun` renders multibyte chars correctly
- [ ] `:Grip wide_table` with `1`-`9` pinning keeps columns visible
- [ ] `:Grip long_values` then `CR` on a cell expands the full value
- [ ] `:Grip binary_blobs` shows `<binary...` for binary cells
- [ ] `:Grip composite_pk` -- edit and apply work with composite WHERE
- [ ] `:Grip json_data` -- JSON values display correctly
- [ ] Sort on NULL columns: NULLs sort consistently (last for ASC)
- [ ] Filter with NULL: `f` on a NULL cell filters by `IS NULL`
- [ ] Pagination boundary: navigate to last page, then `]p` stays on last

---

## 14. Regression Checks (from v2 audit)

These are specific bugs found and fixed. Verify they stay fixed.

- [ ] `go`/`gT`/`gQ` from grid do not crash (url was undefined)
- [ ] Hidden columns + Tab/w/b navigation does not crash
- [ ] Hidden columns + `^`/`$` jump to correct visible column
- [ ] `:GripCreate` with multiple columns does not crash (forward-ref fix)
- [ ] Properties float renders above live SQL preview (z-index)
- [ ] Cell editor renders above info floats (z-index)
- [ ] Error float renders above everything (z-index)
- [ ] MySQL URL with `@` in password parses correctly
- [ ] SQLite table names with special chars work in PRAGMA queries
- [ ] `x` (not `-`) drops column in properties view
- [ ] Esc closes diff buffer
- [ ] Error float closes on `q`, `Esc`, or leaving the window

---

## Quick Smoke Test (5 minutes)

Minimum viable QA pass for a quick check:

```bash
just test                                    # unit tests pass
just seed-sqlite && just dev-sqlite          # launch with SQLite
```

1. `:Grip users` -- grid opens with 15 rows
2. `e` on name cell, change value, `CR` -- cell turns blue
3. `o` -- new green row appears
4. `d` on a row -- red strikethrough
5. `gs` -- staged SQL preview shows UPDATE/INSERT/DELETE
6. `a` -- apply, confirm -- changes persist
7. `r` -- refresh shows updated data
8. `gf` on `orders.user_id` -- FK navigation works
9. `C-o` -- goes back
10. `go` -- schema browser opens
11. `gI` -- properties float opens
12. `?` -- help popup shows
13. `q` -- closes everything cleanly
