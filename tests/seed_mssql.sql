-- seed_mssql.sql: core SQL Server fixtures for dadbod-grip.
-- Usage:
--   SQLCMDPASSWORD='<password>' sqlcmd -S localhost,1433 -U sa -Q "CREATE DATABASE grip_test"
--   SQLCMDPASSWORD='<password>' sqlcmd -S localhost,1433 -U sa -d grip_test -i tests/seed_mssql.sql
--
-- Covers read-only adapter smoke tests: tables, views, composite PKs,
-- foreign keys, unicode, empty result sets, pagination-scale rows.

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID('dbo.order_items', 'U') IS NOT NULL DROP TABLE dbo.order_items;
IF OBJECT_ID('dbo.orders', 'U') IS NOT NULL DROP TABLE dbo.orders;
IF OBJECT_ID('dbo.products', 'U') IS NOT NULL DROP TABLE dbo.products;
IF OBJECT_ID('dbo.long_values', 'U') IS NOT NULL DROP TABLE dbo.long_values;
IF OBJECT_ID('dbo.empty_table', 'U') IS NOT NULL DROP TABLE dbo.empty_table;
IF OBJECT_ID('dbo.unicode_fun', 'U') IS NOT NULL DROP TABLE dbo.unicode_fun;
IF OBJECT_ID('dbo.composite_pk', 'U') IS NOT NULL DROP TABLE dbo.composite_pk;
IF OBJECT_ID('dbo.no_pk_view', 'V') IS NOT NULL DROP VIEW dbo.no_pk_view;
IF OBJECT_ID('dbo.users', 'U') IS NOT NULL DROP TABLE dbo.users;

CREATE TABLE dbo.users (
  id int IDENTITY(1,1) PRIMARY KEY,
  name nvarchar(100) NOT NULL,
  email nvarchar(255) NULL,
  age int NULL,
  created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);

-- Unlike PG/MySQL, a plain UNIQUE constraint here allows only ONE NULL;
-- the fixture has two NULL emails, so uniqueness must be filtered.
CREATE UNIQUE INDEX ux_users_email ON dbo.users(email) WHERE email IS NOT NULL;

INSERT INTO dbo.users (name, email, age) VALUES
  (N'Alice',   N'alice@example.com',   30),
  (N'Bob',     N'bob@example.com',     25),
  (N'Charlie', N'charlie@example.com', NULL),
  (N'Diana',   NULL,                   42),
  (N'Eve',     N'eve@example.com',     19),
  (N'Frank',   N'frank@example.com',   35),
  (N'Grace',   N'grace@example.com',   28),
  (N'Hank',    N'hank@example.com',    51),
  (N'Ivy',     N'ivy@example.com',     22),
  (N'Jack',    N'jack@example.com',    NULL),
  (N'Karen',   N'karen@example.com',   38),
  (N'Leo',     N'leo@example.com',     45),
  (N'Mona',    N'mona@example.com',    31),
  (N'Nate',    NULL,                   27),
  (N'Olivia',  N'olivia@example.com',  33);
GO

-- CREATE VIEW must be the only statement in its batch.
CREATE VIEW dbo.no_pk_view AS
  SELECT name, email, age FROM dbo.users WHERE age IS NOT NULL;
GO

CREATE TABLE dbo.composite_pk (
  tenant_id int NOT NULL,
  user_id int NOT NULL,
  role nvarchar(50) NOT NULL DEFAULT N'member',
  active bit NOT NULL DEFAULT 1,
  CONSTRAINT pk_composite_pk PRIMARY KEY (tenant_id, user_id)
);

INSERT INTO dbo.composite_pk (tenant_id, user_id, role, active) VALUES
  (1, 100, N'admin', 1),
  (1, 101, N'member', 1),
  (2, 100, N'viewer', 0),
  (2, 200, N'admin', 1);

CREATE TABLE dbo.products (
  id int IDENTITY(1,1) PRIMARY KEY,
  name nvarchar(100) NOT NULL,
  price decimal(10,2) NOT NULL,
  category nvarchar(50) NOT NULL
);

