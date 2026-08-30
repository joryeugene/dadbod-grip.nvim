# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Live PostgreSQL, MySQL, and MariaDB CI jobs now use Docker-assigned loopback ports discovered at
  runtime, which avoids collisions with local services and concurrent jobs. SQL Server no longer
  publishes an unused host port because its test wrapper executes inside the container.
- `.mise.toml` pins the repository's existing `just` tool at 1.40.0, so a normal local checkout
  activates the same task runner and plain `just test` works without a global mise default.

## [3.10.1] - 2026-08-30

### Security

- **AI provider requests no longer expose secrets or content in process arguments.** Grip invokes
  curl with a constant `curl --disable --silent --show-error --config -` command and sends the
  provider URL, headers, API key, prompt, schema context, existing SQL, and JSON body through curl
  config on stdin. Shell commands used by `api_key = "cmd:..."` also arrive through shell stdin.
  Transport and provider failures remain actionable without reproducing remote stderr, keys,
  prompts, or request bodies.
- **Database statements no longer appear in client argv.** PostgreSQL, MySQL/MariaDB, SQLite, and
  SQL Server now receive queries, schema reads, and mutations through stdin. PostgreSQL uses an
  invocation-scoped libpq service file for the password-free connection parameters because
  `PGDATABASE` treats a URI as a literal database name; its password remains in `PGPASSWORD`.
  MySQL keeps its SQL mode and optional read-only session statement on stdin, and SQL Server keeps
  `QUOTED_IDENTIFIER` and `NOCOUNT` behavior unchanged. SQL Server seed commands use
  `SQLCMDPASSWORD` instead of `-P`.
- **Linux process-boundary regressions inspect `/proc/<pid>/cmdline`.** The tests prove that API
  keys, provider URLs, prompts, schema text, SQL, mutation values, passwords, and complete DSNs
  stay out of argv while the intended stdin, environment, or invocation-scoped service channel
  receives them.

### Fixed

- **Attached-UI layout regressions are reproducible locally.** `just e2e-visual` opens the seeded
  workspace in a real tmux-backed Neovim UI, renders the grid at 100, 80, and 160 columns, and
  fails when the sidebar or main workspace violates its layout contract.
- **PostgreSQL stdin execution preserves failure semantics.** `ON_ERROR_STOP` makes a rejected
  statement exit nonzero as it did under `psql -c`, so server errors cannot be parsed as successful
  empty results.
- **Public setup and privacy documentation matches the code.** Query-pad AI uses `gA`; the demo
  requires either the DuckDB or SQLite CLI but no database server; the process boundary includes AI,
  formatting, and discovery helpers; and environment-carried credentials explicitly retain their
  same-user visibility limit. The backlog now contains only active, deferred, or genuinely unshipped
  work.

## [3.10.0] - 2026-08-29

### Fixed

- **Scheduled callback failures can no longer produce a green test run.** The
  headless harness records errors raised from `vim.schedule` callbacks and
  exits nonzero; a subprocess regression test proves both focused specs and
  the full runner fail correctly.
- **Layout tests no longer corrupt Neovim's headless grid.** Width policy is
  tested as pure arithmetic, the real headless workspace stays at its natural
  geometry, and spinner cleanup uses the public `:redraw` command instead of
  Neovim's experimental redraw API.
- **Saved queries no longer depend on a connection name or URL.** Persisted
  connections receive stable opaque IDs, new query metadata stores only that
  ID, and rename, promotion, deduplication, recent-use, and attachment edits
  preserve it. Safe legacy URL metadata remains readable; credential-bearing
  legacy URLs are removed and never auto-connected. A loaded query pad rebinds
  only after its saved connection switch succeeds.
- **SQL Server now executes shared grid SQL correctly.** `LIMIT`/`OFFSET` is
  translated to `OFFSET`/`FETCH`, every command enables quoted identifiers,
  and TLS URL options support validated optional, mandatory, and strict modes
  for both `sqlserver://` and `mssql://`.
- **MariaDB integer display widths no longer leak into schema labels.** Types
  such as `bigint(20) unsigned` render as `bigint unsigned` without losing
  modifiers.
- **Exports now distinguish the current page from every matching row.**
  All-row exports preserve filters and sorting, large exports are confirmed,
  clipboard output is capped, and file output uses a same-directory temporary
  file followed by atomic rename so cancellation and failure leave no partial
  destination.
