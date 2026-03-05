# dadbod-grip.nvim

## Ideas Backlog

Not committed to any release. Roughly ordered by expected impact.

### High Value -- Features
- [x] DuckDB cross-database federation (`:GripAttach`, ATTACH pg/mysql/sqlite, cross-DB JOINs): shipped v3.0.0
- [x] Row cloning (`c`: duplicate current row as staged INSERT with PKs cleared): shipped
- [ ] Import from clipboard/pipe (`gI` / `:GripImport`: detect CSV/JSON/TSV, preview columns, stage as INSERT batch; DuckDB: `read_csv_auto()`; PG: COPY or multi-INSERT)
- [ ] Generate sync SQL from diff (make table A match table B, emit INSERT/UPDATE/DELETE migration from `gD` output)

### High Value -- DuckDB Extensions
- [ ] Iceberg/Delta Lake tables (`INSTALL iceberg`: open `iceberg://` paths as live tables, expose partition metadata in sidebar)
- [ ] Spatial extension (`INSTALL spatial`: render geometry columns, `ST_AsText()` in row view, bbox stats in profiling)
- [ ] Full-text search (`INSTALL fts`: `PRAGMA create_fts_index`, surface FTS indexes in schema sidebar, `gF` MATCH operator)
- [ ] MotherDuck branching (`:GripBranch` to create/switch/diff MotherDuck branches, branch name in statusline)

### High Value -- AI Integration
- [ ] Natural language result explanation (`gA` in grid asks AI to summarize what the current result set means in plain English)
- [ ] Anomaly detection in profiling (AI scans `gR` profiling output and flags statistical outliers with reasoning)
- [ ] Schema-aware query pad autocomplete (send table/column DDL as context to AI on each keystroke in query pad)
- [ ] pgvector support (render `vector` columns in row view, `gF` generates `ORDER BY vec <=> $1 LIMIT N` similarity queries, profiling shows dimension count and index type)

### High Value -- Adapters
- [ ] MSSQL adapter (sqlcmd CLI, `mssql://` scheme, sys.tables/sys.columns metadata, SET STATISTICS for explain, TOP N pagination, `##temp` table support)
- [ ] Turso/libSQL adapter (extend SQLite adapter with HTTP transport, auth token in URL, branch management via `:GripBranch`, time-travel queries)
- [ ] CockroachDB adapter (extend PostgreSQL adapter, `cockroachdb://` scheme, CDC changefeed exposure, multi-region config display in properties)

### Medium Value
- [ ] Column reordering via keymap (`<` / `>` to shift column left/right)
- [ ] Inline column resize with `+`/`-` on header row
- [ ] Bookmarked rows (mark interesting rows with `m`, recall with `'`, persist per table in `.grip/bookmarks.json`)
- [ ] Multi-row selection for bulk ops (visual `V`-mode selects rows, then `d`=bulk DELETE, `gy`=copy all as table)
- [ ] Column visibility toggle (`-` hides current column, `+` restores, persists per-session in `.grip/`)
- [ ] Quick data generation (`:GripFill` to populate empty table with N rows of realistic fake data per column type)

### Exploration
- [ ] ClickHouse adapter (`clickhouse-client` CLI, SAMPLE clause, materialized view listing, columnar-specific EXPLAIN)
- [ ] Neon database branching integration (`:GripBranch` to create/switch/diff branches via Neon API)
- [ ] Oracle adapter (sqlplus CLI, ROWNUM pagination, DBA_/ALL_ metadata views)
- [ ] Schema diff across connections (compare two databases, show table/column drift)
- [ ] Data lineage visualization (trace FK chains as ASCII graph)
- [ ] Lua scripting hooks (user-defined pre/post query hooks for logging, auditing, transforms)
