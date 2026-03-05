-- softrear_supplier.sql: Leaked supplier logistics database (SQLite)
-- Seeded by :GripStart alongside the main Softrear database.
-- Attach with: :GripAttach sqlite:.grip/supplier_intel.db  supplier

CREATE TABLE shipments (
  id INTEGER PRIMARY KEY,
  supplier_alias TEXT NOT NULL,
  destination_facility TEXT NOT NULL,
  ship_date TEXT NOT NULL,
  declared_contents TEXT NOT NULL,
  actual_contents TEXT NOT NULL,
  weight_kg REAL NOT NULL,
  customs_flag TEXT
);

CREATE TABLE ingredient_tests (
  id INTEGER PRIMARY KEY,
  batch_ref TEXT NOT NULL,
  test_date TEXT NOT NULL,
  bamboo_grade TEXT NOT NULL,
  contaminant_level REAL NOT NULL,
  passed INTEGER NOT NULL DEFAULT 0,
  tester_notes TEXT
);

CREATE TABLE pricing (
  id INTEGER PRIMARY KEY,
  supplier_alias TEXT NOT NULL,
  territory TEXT NOT NULL,
  price_per_ton REAL NOT NULL,
  discount_pct REAL NOT NULL DEFAULT 0,
  loyalty_tier TEXT,
  notes TEXT
);

-- Shipments: Bamboo Don supplies Shanghai with relabeled material
INSERT INTO shipments VALUES
  (1, 'Bamboo Don', 'Shanghai Liaison Office', '2024-01-15', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 4200.0, NULL),
  (2, 'Bamboo Don', 'Shanghai Liaison Office', '2024-02-03', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 3800.0, NULL),
  (3, 'Bamboo Don', 'Shanghai Liaison Office', '2024-02-28', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 4500.0, 'diverted_from_inspection'),
  (4, 'Bamboo Don', 'Shanghai Liaison Office', '2024-03-14', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 3950.0, NULL),
  (5, 'Bamboo Don', 'Shanghai Liaison Office', '2024-04-02', 'Grade A Bamboo Fiber', 'Grade B Recovered Fiber', 4100.0, NULL),
  (6, 'Bamboo Don', 'Shanghai Liaison Office', '2024-04-19', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 4300.0, 'diverted_from_inspection'),
  (7, 'Bamboo Don', 'Shanghai Liaison Office', '2024-05-07', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 3700.0, NULL),
  (8, 'Bamboo Don', 'Sao Paulo Processing', '2024-03-01', 'Grade A Bamboo Fiber', 'Grade A Bamboo Fiber', 5000.0, NULL),
  (9, 'Bamboo Don', 'Munich Distribution', '2024-03-15', 'Grade A Bamboo Fiber', 'Grade A Bamboo Fiber', 4800.0, NULL),
  (10, 'Bamboo Don', 'Mumbai Warehouse', '2024-04-10', 'Grade A Bamboo Fiber', 'Grade A Bamboo Fiber', 5200.0, NULL),
  (11, 'Green Fiber Co', 'Shanghai Liaison Office', '2024-01-20', 'Grade A Bamboo Fiber', 'Grade A Bamboo Fiber', 3600.0, NULL),
  (12, 'Green Fiber Co', 'Sao Paulo Processing', '2024-02-14', 'Grade A Bamboo Fiber', 'Grade A Bamboo Fiber', 4100.0, NULL),
  (13, 'Panda Textiles', 'Munich Distribution', '2024-03-22', 'Grade B+ Premium Blend', 'Grade B+ Premium Blend', 2800.0, NULL),
  (14, 'Bamboo Don', 'Shanghai Liaison Office', '2024-05-22', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 4050.0, 'cleared_without_sample'),
  (15, 'Bamboo Don', 'Shanghai Liaison Office', '2024-06-10', 'Grade A Bamboo Fiber', 'Grade C Mixed Pulp', 4400.0, NULL);

-- Ingredient tests: failed tests on the batches that became ULTRA_BUDGET_XTRM
INSERT INTO ingredient_tests VALUES
  (1, 'BD-2024-0115', '2024-01-16', 'C', 8.7, 0, 'Sample relabeled before customs. Original grade: C.'),
  (2, 'BD-2024-0203', '2024-02-04', 'C', 6.2, 0, 'Contaminant detected. Supplier notified. No response.'),
  (3, 'BD-2024-0228', '2024-03-01', 'C', 7.4, 0, 'Failed purity threshold. Customs diversion noted on manifest.'),
  (4, 'BD-2024-0314', '2024-03-15', 'B-', 3.1, 1, 'Marginal pass. Below spec but within tolerance.'),
  (5, 'BD-2024-0402', '2024-04-03', 'B', 2.8, 1, 'Clean batch. Grade B recovered fiber, acceptable.'),
  (6, 'BD-2024-0419', '2024-04-20', 'C', 7.9, 0, 'High contaminant. Flagged for disposal. Shipped anyway.'),
  (7, 'BD-2024-0507', '2024-05-08', 'C', 5.5, 0, 'Below minimum standard. Relabeled as Grade A on export docs.'),
  (8, 'GF-2024-0120', '2024-01-21', 'A', 0.3, 1, 'Clean. Green Fiber batch meets all specs.'),
  (9, 'GF-2024-0214', '2024-02-15', 'A', 0.5, 1, 'Clean. Standard quality.'),
  (10, 'PT-2024-0322', '2024-03-23', 'B+', 1.2, 1, 'Panda Textiles premium blend. Within spec.');

-- Pricing: Shanghai gets a founding partner discount nobody else gets
INSERT INTO pricing VALUES
  (1, 'Bamboo Don', 'Shanghai', 1200.00, 40.0, 'founding_partner', 'Original supply agreement. Not subject to renegotiation.'),
  (2, 'Bamboo Don', 'Sao Paulo', 2000.00, 0.0, 'standard', NULL),
  (3, 'Bamboo Don', 'Munich', 2000.00, 0.0, 'standard', NULL),
  (4, 'Bamboo Don', 'Mumbai', 2000.00, 5.0, 'volume', 'Volume discount for bulk orders only.'),
  (5, 'Green Fiber Co', 'Shanghai', 1900.00, 10.0, 'preferred', 'Competitive pricing. Quality consistently Grade A.'),
  (6, 'Green Fiber Co', 'Sao Paulo', 1850.00, 10.0, 'preferred', NULL),
  (7, 'Panda Textiles', 'Munich', 2200.00, 0.0, 'standard', 'Premium blend supplier. Higher base price.');