- **Public adapter timeouts now honor `setup({ timeout = ... })`.** The value is
  used consistently by PostgreSQL, MySQL/MariaDB, SQLite, DuckDB, and SQL
  Server instead of being documented but ignored by most blocking calls.
- **Read-only file formats can no longer be overwritten as CSV.** XLSX and ORC
  remain queryable, but write mode is offered only when Grip has an explicit
  DuckDB `COPY` format. Picking a local file now opens it read-only unless the
  user deliberately enables write mode.
- **Hidden picker actions can no longer execute.** Contextual action predicates
  now guard the key handler as well as the footer, so a hidden write, promote,
  or connection action cannot run from its shortcut.
- **Opening a table dropped the spinner, then froze.** `init.open()` ran three round-trips —
  the `SELECT`, the primary-key lookup, and the pagination `COUNT` — but only the `SELECT` was
  inside the float. On a remote connection the spinner vanished, the editor sat frozen through
  two more adapter invocations, and only then did the grid appear. All three now run under one
  spinner, and the `COUNT` moving ahead of `view.open()` means the grid is rendered **once**
  instead of twice: `view.open()` takes `query_spec` and `total_rows` in its opts, so the first
  paint already reads `Page 1/N (M rows)` and the follow-up re-render is gone.
- **The loading spinner only covered the first query.** `init.open()` wrapped its opening
  query in `ui.blocking`, but every later reload went straight to `db.query`: sorting (`s`, `S`),
  filtering (`f`, `<C-f>`, `F`, `gn`, `gF`, presets), pagination (`H`/`L`, `[p`/`]p`, `[P`/`]P`),
  reset (`X`), refresh (`R`) and FK jumps (`gf`, `gm`). On anything slower than a local SQLite file
  those keys froze the editor with no indicator at all, so the grid looked hung. `do_refresh` is
  now split into `fetch_refresh` (the db round-trips) and `apply_refresh` (the render), and every
  reload path runs the fetch inside one spinner — `on_requery`'s COUNT and its page query share a
  single float instead of flashing two, and the FK jumps put their three or four round-trips behind
  one. Note for future callers: `ui.blocking()` forwards its `fn`'s returns through `table.unpack`,
  which drops everything after a leading `nil`, so work run inside it returns a single table
  (`{ result = ..., err = ... }`) rather than `nil, err` — otherwise the real db error is lost and
  the user is told "unknown error".
- **Connecting assembled the workspace on screen, one empty pane at a time.** `schema.toggle()`
  opened the sidebar split *before* `list_tables()`/`list_routines()`, and those block on a DB
  round-trip that pumps the event loop — so the terminal repainted with an empty sidebar next to
  an empty content area, held it for as long as the query took, then dropped the query pad in as
  a third paint before anything had content. The "connected to …" toast fired first of all,
  hanging alone over the blank layout. The schema is now fetched by the new `schema.prefetch(url)`
  while no sidebar exists yet, and `connections.switch()` builds sidebar, welcome screen and query
  pad inside a single `ui.blocking()` preloader with nothing blocking between them: the spinner
  covers the old screen until the whole workspace is ready, and lifts on a finished layout. The
  toast now follows it. `ui.blocking()` calls nest — an inner call relabels the float instead of
  closing it, so the file-open path (which runs its own spinner for the grid query) no longer
  flashes a half-built layout between the two.

- **`F` and `X` dropped you out of an FK context without saying so.** An FK jump (`gf`, `gm`)
  scopes the grid with a WHERE clause of its own — `"categoryId" = 15` for "the CategoryVersion
  rows referencing Category 15". That clause lived in `query_spec.filters` indistinguishable from
  a filter the user typed, so `clear_filters`/`reset` wiped it: `F` in an FK-navigated grid
  silently replaced 5 referencing rows with the whole table, while the breadcrumb still claimed
  `Organization > Category > CategoryVersion` and `<C-o>` popped back into a state that never
  existed. FK clauses are now *pinned* (`query.add_filter(spec, clause, { pinned = true })`):
  `build_sql`/`build_count_sql` still apply them, `clear_filters`/`reset`/`set_filters` keep them,
  and `has_filters` — hence the `[filtered]` badge and the `F`/`X`/`gP` guards — ignores them. The
  badge no longer claims you filtered something you didn't, and `gP` no longer bakes a clause
  bound to one parent row into a reusable preset. `query.user_filters(spec)` is the new accessor.