INSERT INTO dbo.products (name, price, category) VALUES
  (N'Widget A', 9.99, N'widgets'),
  (N'Widget B', 14.99, N'widgets'),
  (N'Widget C', 24.99, N'widgets'),
  (N'Gadget X', 49.99, N'gadgets'),
  (N'Gadget Y', 79.99, N'gadgets'),
  (N'Gadget Z', 149.99, N'gadgets'),
  (N'Doohickey 1', 4.99, N'accessories'),
  (N'Doohickey 2', 7.99, N'accessories'),
  (N'Doohickey 3', 12.99, N'accessories'),
  (N'Thingamajig', 29.99, N'misc'),
  (N'Whatchamacallit', 19.99, N'misc'),
  (N'Gizmo Alpha', 99.99, N'gizmos'),
  (N'Gizmo Beta', 199.99, N'gizmos'),
  (N'Gizmo Gamma', 299.99, N'gizmos'),
  (N'Part 001', 2.49, N'parts'),
  (N'Part 002', 3.49, N'parts'),
  (N'Part 003', 1.99, N'parts'),
  (N'Part 004', 5.99, N'parts'),
  (N'Premium Kit', 499.99, N'kits'),
  (N'Starter Kit', 59.99, N'kits');

CREATE TABLE dbo.orders (
  id int IDENTITY(1,1) PRIMARY KEY,
  user_id int NOT NULL,
  total decimal(10,2) NOT NULL,
  status nvarchar(20) NOT NULL DEFAULT N'pending',
  ordered_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT fk_orders_users FOREIGN KEY (user_id) REFERENCES dbo.users(id),
  CONSTRAINT ck_orders_status CHECK (status IN (N'pending', N'shipped', N'delivered', N'cancelled', N'returned'))
);

WITH seq(g) AS (
  SELECT 1
  UNION ALL
  SELECT g + 1 FROM seq WHERE g < 150
)
INSERT INTO dbo.orders (user_id, total, status, ordered_at)
SELECT
  ((g - 1) % 15) + 1,
  CAST(5.0 + ((g * 73) % 5000) / 10.0 AS decimal(10,2)),
  CASE (g % 5)
    WHEN 0 THEN N'pending'
    WHEN 1 THEN N'shipped'
    WHEN 2 THEN N'delivered'
    WHEN 3 THEN N'cancelled'
    ELSE N'returned'
  END,
  DATEADD(minute, (g * 37) % 1440, DATEADD(day, g % 365, CAST('2025-01-01' AS datetime2)))
FROM seq
OPTION (MAXRECURSION 200);

CREATE TABLE dbo.order_items (
  id int IDENTITY(1,1) PRIMARY KEY,
  order_id int NOT NULL,
  product_id int NOT NULL,
  quantity int NOT NULL DEFAULT 1,
  unit_price decimal(10,2) NOT NULL,
  CONSTRAINT fk_order_items_orders FOREIGN KEY (order_id) REFERENCES dbo.orders(id),
  CONSTRAINT fk_order_items_products FOREIGN KEY (product_id) REFERENCES dbo.products(id)
);

INSERT INTO dbo.order_items (order_id, product_id, quantity, unit_price)
SELECT
  o.id,
  ((o.id * 3 + items.item_num) % 20) + 1,
  (o.id + items.item_num) % 5 + 1,
  p.price
FROM dbo.orders o
CROSS JOIN (VALUES (0), (1), (2)) AS items(item_num)
JOIN dbo.products p ON p.id = ((o.id * 3 + items.item_num) % 20) + 1
WHERE items.item_num < (o.id % 3) + 1;

CREATE TABLE dbo.unicode_fun (
  id int IDENTITY(1,1) PRIMARY KEY,
  label nvarchar(200),
  value nvarchar(max)
);

INSERT INTO dbo.unicode_fun (label, value) VALUES
  (N'emoji', N'🎉🚀💾🔥✨ Party time!'),
  (N'cjk', N'日本語テスト 中文测试 한국어'),
  (N'rtl', N'مرحبا بالعالم'),
  (N'diacritics', N'Ñoño café résumé naïve Zürich'),
  (N'mixed', N'Hello 世界 🌍 مرحبا'),
  (N'math', N'∑∏∫∂∇ε → ∞'),
  (N'box_draw', N'┌──┬──┐ │  │  │ └──┴──┘');

CREATE TABLE dbo.empty_table (
  id int IDENTITY(1,1) PRIMARY KEY,
  value nvarchar(max)
);

CREATE TABLE dbo.long_values (
  id int IDENTITY(1,1) PRIMARY KEY,
  label nvarchar(50),
  body nvarchar(max)
);

INSERT INTO dbo.long_values (label, body) VALUES
  (N'long_string', REPLICATE(N'abcdefghij', 60)),
  (N'multiline', N'Line one
Line two
Line three'),
  (N'quotes_mix', N'He said "hello" and she said ''goodbye''');
