-- seed_sqlite.sql — pathological test fixtures for dadbod-grip (SQLite).
-- Usage: sqlite3 tests/seed_sqlite.db < tests/seed_sqlite.sql
--
-- Mirrors tests/seed_pg.sql (PostgreSQL) as closely as SQLite allows.
-- Covers: CRUD, composite PKs, JSON, unicode, wide tables,
-- binary data, empty tables, type diversity, long values,
-- foreign keys, pagination-scale data, aggregation targets.

-- Enable foreign keys (SQLite has them off by default)
PRAGMA foreign_keys = ON;

-- Clean slate (FK-aware drop order)
DROP VIEW  IF EXISTS no_pk_view;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS long_values;
DROP TABLE IF EXISTS type_zoo;
DROP TABLE IF EXISTS empty_table;
DROP TABLE IF EXISTS binary_blobs;
DROP TABLE IF EXISTS wide_table;
DROP TABLE IF EXISTS unicode_fun;
DROP TABLE IF EXISTS json_data;
DROP TABLE IF EXISTS composite_pk;
DROP TABLE IF EXISTS users;

-- ── users ────────────────────────────────────────────────────────────────
-- Normal CRUD: text, integer, timestamp, email. 15 rows for sort/filter.
CREATE TABLE users (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL,
  email      TEXT UNIQUE,
  age        INTEGER,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (name, email, age) VALUES
  ('Alice',     'alice@example.com',     30),
  ('Bob',       'bob@example.com',       25),
  ('Charlie',   'charlie@example.com',   NULL),
  ('Diana',     NULL,                    42),
  ('Eve',       'eve@example.com',       19),
  ('Frank',     'frank@example.com',     35),
  ('Grace',     'grace@example.com',     28),
  ('Hank',      'hank@example.com',      51),
  ('Ivy',       'ivy@example.com',       22),
  ('Jack',      'jack@example.com',      NULL),
  ('Karen',     'karen@example.com',     38),
  ('Leo',       'leo@example.com',       45),
  ('Mona',      'mona@example.com',      31),
  ('Nate',      NULL,                    27),
  ('Olivia',    'olivia@example.com',    33);

-- ── no_pk_view ───────────────────────────────────────────────────────────
-- Read-only mode (no primary key)
CREATE VIEW no_pk_view AS
  SELECT name, email, age FROM users WHERE age IS NOT NULL;

-- ── composite_pk ─────────────────────────────────────────────────────────
-- Composite primary key (two columns)
CREATE TABLE composite_pk (
  tenant_id  INTEGER NOT NULL,
  user_id    INTEGER NOT NULL,
  role       TEXT DEFAULT 'member',
  active     INTEGER DEFAULT 1,
  PRIMARY KEY (tenant_id, user_id)
);

INSERT INTO composite_pk (tenant_id, user_id, role, active) VALUES
  (1, 100, 'admin',  1),
  (1, 101, 'member', 1),
  (2, 100, 'viewer', 0),
  (2, 200, 'admin',  1);

-- ── products ─────────────────────────────────────────────────────────────
-- FK target for orders/order_items. 20 products across categories.
CREATE TABLE products (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  name     TEXT NOT NULL,
  price    REAL NOT NULL,
  category TEXT NOT NULL
);

INSERT INTO products (name, price, category) VALUES
  ('Widget A',       9.99,  'widgets'),
  ('Widget B',      14.99,  'widgets'),
  ('Widget C',      24.99,  'widgets'),
  ('Gadget X',      49.99,  'gadgets'),
  ('Gadget Y',      79.99,  'gadgets'),
  ('Gadget Z',     149.99,  'gadgets'),
  ('Doohickey 1',    4.99,  'accessories'),
  ('Doohickey 2',    7.99,  'accessories'),
  ('Doohickey 3',   12.99,  'accessories'),
  ('Thingamajig',   29.99,  'misc'),
  ('Whatchamacallit', 19.99, 'misc'),
  ('Gizmo Alpha',   99.99,  'gizmos'),
  ('Gizmo Beta',   199.99,  'gizmos'),
  ('Gizmo Gamma',  299.99,  'gizmos'),
  ('Part 001',       2.49,  'parts'),
  ('Part 002',       3.49,  'parts'),
  ('Part 003',       1.99,  'parts'),
  ('Part 004',       5.99,  'parts'),
  ('Premium Kit',  499.99,  'kits'),
  ('Starter Kit',   59.99,  'kits');

-- ── orders ───────────────────────────────────────────────────────────────
-- FK to users. 150 rows for pagination testing (page_size=100 → 2 pages).
-- Also tests sort on numeric/date columns and filter by FK values.
CREATE TABLE orders (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id    INTEGER NOT NULL REFERENCES users(id),
  total      REAL NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending',
  ordered_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Generate 150 orders across 15 users, varied totals and statuses
-- Use recursive CTE since SQLite may lack generate_series
WITH RECURSIVE seq(value) AS (
  SELECT 1 UNION ALL SELECT value + 1 FROM seq WHERE value < 150
)
INSERT INTO orders (user_id, total, status, ordered_at)
SELECT
  ((value - 1) % 15) + 1 AS user_id,
  ROUND(5.0 + (value * 7.3 % 500), 2) AS total,
  CASE (value % 5)
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'shipped'
    WHEN 2 THEN 'delivered'
    WHEN 3 THEN 'cancelled'
    WHEN 4 THEN 'returned'
  END AS status,
  datetime('2025-01-01', '+' || (value % 365) || ' days',
           '+' || (value * 37 % 24) || ' hours',
           '+' || (value * 13 % 60) || ' minutes') AS ordered_at
FROM seq;

-- ── order_items ──────────────────────────────────────────────────────────
-- FK to orders AND products. Multi-level FK navigation testing.
CREATE TABLE order_items (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  order_id    INTEGER NOT NULL REFERENCES orders(id),
  product_id  INTEGER NOT NULL REFERENCES products(id),
  quantity    INTEGER NOT NULL DEFAULT 1,
  unit_price  REAL NOT NULL
);

-- 1-3 items per order
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
  o.id AS order_id,
  ((o.id * 3 + item_num) % 20) + 1 AS product_id,
  (o.id + item_num) % 5 + 1 AS quantity,
  p.price AS unit_price
FROM orders o
CROSS JOIN (SELECT 0 AS item_num UNION ALL SELECT 1 UNION ALL SELECT 2) items
JOIN products p ON p.id = ((o.id * 3 + items.item_num) % 20) + 1
WHERE items.item_num < (o.id % 3) + 1;

-- ── json_data ────────────────────────────────────────────────────────────
-- JSON columns with nested objects, arrays, nulls
-- SQLite stores JSON as TEXT but supports json_* functions
CREATE TABLE json_data (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  metadata TEXT,
  config   TEXT,
  tags     TEXT
);

INSERT INTO json_data (metadata, config, tags) VALUES
  ('{"key": "value", "nested": {"deep": true}}',
   '{"theme": "dark", "notifications": {"email": true, "sms": false}}',
   '["alpha", "beta", "gamma"]'),
  (NULL,
   '{"theme": "light"}',
   '[]'),
  ('{"empty_obj": {}}',
   '{"list": [1, 2, 3], "null_val": null}',
   '["single"]'),
  ('{"special": "quotes ''and'' stuff"}',
   '{}',
   NULL);

-- ── unicode_fun ──────────────────────────────────────────────────────────
-- Emoji, CJK characters, RTL text, diacritics in cell values
CREATE TABLE unicode_fun (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT,
  value TEXT
);

INSERT INTO unicode_fun (label, value) VALUES
  ('emoji',      '🎉🚀💾🔥✨ Party time!'),
  ('cjk',        '日本語テスト 中文测试 한국어'),
  ('rtl',        'مرحبا بالعالم'),
  ('diacritics', 'Ñoño café résumé naïve Zürich'),
  ('mixed',      'Hello 世界 🌍 مرحبا'),
  ('math',       '∑∏∫∂∇ε → ∞'),
  ('box_draw',   '┌──┬──┐ │  │  │ └──┴──┘');

-- ── wide_table ───────────────────────────────────────────────────────────
-- 15+ columns to test horizontal scrolling/truncation
CREATE TABLE wide_table (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  col_a  TEXT,
  col_b  TEXT,
  col_c  TEXT,
  col_d  TEXT,
  col_e  TEXT,
  col_f  TEXT,
  col_g  TEXT,
  col_h  TEXT,
  col_i  TEXT,
  col_j  TEXT,
  col_k  TEXT,
  col_l  TEXT,
  col_m  TEXT,
  col_n  TEXT,
  col_o  TEXT
);

INSERT INTO wide_table (col_a, col_b, col_c, col_d, col_e, col_f, col_g, col_h,
                        col_i, col_j, col_k, col_l, col_m, col_n, col_o) VALUES
  ('alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel',
   'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar'),
  ('papa', 'quebec', 'romeo', 'sierra', 'tango', 'uniform', 'victor', 'whiskey',
   'xray', 'yankee', 'zulu', NULL, NULL, NULL, NULL);

-- ── binary_blobs ─────────────────────────────────────────────────────────
-- BLOB column with binary data
CREATE TABLE binary_blobs (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  data BLOB
);

INSERT INTO binary_blobs (name, data) VALUES
  ('tiny',    X'48656c6c6f'),
  ('zeros',   X'0000000000'),
  ('png_hdr', X'89504e470d0a1a0a');

-- ── empty_table ──────────────────────────────────────────────────────────
-- Zero rows (tests empty state rendering)
CREATE TABLE empty_table (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  value TEXT
);

-- ── type_zoo ─────────────────────────────────────────────────────────────
-- SQLite-specific: dynamic typing with 5 storage classes (NULL, INTEGER,
-- REAL, TEXT, BLOB). Declared column types control affinity but do not
-- constrain values. This table tests affinity edge cases, type coercion,
-- CHECK constraints, and values stored in non-obvious affinities.
CREATE TABLE type_zoo (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  -- INTEGER affinity
  flag           INTEGER,                           -- boolean as 0/1
  tiny_num       TINYINT,                           -- affinity: INTEGER
  small_num      SMALLINT,                          -- affinity: INTEGER
  medium_num     MEDIUMINT,                         -- affinity: INTEGER
  big_num        BIGINT,                            -- affinity: INTEGER
  unsigned_num   UNSIGNED BIG INT,                  -- affinity: INTEGER
  -- REAL affinity
  precise_num    NUMERIC(10,4),                     -- affinity: NUMERIC
  approx_num     REAL,
  double_num     DOUBLE PRECISION,                  -- affinity: REAL
  float_num      FLOAT,                             -- affinity: REAL
  -- TEXT affinity
  day            DATE,                              -- affinity: NUMERIC (stored as TEXT)
  tod            TIME,                              -- affinity: NUMERIC (stored as TEXT)
  moment         DATETIME,                          -- affinity: NUMERIC (stored as TEXT)
  guid           TEXT,
  ip_addr        TEXT,
  feeling        TEXT CHECK(feeling IN ('happy','sad','neutral')),
  json_val       TEXT,                              -- JSON stored as TEXT
  -- BLOB affinity
  raw_bytes      BLOB,
  -- NONE affinity (no declared type)
  untyped        ,                                  -- truly dynamic, no affinity
  -- exotic declared types (affinity rules)
  varchar_col    VARCHAR(255),                      -- affinity: TEXT
  nchar_col      NCHAR(50),                         -- affinity: TEXT
  clob_col       CLOB,                              -- affinity: TEXT
  native_char    CHARACTER(20),                     -- affinity: TEXT
  bool_col       BOOLEAN,                           -- affinity: NUMERIC
  decimal_col    DECIMAL(10,2)                      -- affinity: NUMERIC
);

INSERT INTO type_zoo (
  flag, tiny_num, small_num, medium_num, big_num, unsigned_num,
  precise_num, approx_num, double_num, float_num,
  day, tod, moment, guid, ip_addr, feeling, json_val,
  raw_bytes, untyped,
  varchar_col, nchar_col, clob_col, native_char, bool_col, decimal_col
) VALUES
  -- row 1: typical values, all within affinity expectations
  (1, 127, 32767, 8388607, 9223372036854775807, 4294967295,
   3.1416, 2.718, 1.7976931e+308, 0.1,
   '2025-01-15', '14:30:00', '2025-01-15T14:30:00+00:00',
   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '192.168.1.1',
   'happy', '{"key": "value", "list": [1,2,3]}',
   X'48656c6c6f', 'anything goes',
   'hello world', 'fixed width', 'large text block', 'char type', 1, 19.99),
  -- row 2: edge/boundary values, type coercion tests
  (0, -128, -32768, 0, 0, 0,
   0.0001, -0.5, -1.0e-307, -0.0,
   '1970-01-01', '00:00:00', '1970-01-01T00:00:00+00:00',
   '00000000-0000-0000-0000-000000000000', '::1',
   'sad', '[]',
   X'00', 42,
   '', '', '', '', 0, 0.00),
  -- row 3: text stored in INTEGER column (SQLite allows this)
  (NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL,
   NULL, NULL,
   NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL),
  -- row 4: type coercion oddities (SQLite does not enforce types)
  ('yes', 'not a number', 3.14, 'text in int', -9223372036854775808, 18446744073709551615,
   'not a number', 'text in real', 'also text', 'still text',
   12345, 67890, 99999,
   12345, 67890,
   'neutral', 'plain text not json',
   X'89504e470d0a1a0a', X'DEADBEEF',
   12345, 67890, 99999, 0, 'maybe', 'free text');

-- ── long_values ──────────────────────────────────────────────────────────
-- Cells with 500+ char strings, multiline text, SQL injection attempts
CREATE TABLE long_values (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT,
  body  TEXT
);

INSERT INTO long_values (label, body) VALUES
  ('long_string',
   'abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij'),
  ('multiline',
   'Line one
Line two
Line three

Line five after blank
	Tabbed line'),
  ('sql_injection',
   'Robert''); DROP TABLE users;--'),
  ('quotes_mix',
   'He said "hello" and she said ''goodbye'' and then {json: "value"}'),
  ('html_like',
   '<script>alert("xss")</script><b>bold</b>&amp;'),
  ('newlines_only',
   '


');
