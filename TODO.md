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
- [x] Row comparison (`gd` visual: side-by-side diff float, differing cells highlighted): shipped v1.2.0
- [x] Multi-cursor column set (`gU`: stage the same value for all visible rows of the current column; bulk-edit a status field without writing SQL): shipped

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
- [x] AI-assisted data generation (`:GripFill N` / `gA` in grid: AI generates realistic rows staged as INSERTs): shipped v1.2.0
- [ ] pgvector support (render `vector` columns in row view, `gF` generates `ORDER BY vec <=> $1 LIMIT N` similarity queries, profiling shows dimension count and index type)

### High Value -- Adapters
- [ ] Snowflake adapter (snowsql CLI, auth delegated to `~/.snowsql/config`, 3-level hierarchy database/schema/table, `SHOW TABLES IN DATABASE` metadata, warehouse selection)
- [ ] BigQuery adapter (bq CLI, auth via gcloud ADC, project/dataset/table hierarchy, `bq show --format=json` for schema, `bq query --use_legacy_sql=false`)
- [x] MSSQL adapter (sqlcmd CLI, `mssql://` scheme, sys.tables/sys.columns metadata, SET STATISTICS for explain): shipped v3.8.0, read-only. TOP N pagination and `##temp` table support are still open.
- [ ] Turso/libSQL adapter (extend SQLite adapter with HTTP transport, auth token in URL, branch management via `:GripBranch`, time-travel queries)
- [ ] CockroachDB adapter (extend PostgreSQL adapter, `cockroachdb://` scheme, CDC changefeed exposure, multi-region config display in properties)
- [ ] MongoDB: deprioritized; document model incompatible with grid renderer; needs separate path (JSON tree view, not tabular)

### High Value -- Cell Editor
- [x] Timestamp cells: detect ISO timestamp pattern in cell editor, show parsed human-readable date as extmark virtual text below the input line: shipped v1.2.0
- [x] URL cells: `gx` opens the URL in the system browser -- cell editor NORMAL mode (buf-local keymap) and grid (current cell value): shipped v1.2.0
- [x] Markdown columns: auto-set `ft=markdown` in cell editor for columns named body, description, notes, content, text, bio (column name heuristic): shipped with `gB` (`cell_buffer.lua`, `PROSE_COLUMNS`)
- [x] Enum hint: if column has known distinct values, show them as virtual text in the cell editor (on-demand SELECT DISTINCT, cached per session): shipped

### Medium Value
- [ ] Column reordering via keymap (`<` / `>` to shift column left/right)
- [x] Inline column resize: solved differently in v3.4.0 -- `=` (`grid_col_width`) cycles the column under the cursor through compact -> expanded -> reset. `+`/`-` on the header row is not the binding to use: `-` already hides a column.
- [ ] Bookmarked rows (mark interesting rows with `m`, recall with `'`, persist per table in `.grip/bookmarks.json`)
- [x] Multi-row selection for bulk ops: shipped v3.4.0 (`view/keymaps_visual_batch.lua` -- visual `d` stages the selected rows for DELETE, `e` bulk-edits, `x` sets NULL, `y` yanks the column slice). Only `gy`-as-table is missing; `gE` already exports the whole grid in six formats.
- [x] Quick data generation (`:GripFill N` / `gA` in grid): shipped v1.2.0 (merged with AI-assisted data generation)
- [x] Connection health indicators: `*`/`o`/`x` dots in connection picker; `T` retests file connections; status set on successful switch
- [ ] Saved views: persist full grid state (active filters, sort, hidden columns, page size) as a named snapshot per table in `.grip/views.json`; recall without writing SQL
- [x] ASCII histogram for numeric columns: extend `gS` to show a quick distribution histogram inline; complement to stats popup: shipped (horizontal bars, eight labelled buckets for numeric, top values for every other type)
- [ ] Row pinning: mark up to 5 rows to keep visible at the top of every page regardless of filter/sort; useful as reference anchors while editing

### Exploration
- [ ] ClickHouse adapter (`clickhouse-client` CLI, SAMPLE clause, materialized view listing, columnar-specific EXPLAIN)
- [ ] Neon database branching integration (`:GripBranch` to create/switch/diff branches via Neon API)
- [ ] Oracle adapter (sqlplus CLI, ROWNUM pagination, DBA_/ALL_ metadata views)
- [ ] Schema diff across connections (compare two databases, show table/column drift)
- [ ] Data lineage visualization (trace FK chains as ASCII graph)
- [ ] Lua scripting hooks (user-defined pre/post query hooks for logging, auditing, transforms)
- [x] JSON path drilldown (`gK`: for JSON/JSONB cells, navigate nested keys as an expandable tree; `y` yanks the value, `gy` yanks the JSONPath; also reachable from the K-view): shipped
- [ ] Query sharing bundle (`:GripBundle` exports current query + connection scheme without credentials as a `.grip` file; recipient opens with `:GripOpen file.grip`)
- [ ] Schema change detector: on session start, diff current schema against last-seen snapshot in `.grip/schema_snapshot.json` and notify if columns were added, dropped, or renamed
