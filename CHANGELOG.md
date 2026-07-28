# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **CI installs the DuckDB CLI, so 66 previously unrun assertions actually run.**
  `duckdb_federation_spec`, `duckdb_native_schema_spec` and `duckdb_federated_schema_spec` gate on
  the `duckdb` binary and printed `SKIPPED` without it, while the runner still reported
  `ALL TESTS PASSED` — cross-database federation, native non-`main` schemas and schema-prefixed
  table names were never exercised on any push. The version is pinned (1.5.5) and the download
  checksum-verified, because those specs assert on catalog semantics that have changed across
  DuckDB minors; a bump should be a deliberate commit. The three specs still skip locally when
  `duckdb` is absent, but CI sets `GRIP_REQUIRE_DUCKDB=1`, which turns a missing binary into a
  failure so the install step cannot be dropped without the suite going red.

- **luacheck now covers `tests/` too, and the specs it flagged were fixed rather than silenced.**
  Excluding the suite from the gate in 3.9.0 left 15 warnings unexamined; read individually, most
  marked a real hole. Seven `mutation_spec` tests copied the statement-detection and
  table/WHERE-extraction logic out of `init.lua` into their own bodies and asserted on the copy,
  so they passed no matter what the plugin did — including the "UPDATE wrapped in SELECT" bug one
  of them was named after. They now drive `_resolve_query` and `_mutation_preview` directly; each
  new assertion was checked against a deliberately broken build to confirm it can fail.
  `completion_spec` had the same defect in its auto-trigger guard test. `enum_hint_spec` fed the
  editor a callback whose result nothing read, and tore the window down without going through the
  cancel mapping, so a commit-on-cancel regression was invisible; the teardown now cancels for
  real. `adapter_spec` and `duckdb_federation_spec` captured an error value and never checked it.
  The two legitimate stubs of read-only fields (`os.exit` in the runner, `os.time` in
  `connections_spec`) carry inline luacheck directives at their site. No production behaviour
  changes.

## [3.9.0] - 2026-07-28

### Added

- **Sticky column header**: the grid's column-name row is mirrored into the window's `winbar`,
  so the column names stay visible once a table taller than the window scrolls past them, and
  the column under the cursor is highlighted there with the grid's own column background. The
  mirrored row is sliced by display width at the window's `leftcol` and indented past the
  window gutter, so it stays aligned with the cells underneath on wide tables, with `number`
  or `signcolumn` on, and with CJK/emoji headers. While the grid's own header is still on
  screen the winbar goes blank instead of duplicating it — blank rather than unset, so the grid
  never shifts by a row as scrolling crosses that threshold. The watch/write badges keep the
  right edge of the winbar. On by default; `setup({ sticky_header = false })` reclaims the
  screen line.

### Fixed

