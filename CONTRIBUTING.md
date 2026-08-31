# Contributing to Dadbod Grip

Dadbod Grip welcomes focused bug fixes, documentation corrections, and features that can be exercised against a real database client.

## Prepare a checkout

Install the repository tools pinned by Mise:

```sh
mise install
```

Install LuaCheck if it is not already available:

```sh
luarocks --lua-version=5.1 --local install luacheck
```

The deterministic suite requires Neovim 0.10 or newer and `sqlite3`. Tests for a specific adapter also require that adapter's command-line client.

Use a short, purpose-based branch name such as `fix/mysql-null-values` or `docs/connection-setup`. Do not add an agent or tool prefix.

## Run the local gates

Run the focused spec while developing, then run the local CI gates:

```sh
just spec data
just check
```

Use `NVIM=/path/to/nvim just test` for a specific supported Neovim. For an
already-running database, set `GRIP_TEST_LIVE_URL` and run `just test-live
postgresql-16`, `mysql-8.4`, `mariadb-11.8`, `sqlserver-2025`, or `sqlite`.

Run `just e2e-visual` when a change can affect window creation, sidebar sizing, the query pad, grid rendering, or resize behavior. It opens a real tmux-backed Neovim UI at 100, 80, and 160 columns.

Live PostgreSQL, MySQL, MariaDB, and SQL Server jobs run in GitHub Actions.

## Scan for secrets

Enable the repository's optional native Git hook:

```sh
git config core.hooksPath .githooks
```

Run the complete redacted history scan at any time:

```sh
mise exec -- gitleaks git --redact --verbose
```

Never commit a credential, a Gitleaks report, or a broad allowlist. If a real secret is found, revoke or rotate it before discussing history cleanup.

## Prepare a pull request

Keep each pull request focused on one behavior. Add the smallest regression that fails without the change, and use existing helpers before introducing another abstraction or dependency.

Update `CHANGELOG.md` under `Unreleased` when user-visible behavior changes. Update `:help dadbod-grip` when a command, keymap, option, or workflow changes; the README should remain an onboarding guide rather than a second reference manual.

Describe the problem, the chosen fix, and the commands you ran. Do not include database URLs, credentials, private schema text, or production output in the pull request.

Report suspected vulnerabilities through the private channel in [SECURITY.md](SECURITY.md), not through a public issue.
