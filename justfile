# dadbod-grip.nvim task runner
# Install just: https://github.com/casey/just

# Default recipe: run tests
default: test

# Run all unit tests from a fresh deterministic SQLite fixture
test: seed-sqlite
    nvim --headless -u tests/minimal_init.lua -l tests/run_specs.lua

# Run a single spec file by name (e.g., just spec data)
spec name: seed-sqlite
    nvim --headless -u tests/minimal_init.lua -l tests/spec/{{name}}_spec.lua

# Lint with luacheck. Settings live in .luacheckrc; same args as CI.
# Install: luarocks --lua-version=5.1 --local install luacheck
lint:
    luacheck lua/ plugin/ lazy.lua tests/

# Seed PostgreSQL test database
seed-pg:
    createdb grip_test 2>/dev/null || true
    psql grip_test < tests/seed_pg.sql

# Seed SQLite test database
seed-sqlite:
    sqlite3 tests/seed_sqlite.db < tests/seed_sqlite.sql

# Seed MySQL test database
seed-mysql:
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
    mysql -u root grip_test < tests/seed_mysql.sql

# Seed SQL Server test database (requires sqlcmd and a local SQL Server instance)
seed-mssql:
    SQLCMDPASSWORD="${MSSQL_PASSWORD}" sqlcmd -S "${MSSQL_SERVER:-localhost,1433}" -U "${MSSQL_USER:-sa}" -Q "IF DB_ID('grip_test') IS NULL CREATE DATABASE grip_test"
    SQLCMDPASSWORD="${MSSQL_PASSWORD}" sqlcmd -S "${MSSQL_SERVER:-localhost,1433}" -U "${MSSQL_USER:-sa}" -d grip_test -i tests/seed_mssql.sql

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

# Seed all local test databases except SQL Server (requires MSSQL_PASSWORD)
seed-all: seed-pg seed-sqlite seed-mysql seed-duckdb

# Regenerate test databases from seed SQL
reseed: seed-sqlite seed-duckdb

# Open Neovim connected to the Softrear Analyst Portal (seeds on first run)
start:
    nvim --cmd "set rtp^=." -c "GripStart"

# Open Neovim with the plugin loaded from this directory
dev:
    nvim --cmd "set rtp^=."

# Render and verify the real attached workspace at 100, 80, and 160 columns
e2e-visual: seed-sqlite
    #!/usr/bin/env bash
    set -euo pipefail

    command -v tmux >/dev/null || { echo "e2e-visual requires tmux" >&2; exit 1; }
    command -v timeout >/dev/null || { echo "e2e-visual requires timeout" >&2; exit 1; }

    nvim_bin="${NVIM:-nvim}"
    command -v "$nvim_bin" >/dev/null || { echo "Neovim not found: $nvim_bin" >&2; exit 1; }

    session="grip-e2e-$$-$RANDOM"
    sync="$session"
    expected_columns="${GRIP_E2E_EXPECT_COLUMNS:-100}"

    cleanup() { tmux kill-session -t "$session" 2>/dev/null || true; }
    trap cleanup EXIT INT TERM

    tmux new-session -d -s "$session" -c "$PWD" /bin/bash --noprofile --norc
    tmux set-window-option -t "$session" window-size manual
    tmux set-option -t "$session" remain-on-exit on
    tmux resize-window -t "$session" -x 100 -y 36

    printf -v launch 'exec env GRIP_TMUX_SYNC=%q GRIP_EXPECT_COLUMNS=%q %q --cmd %q -u %q -c %q' \
      "$sync" "$expected_columns" "$nvim_bin" "set rtp^=." "tests/minimal_init.lua" \
      "lua vim.schedule(function() dofile('tests/fixtures/workspace_layout_integration.lua') end)"
    tmux send-keys -t "$session" "$launch" Enter

    wait_for() {
      if ! timeout 8s tmux wait-for "$sync-$1"; then
        echo "e2e-visual timed out waiting for $1" >&2
        tmux capture-pane -p -t "$session" >&2 || true
        exit 1
      fi
    }
    snapshot() {
      printf '\n=== Neovim attached UI: %s columns ===\n' "$1"
      tmux capture-pane -p -t "$session"
    }

    wait_for ready
    snapshot 100
    tmux resize-window -t "$session" -x 80 -y 30
    wait_for 80
    snapshot 80
    tmux resize-window -t "$session" -x 160 -y 40
    wait_for 160
    snapshot 160
    tmux resize-window -t "$session" -x 100 -y 36
    wait_for 100

    for _ in {1..100}; do
      [[ "$(tmux display-message -p -t "$session" '#{pane_dead}')" == 1 ]] && break
      sleep 0.05
    done
    if [[ "$(tmux display-message -p -t "$session" '#{pane_dead}')" != 1 ]]; then
      echo "e2e-visual Neovim process did not exit" >&2
      tmux capture-pane -p -t "$session" >&2
      exit 1
    fi

    status="$(tmux display-message -p -t "$session" '#{pane_dead_status}')"
    if [[ "$status" != 0 ]]; then
      echo "e2e-visual failed with status $status" >&2
      tmux capture-pane -p -t "$session" >&2
      exit "$status"
    fi
    echo "e2e-visual: attached UI passed at 100, 80, and 160 columns"

