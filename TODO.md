# dadbod-grip.nvim

## Released

### v1.0.0 - Editable Data Grids
DataGrip-style grids with box-drawing UI, inline cell editing, visual change
staging, live SQL preview, PostgreSQL support, DBUI integration, composite PK
support, read-only auto-detection, navigation, CSV export, undo, help popup.

### v1.1.0 - Multi-Database
Adapter system with SQLite, DuckDB, MySQL/MariaDB adapters. RFC 4180 CSV
parser. DuckDB file-as-table querying (`:Grip /path/to/data.parquet`).

### v1.2.0 - Sort, Filter, Paginate
Column sort (s/S), quick filter (f), freeform WHERE (C-f), clear filter (F),
pagination (]p/[p), query composition module.

### v1.3.0 - FK Navigation & Data Intelligence
FK navigation (gf) with breadcrumb trail and back stack (C-o). Aggregate on
selection (ga), column statistics (gS), multi-format export (gE).

### v1.4.0 - Grid Enhancements
Column pinning (1-9/0), auto-fit, column hide/show (-/g-/gH), conditional
cell formatting, batch edit, visual copy/paste, multi-level undo (50 deep).

### v2.0.0 - Standalone Workflow
EXPLAIN viewer, transaction wrapper, schema browser (go), table picker (gT),
query pad (gQ), saved queries, connection profiles, data diff (gD).

### v3.0.0 - Schema Operations (DDL)
Table properties (gI), column rename (R), column add/drop (+/x), drop table,
create table.

### Ongoing
- 197 unit tests across 8 spec files
- Structural sharing in data.lua, sampled column widths
- Vimdoc help file (doc/dadbod-grip.txt)

---

## Ideas Backlog

Unimplemented ideas from prior research and specs. Not committed to any
release. Roughly ordered by expected impact.

### High Value
- [ ] Remote file querying via DuckDB httpfs: `:Grip https://example.com/data.csv`
- [ ] Generate sync SQL from diff (make table A match table B)
- [ ] Saved filter presets per table (named WHERE clauses)
- [ ] Compact diff mode for narrow terminals (<120 cols)

### Exploration
- [ ] Turso/libSQL adapter compatibility testing
- [ ] Neon database branching integration (`:GripBranch`)
- [ ] MSSQL adapter (sqlcmd CLI)
- [ ] Column reordering via drag or keymap
- [ ] Row duplication keymap (yy-style for grid rows)
- [ ] Inline column resize with +/- on header
- [ ] Export to clipboard as markdown table
- [ ] Telescope integration for saved queries picker
