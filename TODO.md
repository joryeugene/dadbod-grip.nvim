# dadbod-grip.nvim

## Ideas Backlog

Not committed to any release. Roughly ordered by expected impact.

### High Value -- Features
- [x] DuckDB cross-database federation (`:GripAttach`, ATTACH pg/mysql/sqlite, cross-DB JOINs): shipped v3.0.0
- [x] Row cloning (`c`: duplicate current row as staged INSERT with PKs cleared): shipped
- [x] Column filter builder (`gF` with operators and wildcards): shipped v2.9
- [x] Export to file (`gX` / `:GripExport`: CSV, JSON, SQL INSERT): shipped v2.9
- [x] Column visibility toggle (`-` hide, `g-` restore all, `gH` picker): shipped
- [x] ER diagram (`gG` / `4`: tree-spine float, FK follow, breadcrumb nav): shipped v3.3.0
- [x] Built-in SQL completion (nvim-cmp source, alias tracking, `<C-Space>`, schema-aware with federation support): shipped v3.3.0
- [ ] Import from clipboard/pipe (`gI` / `:GripImport`: detect CSV/JSON/TSV, preview columns, stage as INSERT batch; DuckDB: `read_csv_auto()`; PG: COPY or multi-INSERT)
- [ ] Generate sync SQL from diff (make table A match table B, emit INSERT/UPDATE/DELETE migration from `gD` output)
- [ ] Virtual columns: computed display columns defined per-table in `.grip/config.lua` via Lua expressions evaluated client-side (e.g. `full_name = row.first .. " " .. row.last`); no DB writes, spreadsheet-style power
- [ ] Row comparison: visual-select two rows and open a side-by-side diff float showing which cells differ; useful for spotting what changed between similar records
- [ ] Multi-cursor column set: press on a column to stage the same value for all visible rows at once; bulk-edit a status field without writing SQL

### High Value -- UX / Developer Experience
- [x] Command palette (`<C-p>`: searchable action list across grid, query pad, and sidebar; self-registering via `palette.register`): shipped v3.4.0
- [x] SQL formatter (`gF` in query pad: external tool cascade - sqlformat, pg_format, sql-formatter - with Lua fallback): shipped v3.4.0
- [x] Syntax highlighting in query pad (ft=sql, treesitter): shipped v3.4.0
- [x] Remappable keymaps (`setup({ keymaps = { palette = "<F1>", query_pad = false } })`): shipped v3.4.0

### High Value -- DuckDB Extensions
- [ ] Iceberg/Delta Lake tables (`INSTALL iceberg`: open `iceberg://` paths as live tables, expose partition metadata in sidebar)
- [ ] Spatial extension (`INSTALL spatial`: render geometry columns, `ST_AsText()` in row view, bbox stats in profiling)
- [ ] Full-text search (`INSTALL fts`: `PRAGMA create_fts_index`, surface FTS indexes in schema sidebar, `gF` MATCH operator)
- [ ] MotherDuck branching (`:GripBranch` to create/switch/diff MotherDuck branches, branch name in statusline)

### High Value -- AI Integration
- [ ] Natural language result explanation (`gA` in grid asks AI to summarize what the current result set means in plain English)
- [ ] AI explain query (`gA` in query pad, explain mode): describe what the current SQL does in plain English; distinct from "generate SQL"; useful for understanding inherited queries
- [ ] Anomaly detection in profiling (AI scans `gR` profiling output and flags statistical outliers with reasoning)
- [ ] AI-assisted data generation (`:GripFill N` asks AI to generate N realistic rows for the current table schema, staged as INSERTs; smarter than random: names look like names, emails look like emails)
- [ ] pgvector support (render `vector` columns in row view, `gF` generates `ORDER BY vec <=> $1 LIMIT N` similarity queries, profiling shows dimension count and index type)

### High Value -- Adapters
- [ ] Snowflake adapter (snowsql CLI, auth delegated to `~/.snowsql/config`, 3-level hierarchy database/schema/table, `SHOW TABLES IN DATABASE` metadata, warehouse selection)
- [ ] BigQuery adapter (bq CLI, auth via gcloud ADC, project/dataset/table hierarchy, `bq show --format=json` for schema, `bq query --use_legacy_sql=false`)
- [ ] MSSQL adapter (sqlcmd CLI, `mssql://` scheme, sys.tables/sys.columns metadata, SET STATISTICS for explain, TOP N pagination, `##temp` table support)
- [ ] Turso/libSQL adapter (extend SQLite adapter with HTTP transport, auth token in URL, branch management via `:GripBranch`, time-travel queries)
- [ ] CockroachDB adapter (extend PostgreSQL adapter, `cockroachdb://` scheme, CDC changefeed exposure, multi-region config display in properties)
- [ ] MongoDB: deprioritized; document model incompatible with grid renderer; needs separate path (JSON tree view, not tabular)

### Medium Value
- [ ] Column reordering via keymap (`<` / `>` to shift column left/right)
- [ ] Inline column resize with `+`/`-` on header row
- [ ] Bookmarked rows (mark interesting rows with `m`, recall with `'`, persist per table in `.grip/bookmarks.json`)
- [ ] Multi-row selection for bulk ops (visual `V`-mode selects rows, then `d`=bulk DELETE, `gy`=copy all as table)
- [ ] Quick data generation (`:GripFill` to populate empty table with N rows of realistic fake data per column type)
- [ ] Connection health indicator: persistent dot in status bar (green/yellow/red) showing DB reachability; pings on cursor idle or timer
- [ ] Saved views: persist full grid state (active filters, sort, hidden columns, page size) as a named snapshot per table in `.grip/views.json`; recall without writing SQL
- [ ] ASCII histogram for numeric columns: extend `gS` to show a quick distribution histogram inline; complement to stats popup
- [ ] Row pinning: mark up to 5 rows to keep visible at the top of every page regardless of filter/sort; useful as reference anchors while editing

### Exploration
- [ ] ClickHouse adapter (`clickhouse-client` CLI, SAMPLE clause, materialized view listing, columnar-specific EXPLAIN)
- [ ] Neon database branching integration (`:GripBranch` to create/switch/diff branches via Neon API)
- [ ] Oracle adapter (sqlplus CLI, ROWNUM pagination, DBA_/ALL_ metadata views)
- [ ] Schema diff across connections (compare two databases, show table/column drift)
- [ ] Data lineage visualization (trace FK chains as ASCII graph)
- [ ] Lua scripting hooks (user-defined pre/post query hooks for logging, auditing, transforms)
- [ ] JSON path drilldown: for JSON/JSONB cells, navigate nested keys as a tree in the K-view; follow json paths the way `gf` follows FK chains
- [ ] Query sharing bundle (`:GripBundle` exports current query + connection scheme without credentials as a `.grip` file; recipient opens with `:GripOpen file.grip`)
- [ ] Schema change detector: on session start, diff current schema against last-seen snapshot in `.grip/schema_snapshot.json` and notify if columns were added, dropped, or renamed