- **`attempt to index global 'ui'` on the connection prompts** ([#12](https://github.com/joryeugene/dadbod-grip.nvim/issues/12)):
  the shared-`ui`-helpers refactor in 3.8.0 started calling `ui.input()`/`ui.confirm()` from
  `connections.lua` without requiring the module there, so eight prompts raised as soon as they
  were opened — new connection, connect-once, the three remove confirmations, the DuckDB attach
  alias, and "Save as". Lua compiles an undeclared `ui` as a global read, which is why this got
  past the test suite: nothing fails until a user reaches one of those prompts. A new
  `globals_spec` now walks the bytecode of every plugin file for global reads and writes, so a
  missing `require` fails the suite instead of shipping. Also removes a stray write to the global
  `_` in `completion.lua`, found by the same scan.

### Changed

- **luacheck now runs in CI.** The `just lint` recipe existed but was wired into nothing, and
  there was no `.luacheckrc` — so the linter that would have caught the bug above at parse time
  never ran. Clearing it removed four unused constants and a duplicated `require` in `view.lua`,
  two variables re-declared over an identical binding already in scope in `connections.lua`, a
  dead assignment in `diff.lua`, and three shadowed `opts` bindings. No behaviour changes.

## [3.8.0] - 2026-07-27

This release brings the work done in the [GlebYavorski/dadbod-grip.nvim](https://github.com/GlebYavorski/dadbod-grip.nvim)
fork back into the main repository.

**On the version number.** Tags here ran up to `v3.3.1` on 5 March 2026, after which numbering
restarted at `v1.0.0` and continued through `v1.10.0`. Because `v3.3.1` still sorts highest,
`version = "*"` kept resolving to the March snapshot rather than to the newest code — the root
cause behind ([#14](https://github.com/joryeugene/dadbod-grip.nvim/issues/14)) and
([#19](https://github.com/joryeugene/dadbod-grip.nvim/issues/19)). The fork continued the 3.x
line above `v3.3.1` (3.4 through 3.7.7, released only in the fork), and this release lands at
3.8.0 — a minor rather than a patch bump, because two features landed after the fork's 3.7.7
tag. Pinned installs are unaffected; `version = "*"` now resolves to current code again. The
older tags are left in place so anyone pinned to them keeps working.

### Added

- **SQL Server adapter** (read-only) driven by `sqlcmd`, for `sqlserver://` and `mssql://` URLs:
  query, schema introspection, column info, primary/foreign keys, indexes and constraints.
  From [PR #17](https://github.com/joryeugene/dadbod-grip.nvim/pull/17) by **joryeugene**,
  closing [#13](https://github.com/joryeugene/dadbod-grip.nvim/issues/13).
- **PostgreSQL routines in the schema sidebar**: functions and procedures are listed in their
  own `Functions` / `Procedures` sections with argument signatures, overloads resolved by oid,
  and non-public schemas qualified. From [PR #17](https://github.com/joryeugene/dadbod-grip.nvim/pull/17)
  by **joryeugene**, closing [#15](https://github.com/joryeugene/dadbod-grip.nvim/issues/15).
- **Focused ER diagram**: `gG` from a table context renders that table plus its direct FK parents
  and children, marked `(FOCUS)` in the title and the tree; `4` still opens the full map, and an
  unknown focus name falls back to it. From [PR #17](https://github.com/joryeugene/dadbod-grip.nvim/pull/17)
  by **joryeugene**, closing [#12](https://github.com/joryeugene/dadbod-grip.nvim/issues/12).
- **Reverse foreign-key navigation** (`gm`): jump from a row to the rows in other tables that
  reference it. One referencing table opens directly, several show a picker of
  `child_table.fk_column`; hops chain (`users` → `orders` → `order_items`) and `<C-o>` walks
  back through the shared navigation stack. Backed by a new optional adapter method
  `get_referencing_foreign_keys` with single-query implementations for PostgreSQL, MySQL,
  SQLite and DuckDB, plus a generic fallback.
- **SQL Server reverse-FK lookup** via `sys.foreign_keys` / `sys.foreign_key_columns`, resolving
  the parent by schema *and* name server-side, so schema-qualified targets keep their matches
  and composite keys collapse into one entry like the other adapters.
- **Cell value in a full split buffer** (`gB`), built for large JSON and long text: JSON is
  pretty-printed with `ft=json`, prose columns (`body`, `notes`, `description`, …) open as
  markdown, and `:w` stages the buffer text through the normal staging flow without touching the
  database. Read-only grids open in view mode. Split style is configurable through the new
  `cell_split = "horizontal" | "vertical"` setup option. Closes
  [#18](https://github.com/joryeugene/dadbod-grip.nvim/issues/18).
- **JSON tree drilldown** (`gK`): open a JSON/JSONB cell as a collapsible tree float instead of a
  one-line blob. `<CR>`/`za` expand or collapse, `y` yanks the value under the cursor, `gy` yanks
  its JSONPath, `q`/`<Esc>` close. Objects render as `{...} (N keys)`, arrays as `[...] (N items)`;
  documents with 20 leaves or fewer open fully expanded. Also reachable from inside the `K` row view.
- **Multi-cursor column set** (`gU`): stage one value for the current column across every visible
  row of the page without a visual selection. Staged-deleted rows are skipped, staged INSERT rows
  are included, other pages are never touched, and a confirmation is required above 50 rows.
- **Enum value hints in the cell editor**: a column with at most 8 distinct non-NULL values shows
  them as muted virtual text (`values: active │ pending │ done`). Fetched on demand with
  `SELECT DISTINCT … LIMIT 9` and cached per session, negative results included, so free-text
  columns never re-query.
- **Non-blocking schema warm-up**: `get_schema_batch_async` for SQLite, PostgreSQL, MySQL and
  SQL Server (DuckDB already had one), so a cold completion cache no longer means a blocking CLI
  spawn in the middle of typing. Both the sync and async paths of each adapter now share one
  statement, one parser and one argv builder.
- `adapters.run_cmd_async`, the non-blocking twin of `run_cmd`: the same never-throw contract,
  callbacks delivered on the main loop, and a watchdog that synthesizes the timeout answer if
  `on_exit` never fires, with a deliver-once guard so the two cannot race.
- Test fixtures for live servers: `tests/seed_pg.sql` and `tests/seed_mssql.sql`.

### Fixed

- **`:GripExplain` no longer executes DML.** `EXPLAIN (ANALYZE)` runs the statement it plans, so
  explaining an `UPDATE`/`DELETE`/`INSERT` silently mutated data; `ANALYZE` is now added only for
  `SELECT`/`TABLE`/`VALUES`, and `WITH` (which can carry data-modifying CTEs) falls back to a plain
  `EXPLAIN` ([#22](https://github.com/joryeugene/dadbod-grip.nvim/issues/22)).
- **Setting a cell to NULL staged the literal string `__GRIP_NULL__`.** Both the single-cell and
  the visual batch edit path used the `x and nil or y` idiom, which yields the sentinel itself
  ([#24](https://github.com/joryeugene/dadbod-grip.nvim/issues/24)).
- **`data.effective_value` returned `""` instead of `nil` for NULL originals**, and the audit of
  every caller fixed the fallout: NULL cells no longer shift columns in `gy`/`gE` exports, are no
  longer counted as values by the `ga` aggregate, and quick filter emits `IS NULL` instead of `= ''`.
- **`DROP TABLE … CASCADE` is scoped to PostgreSQL and DuckDB.** SQLite rejects the clause outright
  and MySQL silently ignores it; on those adapters the confirmation dialog now carries an explicit
  warning that the drop may fail or leave dangling references.
- **A self-referencing foreign key is no longer treated as an inbound dependency.** Any table with
  a `parent_id`/`manager_id` column looked like it had a dependent, which widened the drop to
  `CASCADE` on PostgreSQL and DuckDB and produced a false warning elsewhere.
- **Visual-mode `G`/`j`/`k` are clamped to the data rows**, so `V` then `G` no longer overshoots
  onto the separator, footer or hint line
  ([#20](https://github.com/joryeugene/dadbod-grip.nvim/issues/20)).
- **Cell padding and truncation are display-width correct for multibyte (CJK) text.** Truncation
  used to count code points rather than terminal columns, so a Korean cell that filled its column
  misaligned every border line in the grid. From
  [PR #16](https://github.com/joryeugene/dadbod-grip.nvim/pull/16) by **Kimilhee**.
- The same display-width treatment now covers the properties, profile and diff renderers, which
  padded and truncated by byte length and could slice a multi-byte character in half, committing
  broken UTF-8 into the buffer.
- `e` no longer wedges on a cell ending in a multibyte glyph (the `…` truncation marker or `·NULL·`).
- Horizontal reveal: `$`, `w`/`e` and `Tab` now bring a wide column's right edge into view,
  including the trailing border glyph.
- Columns no longer balloon past their content when hiding a column frees up width.
- The SQL formatter (`gF`) no longer splits multi-character PostgreSQL operators: `->>` used to
  come out as `-> >`, and `@>`, `<@`, `&&` (plus the containment, overlap, shift/inet, regex and
  full-text operators, and MySQL's `<=>`) were split into single characters, corrupting jsonb,
  array and inet queries.
- `:GripExplain` receives its SQL as a command argument, so a multi-line query is no longer split
  on newlines and `|` by the Ex parser.
- `ga` aggregates the whole column in normal mode instead of the stale previous visual selection;
  a visual-mode mapping on the same key aggregates the live selection.
- Query pad: `<C-CR>` runs the statement under the cursor (a ```` ```sql ```` fence, else the
  blank-line-delimited paragraph) rather than the entire buffer; auto-synced `SELECT`s no longer
  pile up when hopping between tables; and the prefilled query quotes the table name, so a
  case-sensitive or reserved-word table runs as-is.
- Adapters never throw when the CLI binary is missing — `vim.system` raises on ENOENT, which used
  to surface as a traceback from paths that do not pre-check `executable()`.
- DuckDB: the DSN is escaped in the `ATTACH` prefix (a quote in the DSN passed validation and then
  broke every query on that persisted connection); one `main_catalog_name()` helper that knows the
  in-memory catalog is called `memory`, not `:memory:`, which previously made the batch schema
  query return nothing; and `get_schema_batch` has a stable column order and reads nullability
  from the same source as `get_column_info`.
- MySQL: `execute()` reports real affected-row counts through `ROW_COUNT()` (the parsed
  `(N rows) affected` line is never printed under `--batch`, so every DML reported 0), and column
  types come from `COLUMN_TYPE` instead of being rebuilt from `DATA_TYPE` plus a length — which
  used to render `enum(7)`, `float(12)` and `longtext(4294967295)`. This changes what the schema
  view displays.
- SQL Server: `sqlcmd` is invoked with `-b` so server errors stop exiting 0 and being parsed as a
  result grid; the reported error starts at the server's `Msg` line instead of the preceding row
  counts; `EXPLAIN` is sent as GO-separated batches on stdin, so `SET SHOWPLAN_TEXT` is alone in
  its batch and plans work at all; the `(max)` suffix survives on `nvarchar(max)`/`varbinary(max)`;
  and `execute()` reports a real affected-row count.
- PostgreSQL: the bare `IN` mode is stripped from procedure arguments (PG 14+ prints it for
  procedures but not functions), so routines render consistently in the sidebar.
- Column profiling classifies by the bare type name. Matching keywords anywhere in the type string
  meant `enum('printed','draft')` classified as numeric and `enum('daytime','night')` as a date,
  producing a meaningless average instead of a value histogram.
- The picker invalidates its filter cache after a display-mutating action, so toggling password
  masking in the connections picker no longer replays the pre-toggle match set.
- One JSON pretty-printer, shared with the cell buffer: strings are escaped as valid JSON (a raw
  `\n` used to smear a value across the float), nesting is indented two spaces per level, empty
  containers collapse to `{}` / `[]`, and numbers no longer print as `1e+15`.
- `ui.dismiss_float` deletes the float's buffer along with the window; every float opened during a
  session used to leave a hidden scratch buffer alive until Neovim exited. The properties float's
  `R`/`+`/`T`/`D` keys close deterministically before opening a blocking DDL prompt.
- AI prompt building: the batch schema fetch is `pcall`'d so a throwing adapter cannot kill the
  prompt, the batch spawn is skipped when there are no tables, and the mentioned-table list is
  capped at 30 like the schema budget it was bypassing.
- Adapter detection is derived from one `SCHEME_MAP` instead of three drifted copies, so
  `sqlserver://`/`mssql://` and `mariadb://` are no longer misreported by the Query Doctor,
  the `:GripFill` value-format hint and the AI prompt.
- Assorted defects found in review: the `[N rows]` label in `gJ` read `total_rows` off the wrong
  table and was always empty; the `GripColType` highlight group was used but never defined; the
  query pad's schedule-deferred schema pre-warm could index a wiped buffer; and after DDL the
  plugin refreshes the grids visible in the current tabpage rather than an arbitrary session.
- The bundled `lazy.lua` spec is nested correctly and lists `GripToggle`/`GripFill`, so all commands
  work as lazy-load triggers ([#19](https://github.com/joryeugene/dadbod-grip.nvim/issues/19)).
### Changed

- **Reverse foreign-key navigation moved from `gr` to `gm`.** Neovim 0.11+ ships built-in global
  `grn`/`gra`/`grr`/`gri`/`grt`/`grx` LSP maps, which made a bare `gr` in the grid a prefix: it
  waited for `timeoutlen` and which-key surfaced the LSP submenu instead of firing the action.
  Users who remapped the action keep their override; a regression test guards against a `gr` grid
  default coming back.
- Internal restructuring of the grid: `view.lua` was 5050 lines, more than half of it a single
  keymap setup function. It is now 2563 lines plus 14 modules under `lua/dadbod-grip/view/` —
  thirteen keymap sections (`keymaps_nav`, `keymaps_edit`, `keymaps_sort_filter`,
  `keymaps_inspect`, `keymaps_aggregate`, `keymaps_fk`, `keymaps_visual_batch`,
  `keymaps_tab_view`, `keymaps_misc`, and `keymaps_schema`, `keymaps_session`, `keymaps_ai`,
  `keymaps_results` split out of the oversized `keymaps_tool`) plus `column_highlight`. Sections
  reach the module through a context table instead of file-private state; registration order,
  and therefore keymap precedence for a duplicated key, is unchanged.
- The test suite grew from 41 to 60 spec files, including live integration specs run against real
  PostgreSQL, MySQL and SQL Server servers (gated on `GRIP_TEST_PG_URL` / `GRIP_TEST_MYSQL_URL`,
  skipping cleanly when unset or unreachable). `tests/seed_mssql.sql` was fixed to be runnable
  against a live SQL Server: GO separators, and a filtered unique index instead of a `UNIQUE`
  constraint that rejects the fixture's two NULL emails.
- Migrated off APIs deprecated in Neovim 0.11: all 18 `nvim_buf_add_highlight` call sites use
  `nvim_buf_set_extmark`, `nvim_win_set_option` becomes `nvim_set_option_value`, and the
  `vim.loop` fallback is gone. The 0.10 baseline is unchanged.
- The Query Doctor (`detect_adapter`, EXPLAIN parsing, translations, rendering) moved out of
  `setup()` into its own `explain.lua` module; roughly 200 lines were being rebuilt on every
  `setup()` call and were invisible to tests. It now also covers SQL Server plans (operator tree,
  no cost estimates).
- Consolidated duplicated code across the plugin: shared `paths.lua`
  (`project_root`/`grip_dir`/`ensure_dir`), shared `ui` helpers (`info_float`, `input`, `confirm`,
  `report_split`, `dismiss_float`, `truncate_display`/`pad_display`), shared `sql` helpers
  (`escape_literal` replacing 51 copies of the same gsub, `split_table_name`, `parse_dadbod_url`),
  one export formatter behind the file, clipboard and markdown yank paths, one `resolve_target`
  for the table-scoped commands, and one `keymaps.TAB_VIEWS` table for tab slots 4-9. Output was
  verified byte-identical in each case.
- `require("dadbod-grip").get_opts()` returns a deep copy of the stored options instead of a
  hand-maintained field list, so a new option is no longer silently `nil` — and a table-valued
  `border` can no longer be mutated by a caller.
- Dropped the MariaDB detection path: both MySQL and MariaDB are driven with `--batch`, and the
  detection was reachable only from test hooks.
- `view.open()` accepts only the string form of `opts.view`; the dead numeric mapping (which
  disagreed with the four other copies of the tab-slot table) was removed rather than reconciled.
- Removed dead code across `connections.lua`, `ai.lua`, `properties.lua` and `profile.lua`, each
  checked for references across the whole tree first.
- README gained a `Credits` section naming the plugin's author, its maintainer and its outside
  contributors.

### Performance

- Grid rendering resolves each cell once per render instead of three times, and the CursorMoved
  column highlight is skipped when the highlighted column has not changed: 17.4 ms → 6.1 ms on a
  400×20 grid with staged edits, with byte-identical output.
- ASCII fast path in `truncate_display`, which previously asked `vim.fn` for the width of every
  character: 9.6× on a 4000-call grid workload (7.6 ms → 0.8 ms).
- AI prompt context fetches all columns in one batch query instead of looping per table: 91 → 62
  CLI spawns at the 30-table cap, with byte-identical prompt text.
- The FK view and `drop_table`'s referencing-FK check both use the single-query
  `get_referencing_foreign_keys` instead of spawning a CLI process per table in the schema.
- SQLite `get_indexes` runs one query joining `pragma_index_list`/`pragma_index_info` instead of
  N+1 process spawns (4 → 1 for a three-index table).
- `parse_csv` scans forward to the next quote and joins once, instead of appending byte by byte —
  the old form was quadratic in allocations on large blob and text columns.
- Completion caches alias parsing by `(bufnr, changedtick)` rather than re-parsing the whole query
  pad on every keystroke, and drops the entry on `BufWipeout`/`BufDelete`.
- Query history appends a single line instead of rewriting the whole JSONL file on every record,
  compacting only when the file overshoots its cap; `connections.switch()` reads the file once and
  writes at most once, where it previously read up to four times and wrote twice.
- The built-in picker memoizes `filtered_items()` per render, keyed on the live filter and item
  list, instead of re-scanning on every call.

### Contributors

- **Kimilhee** — multibyte/CJK cell padding and truncation
  ([PR #16](https://github.com/joryeugene/dadbod-grip.nvim/pull/16)).
- **joryeugene** — SQL Server adapter, PostgreSQL routines in the schema sidebar, focused ER diagram
  ([PR #17](https://github.com/joryeugene/dadbod-grip.nvim/pull/17)).

[Unreleased]: https://github.com/joryeugene/dadbod-grip.nvim/compare/v3.9.0...HEAD
[3.9.0]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.9.0
[3.8.0]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.8.0