- **The query pad kept advertising the table you started from after an FK jump.** `sync_query`
  ran only from `init.open()`, and FK navigation swaps the spec *inside* an existing grid, so
  three hops into `Organization > Category > CategoryVersion` the pad still read
  `SELECT * FROM "Organization"` — a query returning a different result set than the grid below
  it. `gf`, `gm` and `<C-o>` now sync through the new `view._sync_pad()`, and `clean_sql` includes
  pinned filters so the synced SQL actually describes the rows on screen
  (`SELECT * FROM "CategoryVersion" WHERE ("categoryId" = 15)`). Sorts, user filters and
  pagination stay out of the pad, as before — those are transient, and rewriting the pad on every
  `f`/`s`/`H` keypress would clobber whatever you are composing there. `sync_query`'s docblock
  had listed FK navigation as a caller all along; now it is one. It also learned to write nothing
  when the pad already ends with the query being synced, so the round trip "run a query from the
  pad → `gf` away → `<C-o>` back" leaves that query in the pad once rather than twice, and the
  block it deduplicates onto stays the user's — a later jump appends below it instead of
  overwriting it.

- **`ga`, `gF` and filter-IS-NULL resolved the wrong column from the type row.** Four handlers
  open-coded "column under the cursor" by pairing `view._snap_col` with a byte-position map, and
  three of them passed `hdr_byte_positions` unconditionally. The rows do not share byte offsets:
  a type name too long for its column is truncated with `…`, which spends 3 bytes on 1 display
  cell, so every column after it sits elsewhere in the type row than in the header. With the
  cursor on the type row those three could aggregate, filter or build a filter against a
  neighbouring column. All four now call `ctx.cursor_column()`, which resolves through
  `resolve_row_bp` — the row-type-aware path the fourth copy (`=`, column width) already used.
- **The first attach of a scanner-backed database could time out and report itself as a broken
  DSN.** Attaching a `postgres:`/`mysql:`/`sqlite:`/`md:` database makes DuckDB fetch the matching
  scanner extension from `extensions.duckdb.org`, and that download had to fit inside the ordinary
  10-second query budget — together with the query itself. When it did not, `duckdb` was killed at
  code 124 and the failure surfaced as `Failed to attach database`, blaming a DSN that was
  perfectly good; on an already-attached connection the same 10 seconds covered a first query,
  a first DML statement or the completion pre-warm, whose budget is shorter still. A call whose
  `INSTALL` may actually have to fetch something now gets the same 60-second allowance an `httpfs`
  query has always had, across all four paths that spawn the CLI. The allowance is deliberately
  not unconditional: a warm `INSTALL` is a local no-op, so it is spent once per extension per
  session, and an attached database that has gone unreachable still fails in 10 seconds rather
  than 60. This is the same fetch that made CI's `test (stable)` leg fail 13 assertions about
  catalogs that were never attached, while the `v0.10.0` leg passed the same specs.
- **`s`, `S` and `gS` refused to work off a data row.** Sorting and column statistics are
  column-scoped, so pressing them with the cursor on the header — the most natural place to reach
  for a sort — did nothing but print "Move cursor to a column". `_snap_col`'s own docblock names
  sorting as a reason the snapping exists. They now resolve like every other column-scoped action.
  Actions that need a cell *value* (`f`, edits, yanks) still require a data row, by design.

### Added

- **`setup({ open_sidebar = false })`** opens directly into the main workspace.
  The sidebar still opens on demand, clamps on terminal shrink, and does not
  automatically grow over a deliberately narrow user size.
- **A shared data-file extension registry** now routes Parquet, CSV, TSV, JSON,
  NDJSON, JSONL, XLSX, ORC, Arrow, and IPC consistently from startup,
  connections, and schema discovery. Direct S3 file URLs follow the same
  route instead of falling through as table names.
- **Required live integration scenarios** cover schema discovery, CRUD,
  filtering, sorting, pagination, requery, atomic export, and DuckDB federation
  against PostgreSQL 16, MySQL 8.4, and MariaDB 11.8 on pull requests, with SQL
  Server 2025 as a nightly, manual, and tag gate. CI also runs Neovim 0.10 and
  stable, uploads LuaCov artifacts, pins Actions by commit, and gives workflows
  read-only permissions.
- **Documentation contract tests** compare public commands, all default
  mappings, and supported extensions against code so those lists cannot drift
  silently again.
