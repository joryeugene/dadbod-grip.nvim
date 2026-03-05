# dadbod-grip keymaps

**Check this file before adding any new keymap.** A duplicate silently clobbers existing behavior.

## Grid (modifiable=false, ft=grip)

### Navigation
| Key | Action |
|-----|--------|
| `j` / `k` | Move down/up rows |
| `h` / `l` | Move left/right within row |
| `w` / `b` | Next / previous column |
| `Tab` / `S-Tab` | Next / previous column |
| `e` | Next column, land at end of cell |
| `gg` | First data row (same column) |
| `G` | Last data row |
| `0` / `^` | First column |
| `$` | Last column |
| `{` / `}` | Prev / next modified row |

### Editing
| Key | Action |
|-----|--------|
| `i` / `<CR>` | Edit cell under cursor |
| `x` | Set cell to NULL |
| `p` | Paste clipboard into cell |
| `P` | Paste multi-line into consecutive rows |
| `o` | Insert new row after cursor |
| `c` | Clone row (copy values, clear PKs) |
| `d` | Toggle delete on current row |
| `u` | Undo last edit (multi-level) |
| `<C-r>` | Redo |
| `U` | Undo all (reset to original) |
| `a` | Apply all staged changes to DB |

### Batch Edit (visual mode)
| Key | Action |
|-----|--------|
| `e` | Set selected cells to same value |
| `d` | Toggle delete on selected rows |
| `x` | Set selected cells to NULL |
| `y` | Yank selected cells in column |

### Display / Column
| Key | Action |
|-----|--------|
| `-` | Hide column under cursor |
| `g-` | Restore all hidden columns |
| `gH` | Column visibility picker |
| `=` | Cycle column width (compact → expanded → reset) |
| `T` | Toggle column type annotations |
| `K` | Row view (vertical transpose) |
| `?` | Show help popup |
| `Q` | Welcome screen (home) |

### Sort / Filter / Pagination
| Key | Action |
|-----|--------|
| `s` | Toggle sort on column (ASC → DESC → off, replaces existing sorts) |
| `S` | Add/toggle secondary sort (stacked: ▲1 ▼2 ▲3) |
| `f` | Quick filter by cell value (= current value) |
| `gn` | Filter: column IS NULL |
| `gF` | **[NEW v2.9]** Filter builder (=, !=, >, <, LIKE, IN, BETWEEN, NULL, NOT NULL) |
| `<C-f>` | Freeform WHERE clause filter |
| `F` | Clear all active filters |
| `gp` | Load saved filter preset |
| `gP` | Save current filter as preset |
| `X` | Reset view (clear sort + filter + page) |
| `H` / `L` | Previous / next page |
| `[p` / `]p` | Previous / next page (bracket alias) |
| `[P` / `]P` | First / last page |

### FK Navigation
| Key | Action |
|-----|--------|
| `gf` | Follow foreign key under cursor |
| `<C-o>` | Go back in FK navigation stack |

### Inspection
| Key | Action |
|-----|--------|
| `ge` | Explain cell (type, value, status) |
| `gs` | Preview staged SQL |
| `gc` | Copy staged SQL to clipboard |
| `gi` | Table info (columns, types, PKs) |
| `gI` | Table properties (full detail float) |
| `gN` | Rename column under cursor |
| `gl` | Toggle live SQL preview float |

### Analysis & Export
| Key | Action |
|-----|--------|
| `ga` | Aggregate current column (count, sum, avg, min, max) |
| `gS` | Column statistics popup (distinct, nulls%, top values) |
| `gR` | Table profile (sparkline distributions) |
| `gV` | Show CREATE TABLE DDL float |
| `gx` | Explain current query plan |
| `gD` | Diff against another table |
| `gE` | Export to clipboard (CSV, TSV, JSON, SQL, Markdown, Grip Table) |
| `gX` | **[NEW v2.9]** Export to file (csv/json/sql) |
| `y` | Yank cell value to clipboard |
| `Y` | Yank row as CSV |
| `gY` | Yank entire table as CSV |
| `gy` | Yank table as Markdown pipe table |

### Tab Views (1-9)
| Key | Action |
|-----|--------|
| `1` | Table picker |
| `2` | Records (default view) |
| `3` | Query History |
| `4` | Column Stats |
| `5` | Explain (query plan) |
| `6` | Columns (schema) |
| `7` | Foreign Keys |
| `8` | Indexes |
| `9` | Constraints |

### Schema & Workflow
| Key | Action |
|-----|--------|
| `go` | Open schema browser sidebar (focus / toggle) |
| `gT` / `gt` | Pick table (floating picker) |
| `gb` | Schema browser sidebar (toggle/focus) |
| `gO` | Open as editable table (read-only → table) |
| `gC` / `<C-g>` | Switch database connection |
| `gW` | Toggle watch mode (auto-refresh on timer) |
| `g!` | Toggle write mode (apply overwrites file) |
| `:GripAttach` | Attach external DB to DuckDB (Postgres, MySQL, SQLite, MotherDuck) |
| `:GripDetach` | Detach attached database |
| `q` | Open query pad |
| `gq` | Load saved query |
| `gh` | Query history browser |
| `r` | Refresh (re-run query) |
| `A` | AI SQL generation |

## Query Pad (ft=sql, editable)

| Key | Action |
|-----|--------|
| `<C-CR>` | Execute query |
| `gA` | AI SQL generation |
| `?` | Show help |
| `q` | Close query pad |

## Schema Sidebar (ft=grip-schema)

| Key | Action |
|-----|--------|
| `<CR>` / `go` | Open table under cursor (plain) |
| `gT` / `gt` | Pick table (picker) |
| `gb` | Close sidebar |
| `gq` | Load saved query into query pad |
| `gh` | Query history → load into query pad |
| `gC` / `gc` / `<C-g>` | Switch connection |
| `ga` | Attach external DB (DuckDB federation) |
| `gd` | Detach attached database |
| `?` | Show help |
| `1` | Table picker |
| `2-9` | Same tab views as grid (2=Records, 3=History, 4=Stats, 5=Explain, 6=Columns, 7=FK, 8=Indexes, 9=Constraints) |

## Free `g` Keymaps (as of v2.9)

Available for future features. Check this list before assigning a new `g` keymap:

**Uppercase (free):** `gA` (query pad only), `gB`, `gG`, `gJ`, `gK`, `gL`, `gM`, `gQ`, `gU`, `gZ`
**Lowercase (free in grid):** `gd`, `gm`, `gr`, `gw`
**Lowercase (free in sidebar):** `gm`, `gr`
