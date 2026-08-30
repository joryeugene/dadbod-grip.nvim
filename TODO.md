# dadbod-grip.nvim backlog

Shipped work belongs in `CHANGELOG.md`. Review this file after each release and remove completed work instead of keeping checked boxes.

## Deferred

- Revisit required checks and branch protection only after the workflows prove stable.

## Product ideas

- Import CSV, TSV, or JSON from the clipboard or a pipe, preview the inferred columns, and stage the rows as inserts.
- Generate migration SQL that makes one table match another from the existing diff view.
- Add client-side virtual columns defined by project configuration without writing them to the database.
- Support DuckDB Iceberg/Delta Lake tables, spatial values, full-text search, and MotherDuck branches.
- Explain result sets and inherited queries with AI, and flag anomalies in profiling output.
- Add pgvector rendering, similarity-query helpers, and vector index details.
- Add Snowflake, BigQuery, Turso/libSQL, CockroachDB, ClickHouse, and Oracle adapters when a maintainer can test each against a real service.
- Support SQL Server `##temp` tables across CLI invocations.
- Add column reordering, bookmarked rows, saved grid views, and row pinning.
- Explore Neon branches, cross-connection schema diff, data-lineage views, user scripting hooks, credential-free query bundles, and schema-change detection.