- **A connection can reference its password instead of storing it.** Any `${VAR}` in a connection
  URL is resolved when you connect, from the `.env` file the new `env_file` entry field points at,
  falling back to the process environment. The secret stays where it already lives and never
  reaches `~/.grip/connections.json`. This is arranged so that no write path *can* leak it rather
  than by scrubbing the ones that exist today: `vim.g.db` holds the template, and expansion happens
  at the single dispatch point `db.resolve()`, so nothing that persists, logs, or displays a URL
  ever holds the expanded one. A placeholder that cannot be resolved is an error, and so is one
  that resolves to an empty value: a bare `KEY=` is the usual shape of a committed `.env` template,
  and substituting it would hand `psql` a URL with no password, which falls through to `~/.pgpass`
  and may connect with a *different* credential instead of failing. Either way the entry shows `?`
  in the picker and names the variable. A literal password containing `${WORD}` is written
  `$${WORD}`. `.env`
  contents are memoized on the file's mtime, so a rotated password is picked up on the next query,
  and failed reads are deliberately never cached, so `git-crypt unlock` takes effect on the very
  next connect with no restart — a still-locked file is reported as locked rather than as a parse
  error. The one cost: a templated URL is grip-only, because vim-dadbod's `:DB` and any statusline
  reading `g:db` see the literal `${VAR}`. New module `dadbod-grip.secrets`.

- **Read-only connections.** An entry with `"mode": "ro"` connects through the client's own
  read-only switch — `PGOPTIONS=-c default_transaction_read_only=on`, `SET SESSION TRANSACTION READ
  ONLY` merged into mysql's existing `--init-command` (a second `--init-command` flag would silently
  discard the first, taking `sql_mode` with it), and `-readonly` for sqlite and duckdb, applied only
  to a file that already exists: the flag aborts `duckdb::memory:` outright and turns "create it"
  into an error for a new sqlite file. Grid editing is off and the DDL entry points — `:GripCreate`,
  `:GripDrop`, `:GripRename`, `:GripFill`, the sidebar's create/drop, and the four column operations
  — decline locally instead of prompting you and then failing at the server. Press `r` in the
  connection picker to connect in the opposite mode for one session; the file is not touched.
  **This is a guard against accidents, not a security boundary** — every mechanism above is
  reversible from the query pad, and the actual boundary is a database role that cannot write. Two
  limits worth knowing: an `options=` already in a postgres URL beats `PGOPTIONS`, so such a
  connection reports `RO` while its session is not read-only — connecting it read-only warns once,
  because that badge otherwise claims more than the server was told; and sqlserver is unaffected
  because it was already read-only. New: `connections.current_mode()`,
  `connections.deny_if_readonly()`, `adapters.readonly_caveat()`.

- **A per-connection accent colour.** `"color"` on an entry takes a palette name (`green`,
  `orange`, `red`, `blue`, `violet`, `yellow`) or `#rrggbb`, and tints the window borders, the grid
  rules and the sidebar title, so a red prod connection does not look like a green local one. The
  palette reuses hexes already in the theme rather than introducing a second one, every accent
  carries a `ctermfg` (a user hex is approximated onto the xterm cube and grey ramp) so nothing
  requires truecolor, and an unknown value is ignored rather than raised. `GripBorder` is now
  *derived* from the accent, which is what makes leaving a coloured connection restore the default
  instead of stranding the border red. The groups `GripConnAccent` and `GripConnAccentBold` are
  redefined on every switch and re-applied from `ensure_highlights`, so they survive `:colorscheme`.
  New: `view.set_connection_accent()`.

- **ASCII distribution in the `gS` column-statistics popup.** Numeric columns get the eight
  `build_histogram_sql` buckets with their bounds labelled and their counts drawn as horizontal
  bars; every other type gets its top values the same way. Bars resolve to an eighth of a cell,
  and a non-zero count never renders as blank — one row out of ten million must not be
  indistinguishable from an empty bucket. `profile.hbar`, `profile.bucket_bounds`,
  `profile.is_bucketed`, `profile.gather_column` and `profile.build_column_lines` are the new
  public surface; the popup's logic moved out of the keymap closure into `profile.lua`, where it
  is unit-testable.

### Fixed

- **Date columns produced a meaningless sparkline in `gR`.** A date's `MIN`/`MAX` are timestamp
  strings, so `build_histogram_sql` always answered it with a top-values `GROUP BY` — but the
  branch that read the rows back listed `text`, `boolean` and `unknown` and left `date` out. Date
  rows therefore went down the bucketed path, where `tonumber("2025-01-02 13:13:00")` is `nil`,
  every value collapsed into bucket 1, and the column drew one bar and seven zeros with no top
  values to fall back on. Both sides now ask `profile.is_bucketed()`, so the SQL and the reader
  cannot disagree again.
