-- seed_mysql.sql — pathological test fixtures for dadbod-grip (MySQL/MariaDB).
-- Usage: mysql -u root -e "CREATE DATABASE IF NOT EXISTS grip_test"
--        mysql -u root grip_test < tests/seed_mysql.sql
--
-- Covers: CRUD, composite PKs, JSON, unicode, wide tables,
-- binary data, empty tables, type diversity, long values,
-- foreign keys, pagination-scale data, aggregation targets.

SET sql_mode = 'ANSI_QUOTES';

-- Clean slate (FK-aware drop order)
DROP TABLE IF EXISTS "order_items";
DROP TABLE IF EXISTS "orders";
DROP TABLE IF EXISTS "products";
DROP TABLE IF EXISTS "long_values";
DROP TABLE IF EXISTS "type_zoo";
DROP TABLE IF EXISTS "empty_table";
DROP TABLE IF EXISTS "binary_blobs";
DROP TABLE IF EXISTS "wide_table";
DROP TABLE IF EXISTS "unicode_fun";
DROP TABLE IF EXISTS "json_data";
DROP TABLE IF EXISTS "composite_pk";
DROP VIEW  IF EXISTS "no_pk_view";
DROP TABLE IF EXISTS "users";

-- ── users ────────────────────────────────────────────────────────────────
-- Normal CRUD: varchar, integer, timestamp, email. 15 rows for sort/filter.
CREATE TABLE "users" (
  "id"         INT AUTO_INCREMENT PRIMARY KEY,
  "name"       VARCHAR(100) NOT NULL,
  "email"      VARCHAR(255) UNIQUE,
  "age"        INT,
  "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO "users" ("name", "email", "age") VALUES
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
CREATE VIEW "no_pk_view" AS
  SELECT "name", "email", "age" FROM "users" WHERE "age" IS NOT NULL;

-- ── composite_pk ─────────────────────────────────────────────────────────
-- Composite primary key (two columns)
CREATE TABLE "composite_pk" (
  "tenant_id"  INT NOT NULL,
  "user_id"    INT NOT NULL,
  "role"       VARCHAR(50) DEFAULT 'member',
  "active"     TINYINT(1) DEFAULT 1,
  PRIMARY KEY ("tenant_id", "user_id")
);

INSERT INTO "composite_pk" ("tenant_id", "user_id", "role", "active") VALUES
  (1, 100, 'admin',  1),
  (1, 101, 'member', 1),
  (2, 100, 'viewer', 0),
  (2, 200, 'admin',  1);

-- ── products ─────────────────────────────────────────────────────────────
-- FK target for orders/order_items. 20 products across categories.
CREATE TABLE "products" (
  "id"       INT AUTO_INCREMENT PRIMARY KEY,
  "name"     VARCHAR(100) NOT NULL,
  "price"    DECIMAL(10,2) NOT NULL,
  "category" VARCHAR(50) NOT NULL
);

INSERT INTO "products" ("name", "price", "category") VALUES
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
CREATE TABLE "orders" (
  "id"         INT AUTO_INCREMENT PRIMARY KEY,
  "user_id"    INT NOT NULL,
  "total"      DECIMAL(10,2) NOT NULL,
  "status"     VARCHAR(20) NOT NULL DEFAULT 'pending',
  "ordered_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY ("user_id") REFERENCES "users"("id")
);

-- Generate 150 orders via recursive CTE
INSERT INTO "orders" ("user_id", "total", "status", "ordered_at")
WITH RECURSIVE seq(g) AS (
  SELECT 1 UNION ALL SELECT g + 1 FROM seq WHERE g < 150
)
SELECT
  ((g - 1) % 15) + 1 AS user_id,
  ROUND(5.0 + (g * 7.3) % 500, 2) AS total,
  CASE (g % 5)
    WHEN 0 THEN 'pending'
    WHEN 1 THEN 'shipped'
    WHEN 2 THEN 'delivered'
    WHEN 3 THEN 'cancelled'
    WHEN 4 THEN 'returned'
  END AS status,
  DATE_ADD('2025-01-01',
    INTERVAL ((g % 365) * 24 * 60 + (g * 37 % 24) * 60 + (g * 13 % 60)) MINUTE
  ) AS ordered_at
FROM seq;

-- ── order_items ──────────────────────────────────────────────────────────
-- FK to orders AND products. Multi-level FK navigation testing.
CREATE TABLE "order_items" (
  "id"          INT AUTO_INCREMENT PRIMARY KEY,
  "order_id"    INT NOT NULL,
  "product_id"  INT NOT NULL,
  "quantity"    INT NOT NULL DEFAULT 1,
  "unit_price"  DECIMAL(10,2) NOT NULL,
  FOREIGN KEY ("order_id") REFERENCES "orders"("id"),
  FOREIGN KEY ("product_id") REFERENCES "products"("id")
);

-- 1-3 items per order
INSERT INTO "order_items" ("order_id", "product_id", "quantity", "unit_price")
SELECT
  o."id" AS order_id,
  ((o."id" * 3 + item_num) % 20) + 1 AS product_id,
  (o."id" + item_num) % 5 + 1 AS quantity,
  p."price" AS unit_price
FROM "orders" o
CROSS JOIN (SELECT 0 AS item_num UNION ALL SELECT 1 UNION ALL SELECT 2) items
JOIN "products" p ON p."id" = ((o."id" * 3 + items.item_num) % 20) + 1
WHERE items.item_num < (o."id" % 3) + 1;

-- ── json_data ────────────────────────────────────────────────────────────
-- JSON columns with nested objects, arrays, nulls
CREATE TABLE "json_data" (
  "id"       INT AUTO_INCREMENT PRIMARY KEY,
  "metadata" JSON,
  "config"   JSON,
  "tags"     JSON
);

INSERT INTO "json_data" ("metadata", "config", "tags") VALUES
  ('{"key": "value", "nested": {"deep": true}}',
   '{"theme": "dark", "notifications": {"email": true, "sms": false}}',
   '["alpha", "beta", "gamma"]'),
  (NULL,
   '{"theme": "light"}',
   '[]'),
  ('{"empty_obj": {}}',
   '{"list": [1, 2, 3], "null_val": null}',
   '["single"]'),
  ('{"special": "quotes and stuff"}',
   '{}',
   NULL);

-- ── unicode_fun ──────────────────────────────────────────────────────────
-- Emoji, CJK characters, RTL text, diacritics in cell values
CREATE TABLE "unicode_fun" (
  "id"    INT AUTO_INCREMENT PRIMARY KEY,
  "label" VARCHAR(200),
  "value" TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

INSERT INTO "unicode_fun" ("label", "value") VALUES
  ('emoji',      '🎉🚀💾🔥✨ Party time!'),
  ('cjk',        '日本語テスト 中文测试 한국어'),
  ('rtl',        'مرحبا بالعالم'),
  ('diacritics', 'Ñoño café résumé naïve Zürich'),
  ('mixed',      'Hello 世界 🌍 مرحبا'),
  ('math',       '∑∏∫∂∇ε → ∞'),
  ('box_draw',   '┌──┬──┐ │  │  │ └──┴──┘');

-- ── wide_table ───────────────────────────────────────────────────────────
-- 15+ columns to test horizontal scrolling/truncation
CREATE TABLE "wide_table" (
  "id"    INT AUTO_INCREMENT PRIMARY KEY,
  "col_a" VARCHAR(30),
  "col_b" VARCHAR(30),
  "col_c" VARCHAR(30),
  "col_d" VARCHAR(30),
  "col_e" VARCHAR(30),
  "col_f" VARCHAR(30),
  "col_g" VARCHAR(30),
  "col_h" VARCHAR(30),
  "col_i" VARCHAR(30),
  "col_j" VARCHAR(30),
  "col_k" VARCHAR(30),
  "col_l" VARCHAR(30),
  "col_m" VARCHAR(30),
  "col_n" VARCHAR(30),
  "col_o" VARCHAR(30)
);

INSERT INTO "wide_table" ("col_a", "col_b", "col_c", "col_d", "col_e", "col_f", "col_g", "col_h",
                          "col_i", "col_j", "col_k", "col_l", "col_m", "col_n", "col_o") VALUES
  ('alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', 'golf', 'hotel',
   'india', 'juliet', 'kilo', 'lima', 'mike', 'november', 'oscar'),
  ('papa', 'quebec', 'romeo', 'sierra', 'tango', 'uniform', 'victor', 'whiskey',
   'xray', 'yankee', 'zulu', NULL, NULL, NULL, NULL);

-- ── binary_blobs ─────────────────────────────────────────────────────────
-- BLOB column with binary data
CREATE TABLE "binary_blobs" (
  "id"   INT AUTO_INCREMENT PRIMARY KEY,
  "name" VARCHAR(50),
  "data" BLOB
);

INSERT INTO "binary_blobs" ("name", "data") VALUES
  ('tiny',    X'48656c6c6f'),
  ('zeros',   X'0000000000'),
  ('png_hdr', X'89504e470d0a1a0a');

-- ── empty_table ──────────────────────────────────────────────────────────
-- Zero rows (tests empty state rendering)
CREATE TABLE "empty_table" (
  "id"    INT AUTO_INCREMENT PRIMARY KEY,
  "value" TEXT
);

-- ── type_zoo ─────────────────────────────────────────────────────────────
-- boolean, integer, bigint, decimal, float, date, time, timestamp,
-- interval (varchar), uuid (char), json (arrays), enum
CREATE TABLE "type_zoo" (
  "id"           INT AUTO_INCREMENT PRIMARY KEY,
  "flag"         TINYINT(1),
  "small_num"    INT,
  "big_num"      BIGINT,
  "precise_num"  DECIMAL(10,4),
  "approx_num"   FLOAT,
  "day"          DATE,
  "tod"          TIME,
  "moment"       TIMESTAMP NULL,
  "duration"     VARCHAR(100),
  "guid"         CHAR(36),
  "ip_addr"      VARCHAR(45),
  "int_list"     JSON,
  "txt_list"     JSON,
  "feeling"      ENUM('happy', 'sad', 'neutral')
);

INSERT INTO "type_zoo" ("flag", "small_num", "big_num", "precise_num", "approx_num",
                        "day", "tod", "moment", "duration", "guid", "ip_addr",
                        "int_list", "txt_list", "feeling") VALUES
  (1,    42,     9223372036854775807, 3.1416, 2.718,
   '2025-01-15', '14:30:00', '2025-01-15 14:30:00', '2 hours 30 minutes',
   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '192.168.1.1',
   '[1, 2, 3]', '["hello", "world"]', 'happy'),
  (0,    -1,     0,                   0.0001, -0.5,
   '1970-01-01', '00:00:00', '1970-01-01 00:00:00', '0 seconds',
   '00000000-0000-0000-0000-000000000000', '::1',
   '[]', '[]', 'sad'),
  (NULL, NULL,   NULL,                NULL,   NULL,
   NULL,         NULL,       NULL,            NULL,
   NULL,                                      NULL,
   NULL, NULL, NULL);

-- ── long_values ──────────────────────────────────────────────────────────
-- Cells with 500+ char strings, multiline text, SQL injection attempts
CREATE TABLE "long_values" (
  "id"    INT AUTO_INCREMENT PRIMARY KEY,
  "label" VARCHAR(50),
  "body"  TEXT
);

INSERT INTO "long_values" ("label", "body") VALUES
  ('long_string',
   REPEAT('abcdefghij', 60)),
  ('multiline',
   'Line one\nLine two\nLine three\n\nLine five after blank\n\tTabbed line'),
  ('sql_injection',
   'Robert''); DROP TABLE users;--'),
  ('quotes_mix',
   'He said "hello" and she said ''goodbye'' and then {json: "value"}'),
  ('html_like',
   '<script>alert("xss")</script><b>bold</b>&amp;'),
  ('newlines_only',
   '\n\n\n');