# Open Neovim connected to DuckDB for httpfs testing
dev-httpfs: seed-httpfs
    nvim --cmd "set rtp^=." -c "let g:db='duckdb::memory:'"

# Open Neovim and immediately connect to a SQLite test DB
dev-sqlite: seed-sqlite
    nvim --cmd "set rtp^=." -c "let g:db='sqlite:tests/seed_sqlite.db'"

# ── Watch / Write mode test fixtures ─────────────────────────────────────────

# Create a local CSV that grows by one row every 4 seconds (for --watch testing).
# Run this in a separate terminal, then in Neovim: :Grip /tmp/grip_watch.csv --watch
watch-fixture:
    #!/usr/bin/env bash
    FILE=/tmp/grip_watch.csv
    echo "id,name,score,ts" > "$FILE"
    echo "1,alice,90,$(date -u +%H:%M:%S)" >> "$FILE"
    echo "2,bob,75,$(date -u +%H:%M:%S)"   >> "$FILE"
    echo "Watching: appending to $FILE every 4s: Ctrl-C to stop"
    N=3
    while true; do
        sleep 4
        echo "$N,user_$N,$((RANDOM % 100)),$(date -u +%H:%M:%S)" >> "$FILE"
        echo "  row $N appended ($(wc -l < "$FILE") rows total)"
        N=$((N + 1))
    done

# Create a writable CSV for --write testing.
# Then in Neovim: :Grip /tmp/grip_write.csv --write
write-fixture:
    #!/usr/bin/env bash
    FILE=/tmp/grip_write.csv
    printf 'id,first_name,last_name,score,active\n' > "$FILE"
    printf '1,alice,smith,88,true\n'  >> "$FILE"
    printf '2,bob,jones,74,true\n'    >> "$FILE"
    printf '3,carol,white,95,false\n' >> "$FILE"
    printf '4,dave,black,61,true\n'   >> "$FILE"
    printf '5,eve,grey,82,false\n'    >> "$FILE"
    echo "Write fixture ready: $FILE"
    echo "In Neovim: :Grip /tmp/grip_write.csv --write"

# Create a Parquet fixture for --write testing (requires DuckDB).
write-fixture-parquet:
    duckdb -c "COPY (SELECT i AS id, 'user_'||i AS name, (random()*100)::int AS score FROM range(1,11) t(i)) TO '/tmp/grip_write.parquet' (FORMAT PARQUET)"
    echo "Parquet fixture ready: /tmp/grip_write.parquet"
    echo "In Neovim: :Grip /tmp/grip_write.parquet --write"

# Open Neovim ready to test --watch (fixture must be running in another terminal)
dev-watch: seed-httpfs
    nvim --cmd "set rtp^=." -c "Grip /tmp/grip_watch.csv --watch"

# Open Neovim ready to test --write on CSV
dev-write: write-fixture
    nvim --cmd "set rtp^=." -c "Grip /tmp/grip_write.csv --write"

# Open Neovim ready to test --write on Parquet
dev-write-parquet: write-fixture-parquet
    nvim --cmd "set rtp^=." -c "Grip /tmp/grip_write.parquet --write"

# Show git log for the current feature branch
log:
    git log --oneline --graph -20

# Count lines of Lua source (excluding tests)
loc:
    find lua/ -name '*.lua' | xargs wc -l | tail -1
