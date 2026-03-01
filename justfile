# dadbod-grip.nvim task runner
# Install just: https://github.com/casey/just

# Default recipe: run tests
default: test

# Run all unit tests (197 specs across 8 modules)
test:
    nvim --headless -u tests/minimal_init.lua -l tests/run_specs.lua

# Run a single spec file by name (e.g., just spec data)
spec name:
    nvim --headless -u tests/minimal_init.lua -l tests/spec/{{name}}_spec.lua

# Lint with luacheck (if installed)
lint:
    luacheck lua/ --no-unused-args --no-max-line-length

# Seed PostgreSQL test database
seed-pg:
    createdb grip_test 2>/dev/null || true
    psql grip_test < tests/seed.sql

# Seed SQLite test database
seed-sqlite:
    sqlite3 tests/grip_test.db < tests/seed_sqlite.sql

# Seed MySQL test database
seed-mysql:
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
    mysql -u root grip_test < tests/seed_mysql.sql

# Seed DuckDB test database
seed-duckdb:
    rm -f tests/grip_test.duckdb
    duckdb tests/grip_test.duckdb < tests/seed_duckdb.sql

# Seed all test databases
seed-all: seed-pg seed-sqlite seed-mysql seed-duckdb

# Remove test database files
clean:
    rm -f tests/grip_test.db tests/grip_test.duckdb

# Open Neovim with the plugin loaded from this directory
dev:
    nvim --cmd "set rtp^=." -c "lua require('dadbod-grip').setup()"

# Open Neovim and immediately connect to a SQLite test DB
dev-sqlite: seed-sqlite
    nvim --cmd "set rtp^=." -c "lua require('dadbod-grip').setup()" -c "let g:db='sqlite:tests/grip_test.db'"

# Show git log for the current feature branch
log:
    git log --oneline --graph -20

# Count lines of Lua source (excluding tests)
loc:
    find lua/ -name '*.lua' | xargs wc -l | tail -1
