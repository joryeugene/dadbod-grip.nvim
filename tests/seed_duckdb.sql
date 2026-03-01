-- seed_duckdb.sql — pathological test fixtures for dadbod-grip (DuckDB).
-- Usage: duckdb tests/grip_test.duckdb < tests/seed_duckdb.sql
--
-- Covers: CRUD, composite PKs, JSON, unicode, wide tables,
-- binary data, empty tables, type diversity, long values,
-- foreign keys, pagination-scale data, aggregation targets.

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
DROP TYPE  IF EXISTS mood;

-- ── users ────────────────────────────────────────────────────────────────
-- Normal CRUD: varchar, integer, timestamp, email. 15 rows for sort/filter.
CREATE TABLE users (
  id         INTEGER PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(255) UNIQUE,
  age        INTEGER,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE SEQUENCE users_id_seq START 16;

INSERT INTO users (id, name, email, age) VALUES
  (1,  'Alice',     'alice@example.com',     30),
  (2,  'Bob',       'bob@example.com',       25),
  (3,  'Charlie',   'charlie@example.com',   NULL),
  (4,  'Diana',     NULL,                    42),
  (5,  'Eve',       'eve@example.com',       19),
  (6,  'Frank',     'frank@example.com',     35),
  (7,  'Grace',     'grace@example.com',     28),
  (8,  'Hank',      'hank@example.com',      51),
  (9,  'Ivy',       'ivy@example.com',       22),
  (10, 'Jack',      'jack@example.com',      NULL),
  (11, 'Karen',     'karen@example.com',     38),
  (12, 'Leo',       'leo@example.com',       45),
  (13, 'Mona',      'mona@example.com',      31),
  (14, 'Nate',      NULL,                    27),
  (15, 'Olivia',    'olivia@example.com',    33);

-- ── no_pk_view ───────────────────────────────────────────────────────────
-- Read-only mode (no primary key)
CREATE VIEW no_pk_view AS
  SELECT name, email, age FROM users WHERE age IS NOT NULL;

-- ── composite_pk ─────────────────────────────────────────────────────────
-- Composite primary key (two columns)
CREATE TABLE composite_pk (
  tenant_id  INTEGER NOT NULL,
  user_id    INTEGER NOT NULL,
  role       VARCHAR(50) DEFAULT 'member',
  active     BOOLEAN DEFAULT TRUE,
  PRIMARY KEY (tenant_id, user_id)
);

INSERT INTO composite_pk (tenant_id, user_id, role, active) VALUES
  (1, 100, 'admin',  TRUE),
  (1, 101, 'member', TRUE),
  (2, 100, 'viewer', FALSE),
  (2, 200, 'admin',  TRUE);

-- ── products ─────────────────────────────────────────────────────────────
-- FK target for orders/order_items. 20 products across categories.
CREATE TABLE products (
  id       INTEGER PRIMARY KEY,
  name     VARCHAR(100) NOT NULL,
  price    DECIMAL(10,2) NOT NULL,
  category VARCHAR(50) NOT NULL
);

CREATE SEQUENCE products_id_seq START 21;

INSERT INTO products (id, name, price, category) VALUES
  (1,  'Widget A',       9.99,  'widgets'),
  (2,  'Widget B',      14.99,  'widgets'),
  (3,  'Widget C',      24.99,  'widgets'),
  (4,  'Gadget X',      49.99,  'gadgets'),
  (5,  'Gadget Y',      79.99,  'gadgets'),
  (6,  'Gadget Z',     149.99,  'gadgets'),
  (7,  'Doohickey 1',    4.99,  'accessories'),
  (8,  'Doohickey 2',    7.99,  'accessories'),
  (9,  'Doohickey 3',   12.99,  'accessories'),
  (10, 'Thingamajig',   29.99,  'misc'),
  (11, 'Whatchamacallit', 19.99, 'misc'),
  (12, 'Gizmo Alpha',   99.99,  'gizmos'),
  (13, 'Gizmo Beta',   199.99,  'gizmos'),
  (14, 'Gizmo Gamma',  299.99,  'gizmos'),
  (15, 'Part 001',       2.49,  'parts'),
  (16, 'Part 002',       3.49,  'parts'),
  (17, 'Part 003',       1.99,  'parts'),
  (18, 'Part 004',       5.99,  'parts'),
  (19, 'Premium Kit',  499.99,  'kits'),
  (20, 'Starter Kit',   59.99,  'kits');

-- ── orders ───────────────────────────────────────────────────────────────
-- FK to users. 150 rows for pagination testing (page_size=100 → 2 pages).
CREATE TABLE orders (
  id         INTEGER PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users(id),
  total      DECIMAL(10,2) NOT NULL,
  status     VARCHAR(20) NOT NULL DEFAULT 'pending',
  ordered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE SEQUENCE orders_id_seq START 151;

-- Generate 150 orders using generate_series
INSERT INTO orders (id, user_id, total, status, ordered_at)
SELECT
  g AS id,
  ((g - 1) % 15) + 1 AS user_id,
  ROUND(5.0 + (g * 7.3) % 500, 2) AS total,
  CASE (g % 5)
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'shipped'
    WHEN 2 THEN 'delivered'
    WHEN 3 THEN 'cancelled'
    WHEN 4 THEN 'returned'
  END AS status,
  TIMESTAMP '2025-01-01' + INTERVAL (g % 365) DAY
    + INTERVAL (g * 37 % 24) HOUR
    + INTERVAL (g * 13 % 60) MINUTE AS ordered_at
FROM generate_series(1, 150) AS t(g);

-- ── order_items ──────────────────────────────────────────────────────────
-- FK to orders AND products. Multi-level FK navigation testing.
CREATE TABLE order_items (
  id          INTEGER PRIMARY KEY,
  order_id    INTEGER NOT NULL REFERENCES orders(id),
  product_id  INTEGER NOT NULL REFERENCES products(id),
  quantity    INTEGER NOT NULL DEFAULT 1,
  unit_price  DECIMAL(10,2) NOT NULL
);

-- 1-3 items per order
INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
  ROW_NUMBER() OVER () AS id,
  o.id AS order_id,
  ((o.id * 3 + item_num) % 20) + 1 AS product_id,
  (o.id + item_num) % 5 + 1 AS quantity,
  p.price AS unit_price
FROM orders o
CROSS JOIN (VALUES (0), (1), (2)) AS items(item_num)
JOIN products p ON p.id = ((o.id * 3 + items.item_num) % 20) + 1
WHERE items.item_num < (o.id % 3) + 1;

-- ── json_data ────────────────────────────────────────────────────────────
-- JSON columns with nested objects, arrays, nulls
CREATE TABLE json_data (
  id       INTEGER PRIMARY KEY,
  metadata JSON,
  config   JSON,
  tags     JSON
);

INSERT INTO json_data (id, metadata, config, tags) VALUES
  (1, '{"key": "value", "nested": {"deep": true}}',
      '{"theme": "dark", "notifications": {"email": true, "sms": false}}',
      '["alpha", "beta", "gamma"]'),
  (2, NULL,
      '{"theme": "light"}',
      '[]'),
  (3, '{"empty_obj": {}}',
      '{"list": [1, 2, 3], "null_val": null}',
      '["single"]'),
  (4, '{"special": "quotes and stuff"}',
      '{}',
      NULL);

-- ── unicode_fun ──────────────────────────────────────────────────────────
-- Emoji, CJK characters, RTL text, diacritics in cell values
CREATE TABLE unicode_fun (
  id    INTEGER PRIMARY KEY,
  label VARCHAR(200),
  value TEXT
);

INSERT INTO unicode_fun (id, label, value) VALUES
  (1, 'emoji',      '🎉🚀💾🔥✨ Party time!'),
  (2, 'cjk',        '日本語テスト 中文测试 한국어'),
  (3, 'rtl',        'مرحبا بالعالم'),
  (4, 'diacritics', 'Ñoño café résumé naïve Zürich'),
  (5, 'mixed',      'Hello 世界 🌍 مرحبا'),
  (6, 'math',       '∑∏∫∂∇ε → ∞'),
  (7, 'box_draw',   '┌──┬──┐ │  │  │ └──┴──┘');

-- ── wide_table ───────────────────────────────────────────────────────────
-- 15+ columns to test horizontal scrolling/truncation
CREATE TABLE wide_table (
  id    INTEGER PRIMARY KEY,
  col_a VARCHAR(30),
  col_b VARCHAR(30),
  col_c VARCHAR(30),
  col_d VARCHAR(30),
  col_e VARCHAR(30),
  col_f VARCHAR(30),
  col_g VARCHAR(30),
  col_h VARCHAR(30),
  col_i VARCHAR(30),
  col_j VARCHAR(30),
  col_k VARCHAR(30),
  col_l VARCHAR(30),
  col_m VARCHAR(30),
  col_n VARCHAR(30),
  col_o VARCHAR(30)
);

INSERT INTO wide_table (id, col_a, col_b, col_c, col_d, col_e, col_f, col_g, col_h,
                        col_i, col_j, col_k, col_l, col_m, col_n, col_o) VALUES
  (1, 'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel',
      'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar'),
  (2, 'papa', 'quebec', 'romeo', 'sierra', 'tango', 'uniform', 'victor', 'whiskey',
      'xray', 'yankee', 'zulu', NULL, NULL, NULL, NULL);

-- ── binary_blobs ─────────────────────────────────────────────────────────
-- BLOB column with binary data
CREATE TABLE binary_blobs (
  id   INTEGER PRIMARY KEY,
  name VARCHAR(50),
  data BLOB
);

INSERT INTO binary_blobs (id, name, data) VALUES
  (1, 'tiny',    '\x48656c6c6f'::BLOB),
  (2, 'zeros',   '\x0000000000'::BLOB),
  (3, 'png_hdr', '\x89504e470d0a1a0a'::BLOB);

-- ── empty_table ──────────────────────────────────────────────────────────
-- Zero rows (tests empty state rendering)
CREATE TABLE empty_table (
  id    INTEGER PRIMARY KEY,
  value TEXT
);

-- ── type_zoo ─────────────────────────────────────────────────────────────
-- DuckDB-specific: BOOLEAN, TINYINT through HUGEINT, UINTEGER variants,
-- DOUBLE, DECIMAL, DATE, TIME, TIMETZ, TIMESTAMP variants (S/MS/NS),
-- INTERVAL, UUID, BLOB, BIT, ENUM, JSON, LIST, STRUCT, MAP, UNION
CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral');

CREATE TABLE type_zoo (
  id              INTEGER PRIMARY KEY,
  -- booleans and integers (all sizes)
  flag            BOOLEAN,
  tiny_num        TINYINT,
  small_num       SMALLINT,
  regular_num     INTEGER,
  big_num         BIGINT,
  huge_num        HUGEINT,
  -- unsigned integers
  utiny_num       UTINYINT,
  usmall_num      USMALLINT,
  uregular_num    UINTEGER,
  ubig_num        UBIGINT,
  -- decimals
  precise_num     DECIMAL(10,4),
  approx_float    REAL,
  approx_double   DOUBLE,
  -- date/time
  day             DATE,
  tod             TIME,
  tod_tz          TIMETZ,
  moment          TIMESTAMPTZ,
  moment_s        TIMESTAMP_S,
  moment_ms       TIMESTAMP_MS,
  moment_ns       TIMESTAMP_NS,
  duration        INTERVAL,
  -- identifiers
  guid            UUID,
  -- binary
  raw_bytes       BLOB,
  bits            BIT,
  -- enum
  feeling         mood,
  -- json
  doc_json        JSON,
  -- nested types
  int_list        INTEGER[],
  txt_list        TEXT[],
  nested_list     INTEGER[][],
  record          STRUCT(name VARCHAR, age INTEGER),
  kv_map          MAP(VARCHAR, INTEGER),
  flexible        UNION(num INTEGER, str VARCHAR, flag BOOLEAN),
  -- ip (stored as VARCHAR, DuckDB has no native INET)
  ip_addr         VARCHAR(45)
);

INSERT INTO type_zoo (
  id, flag, tiny_num, small_num, regular_num, big_num, huge_num,
  utiny_num, usmall_num, uregular_num, ubig_num,
  precise_num, approx_float, approx_double,
  day, tod, tod_tz, moment, moment_s, moment_ms, moment_ns, duration,
  guid, raw_bytes, bits, feeling, doc_json,
  int_list, txt_list, nested_list, record, kv_map, flexible, ip_addr
) VALUES
  -- row 1: typical values
  (1, TRUE, 127, 32767, 42, 9223372036854775807,
      170141183460469231731687303715884105727::HUGEINT,
   255, 65535, 4294967295, 18446744073709551615::UBIGINT,
   3.1416, 2.718, 1.7976931348623157e+308,
   '2025-01-15', '14:30:00', '14:30:00+05:30',
   '2025-01-15 14:30:00+00', '2025-01-15 14:30:00', '2025-01-15 14:30:00',
   '2025-01-15 14:30:00', INTERVAL '2 hours 30 minutes',
   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
   '\x48656c6c6f'::BLOB, '10101010'::BIT,
   'happy', '{"key": "value", "list": [1,2,3]}',
   [1, 2, 3], ['hello', 'world'], [[1,2],[3,4]],
   {'name': 'Alice', 'age': 30}, MAP {'a': 1, 'b': 2},
   1::UNION(num INTEGER, str VARCHAR, flag BOOLEAN),
   '192.168.1.1'),
  -- row 2: edge/boundary values
  (2, FALSE, -128, -32768, -1, 0,
      -170141183460469231731687303715884105727::HUGEINT,
   0, 0, 0, 0::UBIGINT,
   0.0001, -0.5, -1.0e-307,
   '1970-01-01', '00:00:00', '00:00:00+00',
   '1970-01-01 00:00:00+00', '1970-01-01 00:00:00', '1970-01-01 00:00:00',
   '1970-01-01 00:00:00', INTERVAL '0 seconds',
   '00000000-0000-0000-0000-000000000000',
   '\x00'::BLOB, '0'::BIT,
   'sad', '[]',
   [], [], [[]],
   {'name': '', 'age': 0}, MAP {},
   'empty'::UNION(num INTEGER, str VARCHAR, flag BOOLEAN),
   '::1'),
  -- row 3: all NULLs
  (3, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL,
   NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- ── long_values ──────────────────────────────────────────────────────────
-- Cells with 500+ char strings, multiline text, SQL injection attempts
CREATE TABLE long_values (
  id    INTEGER PRIMARY KEY,
  label VARCHAR(50),
  body  TEXT
);

INSERT INTO long_values (id, label, body) VALUES
  (1, 'long_string',
      REPEAT('abcdefghij', 60)),
  (2, 'multiline',
      E'Line one\nLine two\nLine three\n\nLine five after blank\n\tTabbed line'),
  (3, 'sql_injection',
      E'Robert''); DROP TABLE users;--'),
  (4, 'quotes_mix',
      E'He said "hello" and she said ''goodbye'' and then {json: "value"}'),
  (5, 'html_like',
      '<script>alert("xss")</script><b>bold</b>&amp;'),
  (6, 'newlines_only',
      E'\n\n\n');
