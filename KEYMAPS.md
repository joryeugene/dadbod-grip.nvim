# dadbod-grip keymaps

**Check this file before adding any new keymap.** A duplicate silently clobbers existing behavior.

All keys shown are defaults. Every binding is overridable via `setup()`:

```lua
require("dadbod-grip").setup({
  keymaps = {
    palette    = "<F1>",   -- remap to a different key
    query_pad  = false,    -- disable entirely (pass false)
  }
})
```

Action names map 1:1 to the entries in `lua/dadbod-grip/keymaps.lua`.

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

**Cell editor float keymaps**

| Key | Mode | Action |
|-----|------|--------|
| `<CR>` / `<C-s>` | insert + normal | Save and close |
| `<Esc>` | insert | Enter normal mode (use ciw, dw, s, etc.) |
| `<Esc>` / `q` | normal | Cancel (discard changes) |
| `<C-c>` | insert | Cancel (discard changes) |

The editor starts in INSERT mode. Press `<Esc>` to drop into NORMAL for Vim motions, then `<CR>` to save or `q`/`<Esc>` to cancel. JSON cells open with JSON syntax highlighting and a taller float (up to 25 lines). Long values wrap at word boundaries.

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
| `<C-p>` | Command palette (searchable action list) |
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

Surface navigation (smart: "press again" = secondary action):

| Key | Primary | Secondary (already on that surface) |
|-----|---------|-------------------------------------|
| `1` | Open sidebar | Connections picker |
| `2` | Open query pad | Query history |
| `3` | Grid / records | Table picker |

Table-depth views (consistent across grid, sidebar, query pad):

| Key | View |
|-----|------|
| `4` | ER diagram float (all tables + FK relationships, same as `gG`) |
| `5` | Column Stats |
| `6` | Columns (schema) |
| `7` | Foreign Keys |
| `8` | Indexes |
| `9` | Constraints |

Note: explain query plan is accessible via `gx` (removed from tab system).

### Schema & Workflow
| Key | Action |
|-----|--------|
| `go` | Open schema browser sidebar (focus / toggle) |
| `gT` / `gt` | Pick table (floating picker) |
| `gb` | Schema browser sidebar (toggle/focus) |
| `gO` | Open as editable table (read-only → table) |
| `gG` | ER diagram float (tables + FK relationships) |
| `gC` / `<C-g>` | Switch database connection |
| `gW` | Toggle watch mode (auto-refresh on timer) |
| `g!` | Toggle write mode (apply overwrites file) |
| `:GripAttach` | Attach external DB to DuckDB (Postgres, MySQL, SQLite, MotherDuck) |
| `:GripDetach` | Detach attached database |
| `:GripOpen [path]` | Open file/HTTPS/s3:// without saving to connections (no arg = picker) |
| `q` | Open query pad |
| `gq` | Load saved query |
| `gh` | Query history browser |
| `r` | Refresh (re-run query) |
| `A` | AI SQL generation |

## Query Pad (ft=sql, editable)

| Key | Action |
|-----|--------|
| `<C-p>` | Command palette (searchable action list) |
| `<C-CR>` | Execute query |
| (auto) | SQL completion fires as you type: tables, columns, aliases, federation |
| `<C-Space>` | Manually trigger SQL completion |
| `<C-x><C-o>` | SQL completion: Vim-standard omnifunc / nvim-cmp source |
| `gA` | AI SQL generation |
| `gF` | Format SQL (external tool cascade: sql-formatter -> pg_format -> sqlfluff -> Lua fallback) |
| `gn` | Open notebook file (.md/.sql) in query pad |
| `?` | Show help |
| `q` | Close query pad |
| `1` | Open sidebar |
| `2` | Query history (secondary: already in query pad) |
| `3` | Jump to grid (table picker if no grid is open) |
| `4` | ER diagram float |
| `5` | Jump to grid + Column Stats view |
| `6` | Jump to grid + Columns view |
| `7` | Jump to grid + Foreign Keys view |
| `8` | Jump to grid + Indexes view |
| `9` | Jump to grid + Constraints view |

## Schema Sidebar (ft=grip-schema)

| Key | Action |
|-----|--------|
| `<C-p>` | Command palette (searchable action list) |
| `<CR>` / `go` | Open table under cursor (plain) |
| `gT` / `gt` | Pick table (picker) |
| `gb` | Close sidebar |
| `gq` | Load saved query into query pad |
| `gh` | Query history → load into query pad |
| `gC` / `gc` / `<C-g>` | Switch connection |
| `ga` | Attach external DB (DuckDB federation) |
| `gd` | Detach attached database |
| `gG` | ER diagram float (all tables + FK relationships) |
| `gn` | Open notebook file (.md/.sql) in query pad |
| `?` | Show help |
| `1` | Connections picker (secondary: already in sidebar) |
| `2` | Open query pad |
| `3` | Jump to grid / open table under cursor as records (table picker if no node) |
| `4` | ER diagram float |
| `5-9` | Open table under cursor in that view (5=Stats, 6=Columns, 7=FK, 8=Indexes, 9=Constraints) |

## Free `g` Keymaps (as of v3.1)

Available for future features. Check this list before assigning a new `g` keymap:

**Uppercase (free):** `gA` (query pad only), `gB`, `gJ`, `gK`, `gL`, `gM`, `gQ`, `gU`, `gZ`
**Lowercase (free in grid):** `gd`, `gm`, `gr`, `gw`
**Lowercase (free in sidebar):** `gm`, `gr`

## Command Palette

`<C-p>` is available on all three surfaces (grid, query pad, sidebar).
It opens the command palette: a searchable list of every action available
in the current context, with a preview pane showing the key binding and
description for each entry.

Use it to discover keymaps, trigger actions without memorising their keys,
or quickly search for a feature by name.

| Key | Available in | Action |
|-----|-------------|--------|
| `<C-p>` | Grid, Query pad, Sidebar | Open command palette |

## Key Design Principles

Surface | `q` | `<Esc>` | `?` | `gC`/`<C-g>` | `gc` | `gb` | `gG`
--------|-----|---------|-----|--------------|------|------|-----
Grid | query pad | (nothing) | help | connections | copy staged SQL | sidebar | ER diagram
Sidebar | query pad | close | help | connections | connections | close | ER diagram
Query pad | welcome screen | (nothing) | help | (nothing) | (nothing) | (nothing) | (nothing)
Modal floats | close | close | (nothing) | (nothing) | (nothing) | (nothing) | close (toggle)

Notes:
- `q` means "to query pad" from grid/sidebar; "welcome screen" from query pad; "close" in modal floats
- Uppercase `gX` = global/navigation actions (connections, schema browser, ER diagram)
- Lowercase `gx` = local inspection/analysis actions (FK follow, explain, export)
- `?` = help everywhere, always
- `gc` in grid = "copy staged SQL" (legacy DBUI compat); `gc` in sidebar = connections
- `:GripOpen` = command only, no grid keymap (`gO` is taken: read-only to editable)
