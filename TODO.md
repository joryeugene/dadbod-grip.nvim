# dadbod-grip.nvim

## Ideas Backlog

Not committed to any release. Roughly ordered by expected impact.

### High Value -- Features
- [ ] DuckDB cross-database federation (`:GripAttach`, ATTACH pg/mysql/sqlite, cross-DB JOINs)
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
