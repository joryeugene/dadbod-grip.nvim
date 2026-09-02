# dadbod-grip.nvim

<p align="center">
<img src="docs/brand/dadbod-grip-wordmark.png" width="620" alt="Dadbod Grip">
</p>

<p align="center">
<a href="https://jorypestorious.com/dadbod-grip-web/"><img src="https://img.shields.io/badge/docs-website-4ade80.svg" alt="Documentation"></a>&nbsp;
<a href="https://github.com/joryeugene/dadbod-grip.nvim/blob/main/LICENSE"><img src="https://img.shields.io/github/license/joryeugene/dadbod-grip.nvim.svg" alt="MIT License"></a>&nbsp;
<img src="https://img.shields.io/badge/Neovim-0.10%2B-green.svg" alt="Neovim 0.10+">&nbsp;
<a href="https://github.com/joryeugene/dadbod-grip.nvim/actions/workflows/test.yml"><img src="https://github.com/joryeugene/dadbod-grip.nvim/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
</p>

<p align="center">
<b>Dadbod Grip turns database tables into editable Vim buffers, with schema browsing, staged mutations, generated SQL, relationship navigation, and cross-database federation inside Neovim.</b>
</p>

<p align="center">
<img src="https://jorypestorious.com/dadbod-grip-web/mascot.gif" width="160" alt="Chonk, the Dadbod Grip mascot"><br>
<sub><b>Chonk</b></sub>
</p>

**Workflow.** Browse a schema, edit rows with Vim motions, follow foreign keys, and run saved SQL without leaving the editor.

**Safety.** Changes remain staged until you review the generated SQL and apply one transaction.

**In this frame.** The schema sidebar, query pad, and editable grid keep navigation, SQL, and pending mutations visible together.

<p align="center">
<img src="https://jorypestorious.com/dadbod-grip-web/live.png" alt="The Dadbod Grip workspace shows a schema sidebar, query pad, and editable grid with staged changes." width="900">
</p>

## Start in five minutes

### Requirements

Dadbod Grip requires Neovim 0.10 or newer and the command-line client for each database you use.

| Data source | Required client |
|---|---|
| PostgreSQL | `psql` |
| MySQL or MariaDB | `mysql` |
| SQLite | `sqlite3` |
| DuckDB, local files, HTTP, or S3 | `duckdb` |
| SQL Server | `sqlcmd` |

The built-in demo requires either `duckdb` or `sqlite3`, but it requires no database server or manual setup. DuckDB loads the full dataset; SQLite provides a compact fallback. Install both CLIs to include the automatically attached supplier-federation chapter. Dadbod Grip has no required Lua dependencies. vim-dadbod-ui, completion plugins, SQL formatters, and AI providers are optional integrations.

### Install with lazy.nvim

```lua
{
  "joryeugene/dadbod-grip.nvim",
  opts = {},
  keys = {
    { "<leader>db", "<cmd>GripConnect<cr>", desc = "Database connections" },
  },
}
```

The plugin ships its own Lazy command triggers. Do not copy a `cmd` list or add a version wildcard.

Restart Neovim, then check the clients available on your machine:

```vim
:checkhealth dadbod-grip
```

Open the disposable demo:

```vim
:GripStart
```

The demo recreates its database from the bundled seed each time, so edits cannot damage your own data.

### Connect to a database

Run the picker to select, add, or discover a connection:

```vim
:GripConnect
```

You can also connect directly:

```vim
:GripConnect postgresql://user:password@localhost:5432/app
:GripConnect mysql://user:password@localhost:3306/app
:GripConnect mariadb://user:password@localhost:3306/app
:GripConnect sqlite:/absolute/path/to/app.db
:GripConnect duckdb:/absolute/path/to/warehouse.duckdb
:GripConnect sqlserver://user:password@localhost:1433/app
```

New connections save to `.grip/connections.json` in the project. Press `G` in the connection picker to promote a connection to `~/.grip/connections.json`, where it becomes available across projects. Existing `g:dbs`, `$DATABASE_URL`, `g:db`, and labeled local Docker containers also appear in the picker.

To keep a password out of the connection file, use an environment placeholder:

```json
{
  "name": "development",
  "url": "postgresql://app:${APP_DB_PASSWORD}@localhost:5432/app"
}
```

