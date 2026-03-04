# dadbod-grip.nvim

## Shipped since v2.4

- v2.5: Mutation preview (`C-CR` stages, `gD` diff float, `u` cancel, `a` apply). Multi-schema.
- v2.6: Sidebar nav (`go`/`gb`), pickers (`gh`/`gc`/`gt`), wide table scroll, tab nav `1-5`.
- v2.7: `--write`/`--watch` file modes, password masking, `gn` null filter, `gV` DDL float, `gi`/`gI` alignment, `:GripStart` + Softrear Portal demo.
- v2.8: SafeState cursor after edit, Chonk welcome screen (`;`), block-centered art float.

Full history: `git log --oneline`.

---

## Ideas Backlog

Unimplemented ideas from prior research and specs. Not committed to any
release. Roughly ordered by expected impact.

### High Value -- Features
- [x] Query history with Telescope search (gh, :GripHistory) -- v2.3.0
- [x] Compact diff mode for narrow terminals (gv toggle) -- v2.3.0
- [x] Sparkline data profiling (gR, :GripProfile) -- v2.4.0
- [x] Query Doctor plain-English EXPLAIN -- v2.4.0
- [x] AI SQL generation (gA, :GripAsk) -- v2.4.0
- [x] Query execution timer -- v2.4.0
- [x] Live watch mode (`--watch` flag, re-execute on file change) -- v2.7
- [x] `:GripStart` demo portal (Softrear Inc., 17 tables) -- v2.7
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
