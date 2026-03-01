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

### v2.1.0 - Schema Operations (DDL)
Table properties (gI), column rename (R), column add/drop (+/x), drop table,
create table.

### v2.2.0 - Quality of Life
Remote file querying via DuckDB httpfs, saved filter presets (gp/gP),
Grip Table box-drawing export format, Telescope saved queries picker.

### v2.3.0 - Query History & Compact Diff
Query history with JSONL storage and Telescope search (gh, :GripHistory).
Auto-records every :Grip query, query pad execution, staged DML, and EXPLAIN.
Consecutive dedup, password redaction, 500-entry cap.

Compact diff mode for narrow terminals (<120 cols). Stacked key-value layout
showing PK context + changed columns with old -> new format. Auto-detects
terminal width, toggle with gv.

### Ongoing
- 279 unit tests across 11 spec files
- Adapter-specific type_zoo seeds (PG: 34 types, MySQL: 28 types, DuckDB: 34 types, SQLite: 26 types + coercion row)
- Committed SQLite test DB (tests/seed_sqlite.db) for zero-setup testing
- Structural sharing in data.lua, sampled column widths
- Vimdoc help file (doc/dadbod-grip.txt)

---

## Ideas Backlog

Unimplemented ideas from prior research and specs. Not committed to any
release. Roughly ordered by expected impact.

### High Value -- Features
- [x] Query history with Telescope search (gh, :GripHistory) -- v2.3.0
- [x] Compact diff mode for narrow terminals (gv toggle) -- v2.3.0
- [ ] Generate sync SQL from diff (make table A match table B, emit INSERT/UPDATE/DELETE migration from `gD` output)
- [ ] Import from clipboard/pipe (`gI` in empty grid or `:GripImport`, detect CSV/JSON/TSV, preview before INSERT, map columns)
- [ ] Row duplication keymap (`yy`-style: duplicate current row as new INSERT with PK cleared)

### High Value -- Adapters
- [ ] MSSQL adapter (sqlcmd CLI, `mssql://` scheme, sys.tables/sys.columns metadata, SET STATISTICS for explain, TOP N pagination, `##temp` table support)
- [ ] Turso/libSQL adapter (extend SQLite adapter with HTTP transport, auth token in URL, branch management via `:GripBranch`, time-travel queries)
- [ ] CockroachDB adapter (extend PostgreSQL adapter, `cockroachdb://` scheme, CDC changefeed exposure, multi-region config display in properties)

### Medium Value
- [ ] Column reordering via keymap (`<` / `>` to shift column left/right)
- [ ] Inline column resize with `+`/`-` on header row
- [ ] Export to clipboard as markdown table (`gy` for GFM pipe table)
- [ ] Bookmarked rows (mark interesting rows with `m`, recall with `'`, persist per table in `.grip/bookmarks.json`)
- [ ] Quick data generation (`:GripFill` to populate empty table with N rows of realistic fake data per column type)

### Exploration
- [ ] ClickHouse adapter (`clickhouse-client` CLI, SAMPLE clause, materialized view listing, columnar-specific EXPLAIN)
- [ ] Neon database branching integration (`:GripBranch` to create/switch/diff branches via Neon API)
- [ ] Oracle adapter (sqlplus CLI, ROWNUM pagination, DBA_/ALL_ metadata views)
- [ ] Schema diff across connections (compare two databases, show table/column drift)
- [ ] Data lineage visualization (trace FK chains as ASCII graph)
- [ ] Lua scripting hooks (user-defined pre/post query hooks for logging, auditing, transforms)
