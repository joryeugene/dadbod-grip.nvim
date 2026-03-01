# dadbod-grip.nvim task runner
# Install just: https://github.com/casey/just

# Default recipe: run tests
default: test

# Run all unit tests (240 specs across 9 modules)
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
    sqlite3 tests/seed_sqlite.db < tests/seed_sqlite.sql

# Seed MySQL test database
seed-mysql:
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
    mysql -u root grip_test < tests/seed_mysql.sql

# Seed DuckDB test database
seed-duckdb:
    rm -f tests/seed_duckdb.duckdb
    duckdb tests/seed_duckdb.duckdb < tests/seed_duckdb.sql

# Seed httpfs demo: DuckDB connection + saved queries for remote URLs
seed-httpfs:
    mkdir -p .grip/queries
    echo '[{"name":"DuckDB (memory)","url":"duckdb::memory:"}]' > .grip/connections.json
    echo "SELECT species, island, avg(body_mass_g) as avg_mass FROM 'https://blobs.duckdb.org/data/penguins.csv' GROUP BY species, island ORDER BY avg_mass DESC" > .grip/queries/penguins-csv.sql
    echo "SELECT Pclass, Sex, count(*) as n, sum(Survived) as survived, round(100.0*sum(Survived)/count(*),1) as pct FROM 'https://raw.githubusercontent.com/datasciencedojo/datasets/master/titanic.csv' GROUP BY Pclass, Sex ORDER BY Pclass, Sex" > .grip/queries/titanic-csv.sql
    echo "SELECT symbol, min(price), max(price), round(max(price)-min(price),2) as range FROM 'https://vega.github.io/vega-datasets/data/stocks.csv' GROUP BY symbol ORDER BY range DESC" > .grip/queries/stocks-csv.sql
    echo "SELECT * FROM 'https://duckdb.org/data/prices.parquet' LIMIT 100" > .grip/queries/prices-parquet.sql
    echo "SELECT Origin, round(avg(Miles_per_Gallon),1) as mpg, round(avg(Horsepower),0) as hp, count(*) as n FROM 'https://vega.github.io/vega-datasets/data/cars.json' GROUP BY Origin" > .grip/queries/cars-json.sql
    echo "SELECT Species, round(avg(SepalLengthCm),2) as sepal, round(avg(PetalLengthCm),2) as petal, count(*) as n FROM 'https://huggingface.co/api/datasets/scikit-learn/iris/parquet/default/train/0.parquet' GROUP BY Species" > .grip/queries/iris-parquet.sql
    echo "SELECT userId, count(*) as total, sum(case when completed then 1 else 0 end) as done FROM 'https://duckdb.org/data/json/todos.json' GROUP BY userId ORDER BY done DESC" > .grip/queries/todos-json.sql

# Seed all test databases
seed-all: seed-pg seed-sqlite seed-mysql seed-duckdb

# Remove test database files
clean:
    rm -f tests/seed_sqlite.db tests/seed_duckdb.duckdb

# Open Neovim with the plugin loaded from this directory
dev:
    nvim --cmd "set rtp^=." -c "lua require('dadbod-grip').setup()"

# Open Neovim connected to DuckDB for httpfs testing
dev-httpfs: seed-httpfs
    nvim --cmd "set rtp^=." -c "lua require('dadbod-grip').setup()" -c "let g:db='duckdb::memory:'"

# Open Neovim and immediately connect to a SQLite test DB
dev-sqlite: seed-sqlite
    nvim --cmd "set rtp^=." -c "lua require('dadbod-grip').setup()" -c "let g:db='sqlite:tests/seed_sqlite.db'"

# Show git log for the current feature branch
log:
    git log --oneline --graph -20

# Count lines of Lua source (excluding tests)
loc:
    find lua/ -name '*.lua' | xargs wc -l | tail -1