Dadbod Grip resolves placeholders when it connects. An unresolved or empty value fails instead of silently trying another credential source. The [connection guide](https://jorypestorious.com/dadbod-grip-web/docs/features/connections) covers project files, global files, `.env` files, read-only sessions, colors, and DuckDB attachments.

### Edit your first table

After connecting:

1. Put the cursor on a table in the schema sidebar and press `<CR>`.
2. Move to a cell and press `i` or `<CR>` to edit it.
3. Press `<CR>` in the cell editor to stage the value.
4. Press `gs` to inspect the SQL for every staged change.
5. Press `a` to confirm and apply the changes in one transaction.

Use `u` to undo one staged edit or `U` to discard every staged edit. Press `?` in any Dadbod Grip buffer for the complete context-sensitive keymap.

## Everyday workflow

These commands cover the normal path:

| Command | Purpose |
|---|---|
| `:GripConnect` | Opens the connection picker and full workspace. |
| `:GripStart` | Recreates and opens the built-in demo. |
| `:Grip users` | Opens a table in an editable grid. |
| `:Grip SELECT * FROM users` | Runs SQL and opens the result. |
| `:GripQuery` | Opens the query pad. |
| `:GripAsk` | Generates SQL from a natural-language request. |
| `:GripExport` | Exports the current page or every matching row. |
| `:GripImport` | Previews and stages CSV, TSV, or JSON rows from the clipboard or `!command`. |
| `:GripHome` | Returns to the welcome screen. |

In the query pad, `<C-CR>` runs SQL and `gA` generates SQL. In the grid, `f` filters by the current cell, `s` sorts the current column, `gf` follows a foreign key, and `gE` exports to the clipboard.

The complete command and keymap reference lives in `:help dadbod-grip`. The [documentation website](https://jorypestorious.com/dadbod-grip-web/) provides task-focused guides and screenshots.

## Files and federation

Open a supported local or remote file with `:Grip`:

```vim
:Grip /data/orders.parquet
:Grip /data/events.jsonl
:Grip https://example.com/report.csv
:Grip s3://analytics-bucket/warehouse/orders.parquet
```

Supported extensions: .parquet .csv .tsv .json .ndjson .jsonl .xlsx .orc .arrow .ipc

DuckDB supplies file access and cross-database federation. CSV, TSV, JSON, NDJSON, JSONL, Parquet, Arrow, and IPC files can opt into write mode. XLSX and ORC remain read-only because Dadbod Grip does not have an explicit safe write format for them.

Use `:GripAttach` from a DuckDB connection to attach another database, then query across sources from one query pad. Persisted attachments return with their parent connection.

## Configuration

Dadbod Grip calls `setup()` with sensible defaults. Override only what you need:

```lua
require("dadbod-grip").setup({
  limit = 100,
  timeout = 10000,
  completion = true,
  open_sidebar = true,
})
```

Set `open_sidebar = false` to connect directly into the main workspace. Set `completion = false` when another completion engine owns SQL suggestions. Set `ai = false` to skip SQL generation and schema preloading; the AI keys remain registered and explain that AI is disabled.

All default values, picker integrations, connection fields, remappable actions, and AI-provider options live in `:help grip-config` and the [getting-started guide](https://jorypestorious.com/dadbod-grip-web/docs/getting-started).

## Safety and privacy

Dadbod Grip stages cell edits, inserted rows, and deletions in memory. Nothing reaches the database until you inspect the generated SQL and confirm the apply action. A connection with `"mode": "ro"` disables editing and asks the database client for a read-only session, but database permissions remain the real security boundary.

Dadbod Grip sends all database SQL and AI request content through stdin. Statements, mutation values, prompts, schema context, existing SQL, and request bodies stay out of process arguments. API-key lookup commands also enter the shell through stdin.

For `:GripImport !command`, the parent shell receives the script through stdin, but child commands retain normal shell argument visibility. Pass credentials through environment variables, stdin, or configuration files instead of command arguments.

Passwords and connection parameters use client environment variables or invocation-scoped files instead of command arguments. Processes running as your user may still read those environment variables, so this prevents casual process-list exposure rather than replacing operating-system isolation.

Credentialed DuckDB federation uses an invocation-scoped DuckDB secret and never creates a persistent DuckDB secret. Saved queries bind to an opaque connection ID instead of copying a URL or password into the SQL file.

Read [SECURITY.md](SECURITY.md) to report a vulnerability privately.

## Load a local checkout

Keep the repository name so Lazy retains the plugin identity, and use `dir` to load your development checkout:

```lua
{
  "joryeugene/dadbod-grip.nvim",
  dir = "~/Documents/github/dadbod-grip.nvim",
  opts = {},
}
```

Lazy should show the local directory instead of a cached release. The development checkout should remain on `main`; use Git worktrees for feature branches.

## Documentation

- Run `:help dadbod-grip` for the exhaustive in-editor manual.
- Read the [website](https://jorypestorious.com/dadbod-grip-web/) for guided workflows.
- Use [`keymaps.json`](keymaps.json) as the machine-readable catalog for persistent mappings.
- Follow the [demo investigation](demo/softrear-internal.md) to explore the bundled database.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) before preparing a change.
- Review [CHANGELOG.md](CHANGELOG.md) for shipped behavior.

## Ecosystem

Dadbod Grip works by itself and can also read vim-dadbod and vim-dadbod-ui connection variables. It is listed in [awesome-neovim](https://github.com/rockerBOO/awesome-neovim).

## Contributors

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and open a focused pull request when you see something Dadbod Grip can do better.

A special thank-you to [Gleb Yavorski (@GlebYavorski)](https://github.com/GlebYavorski) for his contributions.

[Jory Pestorious (@joryeugene)](https://github.com/joryeugene) created and maintains Dadbod Grip, which is available under the [MIT License](LICENSE).