- **Multibyte values were corrupted in the `gS` popup.** Top values were cut with
  `value:sub(1, 30)` — a byte offset derived from a display-cell budget — which sliced Cyrillic,
  CJK and emoji values mid-character. Labels are now truncated and padded with `ui.pad_display`.

### Changed

- **Health checks cover every supported integration.** `sqlcmd` is reported
  with the other database clients, and an installed Ollama executable satisfies
  the AI-provider check without requiring a cloud API key.
- **`gS` shows a distribution instead of a bare top-5 list.** Text, boolean and date columns list
  their top 8 values (was 5), and numeric columns show bucket ranges rather than individual
  values, since the top values of an `id`-like column are all count 1. The popup still issues
  exactly two queries: the distribution replaced its bespoke top-values query rather than adding
  to it.

- **CI installs the DuckDB CLI, so 66 previously unrun assertions actually run.**
  `duckdb_federation_spec`, `duckdb_native_schema_spec` and `duckdb_federated_schema_spec` gate on
  the `duckdb` binary and printed `SKIPPED` without it, while the runner still reported
  `ALL TESTS PASSED` — cross-database federation, native non-`main` schemas and schema-prefixed
  table names were never exercised on any push. The version is pinned (1.5.5) and the download
  checksum-verified, because those specs assert on catalog semantics that have changed across
  DuckDB minors; a bump should be a deliberate commit. The three specs still skip locally when
  `duckdb` is absent, but CI sets `GRIP_REQUIRE_DUCKDB=1`, which turns a missing binary into a
  failure so the install step cannot be dropped without the suite going red.

- **CI installs the DuckDB sqlite scanner before the suite runs.** The runner unzips a fresh CLI
  into `RUNNER_TEMP` each job, so `~/.duckdb` starts empty and the first federated query paid for
  the extension download inside its own timeout — which is how `test (stable)` went red on a
  commit that had nothing to do with it while `test (v0.10.0)`, on a different runner, passed.
  The install is now its own step, retried up to three times, so a slow fetch costs seconds
  instead of a spurious failure and an unreachable extension repository fails in a step that says
  so rather than as thirteen assertions about missing catalogs.

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

### Security

- **DuckDB SQL, attachment DSNs, and credentials no longer appear in process
  arguments.** Every DuckDB query is sent through stdin. Credentialed
  PostgreSQL/MySQL attachments use invocation-scoped temporary secrets, never
  persistent DuckDB secrets, and errors redact passwords and complete DSNs. A
  process-level `/proc/<pid>/cmdline` test guards the boundary. Prefix setup
  result sets are discarded before parsing so `CREATE SECRET` cannot replace
  the user's actual query result.
- **`psql`, `mysql` and `sqlcmd` passwords no longer travel in argv, and URLs no longer appear
  unredacted in error messages.** `psql -P`-style argv is readable by any user on the machine via
  `ps -eo args`, so the password now reaches those three clients through their environment instead:
  `PGPASSWORD` (percent-decoded, as libpq expects), `MYSQL_PWD` and `SQLCMDPASSWORD` (both verbatim
  — `parse_dadbod_url` deliberately does not decode, and decoding those would break existing
  passwords containing `%`). Two limits, both worth stating plainly. This protects against *other
  users*, not against a process running as you, which can read your environment just as easily as
  your argv. DuckDB federation is covered separately above because its credentials travel through
  temporary secrets on stdin rather than client environment variables. Separately, URLs in error
  text are now redacted through the shared `sql.redact_url`, including the case where the password
  itself contains an `@` — the authority is split on the last `@`, not the first, which previously
  left `p@ssw0rd` masked as `***@ssw0rd`. DuckDB's federation path got the same treatment the hard
  way: it rewrites the DSN you hand it before echoing it back in an error, so masking the DSN
  *string* could not work and the password *value* is masked wherever it appears, across all four
  places grip spawns the duckdb CLI.

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

[Unreleased]: https://github.com/joryeugene/dadbod-grip.nvim/compare/v3.10.1...HEAD
[3.10.1]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.10.1
[3.10.0]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.10.0
[3.9.0]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.9.0
[3.8.0]: https://github.com/joryeugene/dadbod-grip.nvim/releases/tag/v3.8.0
