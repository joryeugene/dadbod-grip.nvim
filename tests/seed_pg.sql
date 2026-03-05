-- seed_pg.sql: pathological test fixtures for dadbod-grip (PostgreSQL).
-- Usage: createdb grip_test && psql grip_test < tests/seed_pg.sql
--
-- Covers: CRUD, composite PKs, JSON, unicode, wide tables,
-- binary data, empty tables, type diversity, long values,
-- foreign keys, pagination-scale data, aggregation targets.

BEGIN;

-- Clean slate (FK-aware drop order)
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS long_values CASCADE;
DROP TABLE IF EXISTS type_zoo CASCADE;
DROP TABLE IF EXISTS empty_table CASCADE;
DROP TABLE IF EXISTS binary_blobs CASCADE;
DROP TABLE IF EXISTS wide_table CASCADE;
DROP TABLE IF EXISTS unicode_fun CASCADE;
DROP TABLE IF EXISTS json_data CASCADE;
DROP TABLE IF EXISTS composite_pk CASCADE;
DROP VIEW  IF EXISTS no_pk_view CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TYPE  IF EXISTS mood CASCADE;

-- ── users ────────────────────────────────────────────────────────────────
-- Normal CRUD: varchar, integer, timestamp, email. 15 rows for sort/filter.
CREATE TABLE users (
  id         SERIAL PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(255) UNIQUE,
  age        INTEGER,
  created_at TIMESTAMP DEFAULT NOW()
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
  id       SERIAL PRIMARY KEY,
  name     VARCHAR(100) NOT NULL,
  price    NUMERIC(10,2) NOT NULL,
  category VARCHAR(50) NOT NULL
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
CREATE TABLE orders (
  id         SERIAL PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users(id),
  total      NUMERIC(10,2) NOT NULL,
  status     VARCHAR(20) NOT NULL DEFAULT 'pending',
  ordered_at TIMESTAMP DEFAULT NOW()
);

-- Generate 150 orders across 15 users, varied totals and statuses
INSERT INTO orders (user_id, total, status, ordered_at)
SELECT
  ((g - 1) % 15) + 1 AS user_id,
  ROUND((5.0 + (g * 7.3) % 500)::numeric, 2) AS total,
  CASE (g % 5)
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'shipped'
    WHEN 2 THEN 'delivered'
    WHEN 3 THEN 'cancelled'
    WHEN 4 THEN 'returned'
  END AS status,
  '2025-01-01'::timestamp + (g % 365) * interval '1 day'
    + (g * 37 % 24) * interval '1 hour'
    + (g * 13 % 60) * interval '1 minute' AS ordered_at
FROM generate_series(1, 150) AS g;

-- ── order_items ──────────────────────────────────────────────────────────
-- FK to orders AND products. Multi-level FK navigation testing.
CREATE TABLE order_items (
  id          SERIAL PRIMARY KEY,
  order_id    INTEGER NOT NULL REFERENCES orders(id),
  product_id  INTEGER NOT NULL REFERENCES products(id),
  quantity    INTEGER NOT NULL DEFAULT 1,
  unit_price  NUMERIC(10,2) NOT NULL
);

-- 1-3 items per order
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT
  o.id AS order_id,
  ((o.id * 3 + item_num) % 20) + 1 AS product_id,
  (o.id + item_num) % 5 + 1 AS quantity,
  p.price AS unit_price
FROM orders o
CROSS JOIN (VALUES (0), (1), (2)) AS items(item_num)
JOIN products p ON p.id = ((o.id * 3 + items.item_num) % 20) + 1
WHERE items.item_num < (o.id % 3) + 1;

-- ── json_data ────────────────────────────────────────────────────────────
-- json and jsonb columns with nested objects, arrays, nulls
CREATE TABLE json_data (
  id       SERIAL PRIMARY KEY,
  metadata JSON,
  config   JSONB,
  tags     JSONB
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
  id    SERIAL PRIMARY KEY,
  label VARCHAR(200),
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
  id     SERIAL PRIMARY KEY,
  col_a  VARCHAR(30),
  col_b  VARCHAR(30),
  col_c  VARCHAR(30),
  col_d  VARCHAR(30),
  col_e  VARCHAR(30),
  col_f  VARCHAR(30),
  col_g  VARCHAR(30),
  col_h  VARCHAR(30),
  col_i  VARCHAR(30),
  col_j  VARCHAR(30),
  col_k  VARCHAR(30),
  col_l  VARCHAR(30),
  col_m  VARCHAR(30),
  col_n  VARCHAR(30),
  col_o  VARCHAR(30)
);

INSERT INTO wide_table (col_a, col_b, col_c, col_d, col_e, col_f, col_g, col_h,
                        col_i, col_j, col_k, col_l, col_m, col_n, col_o) VALUES
  ('alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel',
   'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar'),
  ('papa', 'quebec', 'romeo', 'sierra', 'tango', 'uniform', 'victor', 'whiskey',
   'xray', 'yankee', 'zulu', NULL, NULL, NULL, NULL);

-- ── binary_blobs ─────────────────────────────────────────────────────────
-- bytea column with binary data
CREATE TABLE binary_blobs (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(50),
  data BYTEA
);

INSERT INTO binary_blobs (name, data) VALUES
  ('tiny',    '\x48656c6c6f'),
  ('zeros',   '\x0000000000'),
  ('png_hdr', '\x89504e470d0a1a0a');

-- ── empty_table ──────────────────────────────────────────────────────────
-- Zero rows (tests empty state rendering)
CREATE TABLE empty_table (
  id    SERIAL PRIMARY KEY,
  value TEXT
);

-- ── type_zoo ─────────────────────────────────────────────────────────────
-- PostgreSQL-specific: boolean, integer, bigint, numeric, real, double,
-- smallint, date, time, timetz, timestamptz, interval, uuid, inet, cidr,
-- macaddr, array, enum, json, jsonb, bytea, bit, varbit, money, xml,
-- tsvector, tsquery, int4range, tstzrange, point, line, box, citext
CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral');

CREATE TABLE type_zoo (
  id            SERIAL PRIMARY KEY,
  -- booleans and integers
  flag          BOOLEAN,
  tiny_num      SMALLINT,
  small_num     INTEGER,
  big_num       BIGINT,
  -- decimals
  precise_num   NUMERIC(10,4),
  approx_num    REAL,
  double_num    DOUBLE PRECISION,
  money_val     MONEY,
  -- date/time
  day           DATE,
  tod           TIME,
  tod_tz        TIMETZ,
  moment        TIMESTAMPTZ,
  duration      INTERVAL,
  -- identifiers
  guid          UUID,
  -- network
  ip_addr       INET,
  network       CIDR,
  mac           MACADDR,
  -- arrays
  int_list      INTEGER[],
  txt_list      TEXT[],
  -- enum
  feeling       mood,
  -- json
  doc_json      JSON,
  doc_jsonb     JSONB,
  -- binary
  raw_bytes     BYTEA,
  -- bit strings
  bits_fixed    BIT(8),
  bits_var      VARBIT(16),
  -- full-text search
  tsv           TSVECTOR,
  tsq           TSQUERY,
  -- range
  int_range     INT4RANGE,
  ts_range      TSTZRANGE,
  -- geometric
  pt            POINT,
  ln            LINE,
  bx            BOX,
  -- xml
  markup        XML
);

INSERT INTO type_zoo (
  flag, tiny_num, small_num, big_num, precise_num, approx_num, double_num, money_val,
  day, tod, tod_tz, moment, duration, guid,
  ip_addr, network, mac, int_list, txt_list, feeling,
  doc_json, doc_jsonb, raw_bytes, bits_fixed, bits_var,
  tsv, tsq, int_range, ts_range, pt, ln, bx, markup
) VALUES
  -- row 1: typical values
  (TRUE, 127, 42, 9223372036854775807, 3.1416, 2.718, 1.7976931e+308, '$19.99',
   '2025-01-15', '14:30:00', '14:30:00+05:30', '2025-01-15 14:30:00+00',
   '2 hours 30 minutes',
   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
   '192.168.1.1', '10.0.0.0/8', '08:00:2b:01:02:03',
   '{1, 2, 3}', '{"hello", "world"}', 'happy',
   '{"key": "value"}', '{"nested": {"deep": true}}',
   '\x48656c6c6f', B'10101010', B'110011',
   'fat:1 cat:2 sat:3'::tsvector, 'fat & cat'::tsquery,
   '[1,10)', '[2025-01-01 00:00:00+00, 2025-12-31 23:59:59+00]',
   '(1.5, 2.5)', '{1, -1, 0}', '(0,0),(1,1)',
   '<root><item id="1">hello</item></root>'),
  -- row 2: edge/boundary values
  (FALSE, -128, -1, 0, 0.0001, -0.5, -1.0e-307, '$0.00',
   '1970-01-01', '00:00:00', '00:00:00+00', '1970-01-01 00:00:00+00',
   '0 seconds',
   '00000000-0000-0000-0000-000000000000',
   '::1', '::1/128', '00:00:00:00:00:00',
   '{}', '{}', 'sad',
   '{}', '[]',
   '\x00', B'00000000', B'0',
   ''::tsvector, 'a | b'::tsquery,
   'empty', 'empty',
   '(0, 0)', '{0, 1, 0}', '(0,0),(0,0)',
   '<empty/>'),
  -- row 3: all NULLs
  (NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

-- ── long_values ──────────────────────────────────────────────────────────
-- Cells with 500+ char strings, multiline text, SQL injection attempts
CREATE TABLE long_values (
  id    SERIAL PRIMARY KEY,
  label VARCHAR(50),
  body  TEXT
);

INSERT INTO long_values (label, body) VALUES
  ('long_string',
   repeat('abcdefghij', 60)),
  ('multiline',
   E'Line one\nLine two\nLine three\n\nLine five after blank\n\tTabbed line'),
  ('sql_injection',
   E'Robert''); DROP TABLE users;--'),
  ('quotes_mix',
   E'He said "hello" and she said ''goodbye'' and then {json: "value"}'),
  ('html_like',
   '<script>alert("xss")</script><b>bold</b>&amp;'),
  ('newlines_only',
   E'\n\n\n');

COMMIT;
