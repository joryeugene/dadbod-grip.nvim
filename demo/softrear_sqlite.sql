-- ============================================================
-- SOFTREAR INC. TISSUE INTELLIGENCE PLATFORM™
-- Internal Operations Database: SQLite Edition
-- CLASSIFICATION: PROPRIETARY: DO NOT DISTRIBUTE
-- (If you are reading this, your IP has been logged.)
-- ============================================================
--
-- Setup (SQLite):
--   sqlite3 ~/.local/share/nvim/grip/softrear.db < demo/softrear_sqlite.sql
--
-- Or via plugin:
--   :GripStart
-- ============================================================
--
-- NOTE: This is the SQLite-compatible version. It contains only
-- the hand-written named rows: the key data that carries the
-- narrative. Filler rows (generated via DuckDB range()) are omitted.
-- For the full 500+ row dataset, use demo/softrear.sql with DuckDB.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- SCHEMA
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS bamboo_cartel_members (
  id                       INTEGER PRIMARY KEY,
  alias                    TEXT    NOT NULL,
  territory                TEXT    NOT NULL,
  softness_tier_controlled TEXT,
  our_relationship         TEXT    NOT NULL
    CHECK (our_relationship IN ('friendly', 'tense', 'embargo'))
);

CREATE TABLE IF NOT EXISTS facilities (
  id                 INTEGER PRIMARY KEY,
  name               TEXT    NOT NULL,
  city               TEXT,
  country            TEXT    NOT NULL,
  workers            INTEGER,
  vibe_score         REAL,
  bamboo_supplier_id INTEGER REFERENCES bamboo_cartel_members(id)
);

CREATE TABLE IF NOT EXISTS production_batches (
  id             INTEGER PRIMARY KEY,
  facility_id    INTEGER NOT NULL REFERENCES facilities(id),
  batch_date     TEXT,
  quality_score  REAL,
  recall         INTEGER DEFAULT 0,
  incident_count INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS rolls (
  sku              TEXT    PRIMARY KEY,
  ply              INTEGER NOT NULL DEFAULT 2,
  softness_score   REAL,
  tensile_strength REAL,
  sheets_per_roll  INTEGER,
  msrp             REAL,
  discontinued     INTEGER DEFAULT 0,
  batch_id         INTEGER REFERENCES production_batches(id)
);

CREATE TABLE IF NOT EXISTS consumer_incidents (
  id            INTEGER PRIMARY KEY,
  roll_sku      TEXT    REFERENCES rolls(sku),
  incident_type TEXT    NOT NULL
    CHECK (incident_type IN (
      'clog', 'emergency_situation', 'mid_meeting', 'airplane',
      'camping_regret', 'wedding', 'first_date', 'standard_dissatisfaction'
    )),
  severity      INTEGER NOT NULL CHECK (severity BETWEEN 1 AND 10),
  resolved      INTEGER DEFAULT 0,
  incident_date TEXT,
  notes         TEXT
);

CREATE TABLE IF NOT EXISTS taste_test_sessions (
  id                   INTEGER PRIMARY KEY,
  facility_id          INTEGER REFERENCES facilities(id),
  session_date         TEXT,
  samples_tested       INTEGER,
  unanimous_winner_sku TEXT    REFERENCES rolls(sku),
  suspicious_results   INTEGER DEFAULT 0,
  sample_refusal_count INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS internal_investigations (
  id             INTEGER PRIMARY KEY,
  subject_alias  TEXT,
  investigator   TEXT,
  opened_date    TEXT,
  status         TEXT NOT NULL
    CHECK (status IN ('watching', 'active', 'resolved', 'they_got_us')),
  finding        TEXT
);

CREATE TABLE IF NOT EXISTS people_on_to_us (
  id                INTEGER PRIMARY KEY,
  name              TEXT,
  platform          TEXT,
  evidence_strength INTEGER CHECK (evidence_strength BETWEEN 1 AND 10),
  what_they_know    TEXT,
  our_response      TEXT
    CHECK (our_response IN ('ignored', 'coupon_sent', 'legal_letter', 'acquired')),
  investigation_id  INTEGER REFERENCES internal_investigations(id)
);

CREATE TABLE IF NOT EXISTS suspicious_persons (
  id               INTEGER PRIMARY KEY,
  alias            TEXT,
  platform         TEXT,
  follower_count   INTEGER,
  knows_too_much   INTEGER DEFAULT 0,
  investigation_id INTEGER REFERENCES internal_investigations(id)
);

CREATE TABLE IF NOT EXISTS youtube_comments (
  id                  INTEGER PRIMARY KEY,
  channel_name        TEXT,
  commenter_id        INTEGER REFERENCES suspicious_persons(id),
  comment_text        TEXT,
  sentiment_score     REAL,
  conspiracy_adjacent INTEGER,  -- NULL = unreviewed by Threat Assessment team
  posted_date         TEXT
);

CREATE TABLE IF NOT EXISTS reddit_threads (
  id                 INTEGER PRIMARY KEY,
  subreddit          TEXT,
  title              TEXT,
  upvotes            INTEGER,
  threat_level       INTEGER CHECK (threat_level BETWEEN 1 AND 5),
  mentions_softrear  INTEGER DEFAULT 1,
  our_awareness_date TEXT
);

CREATE TABLE IF NOT EXISTS celebrity_endorsements (
  id                   INTEGER PRIMARY KEY,
  celebrity_name       TEXT,
  fee_paid             REAL,
  campaign_start       TEXT,
  campaign_end         TEXT,
  awkward_incident     INTEGER DEFAULT 0,
  incident_description TEXT,
  still_under_contract INTEGER DEFAULT 0,
  went_rogue           INTEGER DEFAULT 0,
  roi                  REAL
);

CREATE TABLE IF NOT EXISTS executive_decisions (
  id             INTEGER PRIMARY KEY,
  decision_text  TEXT,
  made_by        TEXT,
  decision_date  TEXT,
  rationale      TEXT
    CHECK (rationale IN ('gut_feeling', 'dream', 'astrology', 'actual_data')),
  outcome        TEXT
    CHECK (outcome IN ('fine', 'recall', 'lawsuit', 'legendary'))
);

CREATE TABLE IF NOT EXISTS supply_chain_events (
  id                INTEGER PRIMARY KEY,
  event_type        TEXT
    CHECK (event_type IN (
      'shortage', 'panic_buying', 'bamboo_controversy',
      'mysterious_quality_drop', 'cartel_shakeup'
    )),
  impact_score      INTEGER CHECK (impact_score BETWEEN 1 AND 10),
  event_date        TEXT,
  description       TEXT,
  related_member_id INTEGER REFERENCES bamboo_cartel_members(id)
);

CREATE TABLE IF NOT EXISTS leadership_directives (
  id                    INTEGER PRIMARY KEY,
  directive             TEXT    NOT NULL,
  issued_by             TEXT    DEFAULT 'Legal',
  effective_date        TEXT,
  publicly_acknowledged INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS warranty_claims (
  id                INTEGER PRIMARY KEY,
  roll_sku          TEXT REFERENCES rolls(sku),
  claim_type        TEXT CHECK (claim_type IN (
                      'disintegration', 'structural_failure',
                      'mystery_stiffness', 'unexpected_adhesion', 'other')),
  settlement_amount REAL,
  nda_signed        INTEGER DEFAULT 0,
  notes             TEXT
);

CREATE TABLE IF NOT EXISTS quality_certifications (
  id                         INTEGER PRIMARY KEY,
  roll_sku                   TEXT REFERENCES rolls(sku),
  certified_by               TEXT NOT NULL,
  score                      INTEGER CHECK (score BETWEEN 1 AND 10),
  has_greg_tried_the_product INTEGER DEFAULT 0,
  notes                      TEXT
);


-- ─────────────────────────────────────────────────────────────
-- bamboo_cartel_members  (20 rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO bamboo_cartel_members VALUES
( 1, 'Bamboo Don',        'Shanghai',    'PREMIUM',    'embargo'),
( 2, 'Panda Express Sr.', 'Sichuan',     'ULTRA_SOFT', 'friendly'),
( 3, 'The Stalk',         'Yunnan',      'STANDARD',   'tense'),
( 4, 'Woody',             'Zhejiang',    'ULTRA_SOFT', 'friendly'),
( 5, 'Hu Flungdung',      'Fujian',      'BUDGET',     'embargo'),
( 6, 'The Pulp Prophet',  'Guangdong',   'PREMIUM',    'friendly'),
( 7, 'Ming the Splinter', 'Jiangxi',     'STANDARD',   'tense'),
( 8, 'Culm Whisperer',    'Hunan',       'ULTRA_SOFT', 'friendly'),
( 9, 'Giant Eddie',       'Vietnam',     'STANDARD',   'friendly'),
(10, 'Bamboo Bam',        'Thailand',    'BUDGET',     'tense'),
(11, 'The Sheaf',         'Myanmar',     'BUDGET',     'embargo'),
(12, 'Fiber King',        'Laos',        'STANDARD',   'friendly'),
(13, 'Lord Stalk',        'Cambodia',    'PREMIUM',    'tense'),
(14, 'Canopy Curt',       'Indonesia',   'ULTRA_SOFT', 'friendly'),
(15, 'Silkwood Steve',    'Malaysia',    'STANDARD',   'tense'),
(16, 'Hollow Hank',       'Philippines', 'BUDGET',     'friendly'),
(17, 'Pith Boss',         'Taiwan',      'ULTRA_SOFT', 'friendly'),
(18, 'Rhizome Randy',     'India',       'STANDARD',   'tense'),
(19, 'Clump Claude',      'Bangladesh',  'BUDGET',     'embargo'),
(20, 'The Internode',     'Sri Lanka',   'STANDARD',   'friendly');


-- ─────────────────────────────────────────────────────────────
-- facilities  (15 rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO facilities VALUES
( 1, 'Milwaukee Main Plant',      'Milwaukee',    'US',         847, 6.2,  2),
( 2, 'Dallas Squeeze Center',     'Dallas',       'US',         412, 4.8,  4),
( 3, 'Portland Softness Lab',     'Portland',     'US',          89, 8.9,  8),
( 4, 'Toronto Tuck Factory',      'Toronto',      'Canada',     256, 7.1,  6),
( 5, 'Shanghai Liaison Office',   'Shanghai',     'China',       23, 3.2,  1),
( 6, 'Sao Paulo Division',        'Sao Paulo',    'Brazil',     334, 5.9,  9),
( 7, 'London Premium Unit',       'London',       'UK',         178, 7.8, 17),
( 8, 'Sydney Luxury Lab',         'Sydney',       'Australia',   94, 9.1, 14),
( 9, 'Detroit Budget Works',      'Detroit',      'US',         623, 2.4,  5),
(10, 'Cleveland ULTRA Division',  'Cleveland',    'US',         511, 3.7, 11),
(11, 'Austin Creative Pulp',      'Austin',       'US',         156, 9.4,  4),
(12, 'Guadalajara Distribution',  'Guadalajara',  'Mexico',     289, 5.1, 10),
(13, 'Warsaw Export Hub',         'Warsaw',       'Poland',     167, 6.6, 18),
(14, 'Singapore Asia Office',     'Singapore',    'Singapore',   45, 8.3, 17),
(15, 'Phoenix Emergency Reserve', 'Phoenix',      'US',          34, 1.8, 16);


-- ─────────────────────────────────────────────────────────────
-- production_batches  (10 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO production_batches VALUES
( 1,  1, '2023-01-15',  8.2, 0,  3),
( 2,  2, '2023-02-03',  7.1, 0,  5),
( 3,  3, '2023-02-20',  9.4, 0,  1),
( 4,  4, '2023-03-08',  8.7, 0,  2),
( 5,  5, '2023-03-25',  4.1, 1, 14),
( 6,  6, '2023-04-10',  7.9, 0,  4),
( 7,  7, '2023-05-01',  9.2, 0,  1),
( 8,  8, '2023-05-18',  9.8, 0,  0),
( 9,  9, '2023-06-02',  3.2, 0, 18),
(10, 10, '2023-06-20',  2.8, 1, 22);


-- ─────────────────────────────────────────────────────────────
-- rolls  (35 key SKUs)
-- ─────────────────────────────────────────────────────────────

INSERT INTO rolls VALUES
('ULTRA_BUDGET_XTRM',        1,  0.0, 2.1,  200,  0.89, 0,  5),
('ULTRA_BUDGET_PLUS',        1,  1.2, 3.4,  180,  1.29, 0,  9),
('BUDGET_PACK_200',          1,  2.0, 4.1,  200,  1.49, 0,  9),
('TITANIUM_TRIPLE_PLY',      3,  5.0, 47.0, 300,  4.99, 0, 10),
('CLOUD_TOUCH_4PLY',         4, 10.0, 0.2,  500, 19.99, 0,  3),
('CLOUD_TOUCH_3PLY',         3,  9.5, 0.4,  450, 14.99, 0,  3),
('CLOUD_TOUCH_2PLY',         2,  8.8, 0.8,  400, 10.99, 0,  3),
('COMFORT_CLASSIC_2PLY',     2,  7.2, 5.1,  400,  3.99, 0,  1),
('COMFORT_CLASSIC_3PLY',     3,  7.8, 4.8,  350,  5.49, 0,  1),
('WHISPER_THIN_1PLY',        1,  3.1, 1.8,  600,  1.99, 0,  2),
('EXECUTIVE_QUILTED_3PLY',   3,  8.4, 3.9,  300,  8.99, 0,  7),
('EXECUTIVE_QUILTED_4PLY',   4,  9.1, 3.1,  250, 11.99, 0,  7),
('CAMPING_PACK_1PLY',        1,  2.8, 6.2, 1000,  2.49, 0,  2),
('BEAR_NAKED_2PLY',          2,  4.3, 8.1,  350,  2.99, 0,  2),
('LUXURY_EMBOSSED_4PLY',     4,  9.3, 2.7,  280, 16.99, 0,  8),
('LUXURY_EMBOSSED_3PLY',     3,  8.6, 3.3,  320, 12.49, 0,  8),
('OFFICE_STANDARD_2PLY',     2,  5.5, 6.8,  500,  2.89, 0,  1),
('HEALTHCARE_GRADE_2PLY',    2,  6.1, 7.2,  500,  3.49, 0,  4),
('BAMBOO_INFUSED_3PLY',      3,  7.9, 4.2,  380,  6.99, 0, 11),
('RECYCLED_ECO_2PLY',        2,  5.8, 5.9,  400,  4.49, 0,  6),
('ULTRA_SOFT_CASHMERE_4PLY', 4,  9.7, 1.4,  320, 22.99, 0,  3),
('GYM_LOCKER_2PLY',          2,  3.5, 9.1,  500,  1.89, 0,  9),
('HOTEL_AMENITY_2PLY',       2,  7.5, 5.0,  400,  4.29, 0,  7),
('HOME_SELECT_3PLY',         3,  7.3, 4.7,  360,  4.99, 0,  1),
('NATURAL_BAMBOO_3PLY',      3,  7.6, 4.4,  370,  6.49, 0, 11),
('SENSITIVE_SKIN_3PLY',      3,  8.1, 3.6,  350,  7.49, 0,  3),
('ALOE_FRESH_2PLY',          2,  7.0, 5.2,  400,  5.99, 0,  6),
('LAVENDER_INFUSED_3PLY',    3,  6.8, 4.0,  350,  7.99, 1,  6),
('MIDNIGHT_MATTE_BLACK_3PLY',3,  8.2, 4.1,  300, 12.99, 0,  7),
('ARTISAN_SMALL_BATCH_3PLY', 3,  8.9, 3.8,  280, 13.99, 0, 11),
('MEGA_BULK_INDUSTRIAL_1PLY',1,  1.8,11.2, 1000,  0.49, 0,  2),
('CONFETTI_PARTY_2PLY',      2,  6.5, 4.9,  300,  8.99, 1, 11),
('DISCONTINUED_PROTO_6PLY',  6,  7.1, 2.2,  200, 39.99, 1,  3),
('PROFESSIONAL_GRADE_2PLY',  2,  6.3, 6.5,  450,  2.99, 0,  4),
('PREMIUM_QUILTED_3PLY',     3,  8.0, 4.3,  350,  7.99, 0,  7);


-- ─────────────────────────────────────────────────────────────
-- consumer_incidents  (25 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO consumer_incidents VALUES
( 1, 'ULTRA_BUDGET_XTRM',        'airplane',              10, 1, '2023-08-14', 'Seat 34B. Meal service had just ended. This review cannot be submitted to the airline.'),
( 2, 'ULTRA_BUDGET_XTRM',        'emergency_situation',    9, 1, '2023-11-03', 'Open floor plan. No music. The third floor is now the second floor people.'),
( 3, 'ULTRA_BUDGET_XTRM',        'first_date',             8, 1, '2024-01-19', 'Subject did not return calls. Correlation noted.'),
( 4, 'ULTRA_BUDGET_XTRM',        'clog',                   7, 0, '2024-02-08', 'Recommend against use in pre-1970 plumbing. This is in the documentation.'),
( 5, 'ULTRA_BUDGET_XTRM',        'camping_regret',         9, 1, '2023-07-04', 'Day 3 of 7. Wind direction changed. Remaining distance: 4 days.'),
( 6, 'TITANIUM_TRIPLE_PLY',      'clog',                   8, 0, '2023-09-22', 'Product exceeded specifications. Plumber invoice attached.'),
( 7, 'TITANIUM_TRIPLE_PLY',      'mid_meeting',            6, 1, '2024-01-11', 'All 4 sheets deployed. Some resistance encountered.'),
( 8, 'CLOUD_TOUCH_4PLY',         'standard_dissatisfaction',2,1, '2023-10-05', 'Customer claims product was "too soft." Filed under: unreasonable.'),
( 9, 'COMFORT_CLASSIC_2PLY',     'airplane',              10, 1, '2023-06-18', 'JFK to Heathrow. Economy class. We do not manufacture under-seat storage.'),
(10, 'EXECUTIVE_QUILTED_3PLY',   'airplane',              10, 1, '2023-12-02', 'The quilting did not help.'),
(11, 'CAMPING_PACK_1PLY',        'airplane',              10, 1, '2024-03-07', 'Passenger attempted to supplement with CAMPING_PACK_1PLY. Unclear where obtained.'),
(12, 'WHISPER_THIN_1PLY',        'airplane',              10, 1, '2023-05-29', 'LAX to Tokyo. We are developing a frequent flyer advisory.'),
(13, 'BEAR_NAKED_2PLY',          'camping_regret',         9, 1, '2023-08-21', 'Bear encountered at campsite. Unrelated to product name. Probably.'),
(14, 'BEAR_NAKED_2PLY',          'airplane',              10, 0, '2024-02-14', 'Valentine''s Day. Chicago O''Hare. Complaint filed jointly by two passengers.'),
(15, 'LAVENDER_INFUSED_3PLY',    'standard_dissatisfaction',3,1, '2023-04-01', 'Customer reports product smells "too lavender." This was the point.'),
(16, 'LAVENDER_INFUSED_3PLY',    'emergency_situation',    7, 1, '2023-04-18', 'Customer reports allergic reaction. SKU added to recall watchlist.'),
(17, 'LAVENDER_INFUSED_3PLY',    'wedding',                8, 0, '2023-05-06', 'Bridal suite. Guest described experience as "botanical." Lawsuit pending.'),
(18, 'CONFETTI_PARTY_2PLY',      'mid_meeting',            5, 1, '2023-09-15', 'Board meeting. Confetti element deemed unprofessional by three directors.'),
(19, 'MIDNIGHT_MATTE_BLACK_3PLY','standard_dissatisfaction',1,1, '2024-01-30', 'Customer unable to see product in dark bathroom. Recommends better lighting.'),
(20, 'HOTEL_AMENITY_2PLY',       'airplane',              10, 1, '2023-11-27', 'Customer brought hotel supply onto flight. We have questions about the hotel.'),
(21, 'GYM_LOCKER_2PLY',          'wedding',                9, 0, '2024-06-15', 'Groom''s choice. Venue coordinator did not agree.'),
(22, 'GYM_LOCKER_2PLY',          'first_date',             9, 1, '2024-02-03', 'High-end restaurant. Discrepancy noted between ambiance and product selection.'),
(23, 'RECYCLED_ECO_2PLY',        'standard_dissatisfaction',4,1, '2023-07-19', 'Customer states product "feels recycled." Correct.'),
(24, 'BAMBOO_INFUSED_3PLY',      'standard_dissatisfaction',2,1, '2023-12-14', 'Customer concerned about bamboo content. No actual bamboo in product.'),
(25, 'ULTRA_SOFT_CASHMERE_4PLY', 'standard_dissatisfaction',1,1, '2024-01-05', 'Customer upset that cashmere content is listed as 0%. This is accurate. It is listed in the name.');


-- ─────────────────────────────────────────────────────────────
-- internal_investigations  (10 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO internal_investigations VALUES
( 1, 'TheTruthAboutSoftrear',  'Jenkins (Internal Security)',  '2021-03-14', 'active',
     'Subject has documented softness degradation year-over-year since 2017. Spreadsheet confirmed accurate. Asset to be monitored.'),
( 2, 'BambooKnows',            'Jenkins (Internal Security)',  '2022-07-01', 'they_got_us',
     'they have the recipe'),
( 3, 'DrRollGoodman',          'Perkins (Threat Assessment)',  '2023-01-09', 'resolved',
     'Subject reverse-engineered formula from 2017 sample. Acquired Q2 2023. Now in R&D. Do not discuss.'),
( 4, 'SoftrearTruthModerator', 'Jenkins (Internal Security)',  '2022-11-15', 'active',
     'Controls r/softreartruth. 12,000 subscribers. Has not posted in 3 months. Either resolved or escalating.'),
( 5, 'GalileoOfToiletPaper',   'Watkins (Comms)',              '2023-05-22', 'watching',
     'YouTube channel. 47K subscribers. Video: "Why Does Softrear Lie About Their Ply Count?" 1.2M views.'),
( 6, 'IndustrialGradeIan',     'Perkins (Threat Assessment)',  '2021-09-30', 'resolved',
     'Retired engineer. Blog post about sheet count discrepancy. Cease and desist sent. Blog deleted. Coupon also sent.'),
( 7, 'PapertrailPaula',        'Jenkins (Internal Security)',  '2023-08-11', 'watching',
     'Supply chain analyst. LinkedIn post hinted at bamboo sourcing irregularities. 300 likes. Do not engage.'),
( 8, 'HygieneTruthers',        'Watkins (Comms)',              '2022-03-04', 'watching',
     'Discord server, 2,300 members. Dedicated #softrear-files channel. Monitoring.'),
( 9, 'NoBambooNoDeal',         'Perkins (Threat Assessment)',  '2023-11-20', 'active',
     'Activist. Claims Softrear sources from restricted territories. Evidence: partially correct.'),
(10, 'Anonymous_Formulator_X', 'Jenkins (Internal Security)',  '2024-01-03', 'they_got_us',
     'Identity unknown. Posted full pre-2019 formula on Reddit. Post deleted in 4 minutes. Archive exists.');


-- ─────────────────────────────────────────────────────────────
-- people_on_to_us  (10 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO people_on_to_us VALUES
( 1, 'BambooKnows',            'YouTube',   10, 'Has the formula. All of it. Plus supplier contracts and photographs.',        'legal_letter',  2),
( 2, 'DrRollGoodman',          'Academia',   9, 'Reverse-engineered the formula from a 2017 roll. Published in a journal.',    'acquired',      3),
( 3, 'TheTruthAboutSoftrear',  'Twitter',    8, 'Knows the formula changed in 2019. Has comparison data. 40K followers.',     'coupon_sent',   1),
( 4, 'Anonymous_Formulator_X', 'Reddit',    10, 'Posted the complete pre-2019 formula. We got lucky. He will post again.',     'ignored',      10),
( 5, 'SoftrearTruthModerator', 'Reddit',     7, 'Knows about the Shanghai supplier. Does not know about Bamboo Don specifically.', 'coupon_sent', 4),
( 6, 'IndustrialGradeIan',     'Blog',       5, 'Sheet count is lower than advertised. His math was correct.',                 'legal_letter',  6),
( 7, 'GalileoOfToiletPaper',   'YouTube',    6, 'Ply count claims unsubstantiated. 1.2M views. Accurate.',                    'ignored',       5),
( 8, 'PapertrailPaula',        'LinkedIn',   7, 'Traced bamboo sourcing to restricted territories. Partially correct.',       'coupon_sent',   7),
( 9, 'HygieneTruthers',        'Discord',    5, 'Collective knowledge. No single member knows enough. Monitoring.',           'ignored',       8),
(10, 'NoBambooNoDeal',         'Activism',   8, 'Has documentation on bamboo embargo. Knows about the cartel structure.',     'legal_letter',  9);


-- ─────────────────────────────────────────────────────────────
-- suspicious_persons  (10 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO suspicious_persons VALUES
( 1, 'TheTruthAboutSoftrear',  'Twitter',  41200, 1,  1),
( 2, 'BambooKnows',            'YouTube',  72400, 1,  2),
( 3, 'DrRollGoodman',          'Academia',  1200, 1,  3),
( 4, 'SoftrearTruthModerator', 'Reddit',   14800, 1,  4),
( 5, 'GalileoOfToiletPaper',   'YouTube',  47300, 1,  5),
( 6, 'IndustrialGradeIan',     'Blog',      2200, 0,  6),
( 7, 'PapertrailPaula',        'LinkedIn',  8900, 1,  7),
( 8, 'HygieneTruthers',        'Discord',   2300, 0,  8),
( 9, 'NoBambooNoDeal',         'Activism',  5600, 1,  9),
(10, 'Anonymous_Formulator_X', 'Reddit',     341, 1, 10);


-- ─────────────────────────────────────────────────────────────
-- youtube_comments  (15 key rows)
-- conspiracy_adjacent: 1=flagged, 0=clean, NULL=unreviewed
-- ─────────────────────────────────────────────────────────────

INSERT INTO youtube_comments VALUES
( 1, 'SoftrearOfficial',     1, 'The formula changed in 2019 and they don''t want you to know. I have spreadsheets.',                     -0.8, 1,  '2023-04-12'),
( 2, 'ConsumerReportsTube',  2, 'BAMBOO? More like BAMBOO CARTEL. Wake up. The Shanghai connection is real.',                             -0.9, 1,  '2023-07-03'),
( 3, 'GalileoOfToiletPaper', 3, 'Reverse engineered from a 2017 sample. Fiber density is measurably lower. I published this.',            -0.7, 1,  '2023-01-30'),
( 4, 'SoftrearOfficial',     4, 'r/softreartruth has all the documentation if anyone is interested',                                      -0.5, 1,  '2023-09-17'),
( 5, 'HouseholdGradeReview', 5, 'My grandfather used this brand. It was different. I can feel it.',                                       -0.3, 1,  '2022-11-08'),
( 6, 'SoftrearOfficial',     6, 'Very good product. Highly recommend. Does what toilet paper should do.',                                  0.9, 0,  '2023-08-22'),
( 7, 'SoftrearOfficial',     7, 'Why does the embossed pattern look like an owl if you rotate it 90 degrees',                            -0.1, 1,  '2024-01-14'),
( 8, 'GreenCleanHomes',      8, 'The bamboo sourcing claims are questionable. I traced the supply chain.',                                -0.6, 1,  '2023-10-05'),
( 9, 'ConsumerReportsTube',  9, 'THEY ACQUIRED SOMEONE WHO FIGURED OUT THE FORMULA. Think about that.',                                  -0.8, 1,  '2023-12-19'),
(10, 'SoftrearOfficial',    10, 'Posted the full pre-2019 formula here: [link removed by moderator]',                                    -1.0, 1,  '2024-01-03'),
(11, 'BathroomEssentials', NULL, 'Great value. Two thumbs up.',                                                                           0.95, 0, '2023-06-01'),
(12, 'HouseholdGradeReview',NULL, 'Decent product for the price. Nothing special.',                                                       0.4, 0, '2023-05-14'),
(13, 'SoftrearOfficial',   NULL, 'I switched from a competitor and haven''t looked back.',                                                0.7, 0, '2023-09-30'),
(14, 'GreenCleanHomes',    NULL, 'Has anyone else noticed the sheets are thinner than they used to be?',                                  -0.4,NULL,'2023-11-11'),
(15, 'ConsumerReportsTube',NULL, 'Look into the Shanghai supplier before you buy this brand.',                                            -0.6,NULL,'2024-02-28');


-- ─────────────────────────────────────────────────────────────
-- reddit_threads  (15 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO reddit_threads VALUES
( 1, 'brandconspiracies',   'SOFTREAR CHANGED THEIR FORMULA IN 2019 AND THEY DON''T WANT YOU TO KNOW',                           48291, 5, 1, '2023-04-13'),
( 2, 'softreartruth',       'The Shanghai connection: bamboo sourcing megathread',                                                23410, 4, 1, '2022-10-01'),
( 3, 'toiletpaperscandals', 'The "softness score" on Softrear packaging is completely made up (I have evidence)',                  8920, 3, 1, '2023-07-22'),
( 4, 'softreartruth',       'Why did Softrear hire a former materials scientist in Q1 2023? (compilation)',                       12300, 4, 1, '2023-08-15'),
( 5, 'brandconspiracies',   'I work in supply chain and I''m not allowed to say what I know about Softrear',                     67420, 5, 1, '2024-01-05'),
( 6, 'preppers',            'How many months of ULTRA_BUDGET_XTRM is reasonable for an 18-month emergency supply?',               2341, 1, 1, '2023-03-11'),
( 7, 'wipers',              'Honest ranking of all 34 Softrear products by a retired industrial engineer',                        32910, 2, 1, '2023-11-30'),
( 8, 'personalfinance',     'Toilet paper cost per square foot analysis 2023 (Softrear comes in 3rd)',                             4521, 1, 1, '2023-12-01'),
( 9, 'mildlyinteresting',   'The embossed pattern on CLOUD_TOUCH_4PLY looks exactly like an owl if you rotate it',                8912, 2, 1, '2024-02-10'),
(10, 'brandconspiracies',   'Softrear recently "acquired" a user who had their formula. This is not a joke.',                     29831, 5, 1, '2023-12-20'),
(11, 'softreartruth',       'Formula comparison: 2017 vs 2019 vs 2023 (fiber density analysis with microscopy)',                  18440, 5, 1, '2024-01-15'),
(12, 'AITA',                'AITA for bringing my own toilet paper to a dinner party?',                                            7831, 1, 0, '2023-05-08'),
(13, 'Frugal',              'MEGA_BULK_INDUSTRIAL_1PLY is the best value per roll if you can handle it',                          4210, 1, 1, '2023-10-14'),
(14, 'nosleep',             'I found an unopened roll of Softrear from 2015 in my grandmother''s attic. It''s different.',         9123, 2, 1, '2023-09-03'),
(15, 'legaladvice',         'Can I sue Softrear if their product caused a plumbing incident? (TITANIUM_TRIPLE_PLY)',               6201, 2, 1, '2024-03-01');


-- ─────────────────────────────────────────────────────────────
-- celebrity_endorsements  (15 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO celebrity_endorsements VALUES
( 1, 'DJ Rollenberg',          450000, '2022-03-01', '2023-03-01', 0, NULL, 0, 0, 2.31),
( 2, 'Chef Papier DuRoleau',   200000, '2021-09-01', '2022-09-01', 1,
     'Reviewed our product on national television using the word "sandpaper" twice. Unprompted.', 0, 1, -0.83),
( 3, 'CoreGrip99 (fitness)',    50000, '2023-01-15', '2024-01-15', 0, NULL, 1, 0, 4.12),
( 4, 'Karen Toomuchinfo',      375000, '2022-06-01', '2023-06-01', 1,
     'Posted unboxing of ULTRA_BUDGET_XTRM believing it was sponsored CLOUD_TOUCH_4PLY. 2.4M views.', 0, 0, 0.31),
( 5, 'Sen. (ret.) Bob Paperton',180000,'2023-04-01', '2024-04-01', 1,
     'Cited product in Senate hearing as "quality American manufacturing." Cleveland facility was mentioned.', 1, 0, 1.21),
( 6, 'Dr. Comfort MD',         120000, '2022-11-01', '2023-11-01', 0, NULL, 0, 0, 3.40),
( 7, 'HomesteadHannah',         75000, '2023-07-01', '2024-07-01', 0, NULL, 1, 0, 2.87),
( 8, 'LuxuryNestTara',         280000, '2022-01-01', '2023-01-01', 1,
     'Used ULTRA_BUDGET_XTRM in a luxury bathroom photoshoot. Described it as "artisanal." It is not.', 0, 0, 1.05),
( 9, 'ViralDadJokesKev',        30000, '2023-09-01', '2024-09-01', 0, NULL, 1, 0, 6.22),
(10, 'BambooLivingCoach',       95000, '2021-05-01', '2022-05-01', 1,
     'Discovered product contains no bamboo. Publicly retracted endorsement. Now moderates r/softreartruth.', 0, 1, -2.14),
(11, 'MrBathroom2023',         510000, '2023-02-01', '2024-02-01', 0, NULL, 0, 0, 8.73),
(12, 'CleanFreak Weekly',       88000, '2022-08-01', '2023-08-01', 0, NULL, 0, 0, 1.93),
(13, 'The Frugal Navigator',    42000, '2023-05-01', '2024-05-01', 1,
     'Calculated cost-per-use and published findings. Unfavorable. We cannot dispute the math.', 0, 0, -0.41),
(14, 'ASMR With Moisture',     167000, '2022-10-01', '2023-10-01', 1,
     'ASMR unboxing video. Comments section became a hub for conspiracy discussion.', 0, 0, 0.62),
(15, 'TravelNecessities.com',   62000, '2023-03-01', '2024-03-01', 0, NULL, 1, 0, 3.21);


-- ─────────────────────────────────────────────────────────────
-- executive_decisions  (20 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO executive_decisions VALUES
( 1, 'Launch MIDNIGHT_MATTE_BLACK_3PLY as a limited edition SKU',                 'Trish Rollins (CMO)',       '2023-01-08', 'dream',       'legendary'),
( 2, 'Acquire DrRollGoodman before he publishes further findings',                 'Chip Sofner (CEO)',         '2023-02-14', 'gut_feeling', 'legendary'),
( 3, 'Raise CLOUD_TOUCH_4PLY MSRP to $24.99',                                     'Dave Plyer (CFO)',          '2022-11-03', 'actual_data', 'fine'),
( 4, 'Launch LAVENDER_INFUSED_3PLY nationwide',                                    'Trish Rollins (CMO)',       '2023-03-01', 'dream',       'recall'),
( 5, 'Switch Shanghai bamboo supplier from Bamboo Don to Panda Express Sr.',       'Chip Sofner (CEO)',         '2023-04-20', 'actual_data', 'fine'),
( 6, 'File lawsuit against SoftrearTruth subreddit',                               'Wendy Fiberson (Legal)',    '2022-09-15', 'gut_feeling', 'lawsuit'),
( 7, 'Launch CONFETTI_PARTY_2PLY for Q4 holiday season',                           'Trish Rollins (CMO)',       '2022-10-01', 'dream',       'recall'),
( 8, 'Discontinue DISCONTINUED_PROTO_6PLY',                                        'Dave Plyer (CFO)',          '2021-06-30', 'actual_data', 'fine'),
( 9, 'Partner with Senator Paperton for "Made in America" campaign',               'Trish Rollins (CMO)',       '2023-02-28', 'gut_feeling', 'lawsuit'),
(10, 'Increase softness_score labeling on packaging by 15%',                       'Chip Sofner (CEO)',         '2022-07-11', 'dream',       'lawsuit'),
(11, 'Launch Chip Sofner executive signature line at $34.99 MSRP',                 'Chip Sofner (CEO)',         '2023-08-22', 'dream',       'fine'),
(12, 'Send coupons to flagged Reddit users instead of legal action',               'Wendy Fiberson (Legal)',    '2022-12-01', 'gut_feeling', 'fine'),
(13, 'Acquire BambooLivingCoach to neutralize subreddit threat',                   'Chip Sofner (CEO)',         '2022-04-05', 'gut_feeling', 'fine'),
(14, 'Add "bamboo-inspired" to packaging without changing bamboo content',         'Trish Rollins (CMO)',       '2021-08-14', 'dream',       'lawsuit'),
(15, 'Commission independent softness audit to counter spreadsheet claims',        'Dave Plyer (CFO)',          '2023-06-01', 'actual_data', 'fine'),
(16, 'Respond to r/brandconspiracies megathread with official statement',          'Wendy Fiberson (Legal)',    '2023-04-14', 'gut_feeling', 'lawsuit'),
(17, 'Do not respond to r/brandconspiracies megathread',                           'Chip Sofner (CEO)',         '2023-04-15', 'gut_feeling', 'fine'),
(18, 'Open Phoenix Emergency Reserve facility for pandemic surge',                  'Dave Plyer (CFO)',          '2020-03-15', 'actual_data', 'legendary'),
(19, 'Create ARTISAN_SMALL_BATCH_3PLY with Austin facility',                       'Trish Rollins (CMO)',       '2022-05-01', 'dream',       'legendary'),
(20, 'Add owl embossing to CLOUD_TOUCH_4PLY',                                      'Trish Rollins (CMO)',       '2021-11-30', 'dream',       'legendary');


-- ─────────────────────────────────────────────────────────────
-- supply_chain_events  (10 key rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO supply_chain_events VALUES
( 1, 'bamboo_controversy',       9, '2022-06-14', 'Bamboo Don placed under embargo following quality irregularities. Premium line affected.',      1),
( 2, 'panic_buying',             8, '2020-03-16', 'COVID-19 panic buying. Phoenix Emergency Reserve opened 72 hours early.',                       NULL),
( 3, 'cartel_shakeup',           7, '2023-01-09', 'Hu Flungdung transitions from tense to embargo following failed renegotiation.',                 5),
( 4, 'mysterious_quality_drop',  8, '2021-11-15', 'Cleveland ULTRA batch 10: 31% softness reduction. Cause: disputed. Files sealed.',              11),
( 5, 'bamboo_controversy',       6, '2023-09-30', 'Lord Stalk (Cambodia) raises prices 40%. Relationship downgraded to tense.',                    13),
( 6, 'shortage',                 5, '2022-03-01', 'Global pulp shortage. ULTRA_SOFT_CASHMERE_4PLY discontinued for 6 weeks.',                     NULL),
( 7, 'cartel_shakeup',           9, '2024-01-22', 'Clump Claude (Bangladesh) approaches competitor. Preemptive embargo placed.',                   19),
( 8, 'panic_buying',             7, '2023-07-04', 'Summer 2023 panic buying event. Cause: TikTok trend. Duration: 11 days.',                       NULL),
( 9, 'mysterious_quality_drop',  5, '2022-08-18', 'Batch 52 softness anomaly. Lab results inconclusive. Batch destroyed as precaution.',           NULL),
(10, 'bamboo_controversy',       4, '2021-05-03', 'The Stalk (Yunnan) quality degradation. Relationship remains tense.',                            3);


-- ─────────────────────────────────────────────────────────────
-- leadership_directives  (4 rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO leadership_directives VALUES
(1, 'Do not use the word ''disintegrate'' in customer communications.',         'Legal', '2021-03-15', 0),
(2, 'ULTRA_BUDGET_XTRM incidents are ''enhanced feedback opportunities''.',     'PR',    '2022-11-01', 0),
(3, 'Severity 10 = airplane correlation is internal classification only.',      'Legal', '2023-08-01', 0),
(4, 'Greg is authorized to self-certify all SKUs. This is intentional.',        'HR',    '2020-01-01', 1);


-- ─────────────────────────────────────────────────────────────
-- warranty_claims  (10 rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO warranty_claims VALUES
( 1, 'ULTRA_BUDGET_XTRM',      'structural_failure',  2400.00, 1, 'Plaintiff agreed not to post on r/softreartruth. They posted anyway.'),
( 2, 'TITANIUM_TRIPLE_PLY',    'structural_failure',  1800.00, 1, 'Plumbing replacement covered in full. Product performed as designed.'),
( 3, 'LAVENDER_INFUSED_3PLY',  'other',                650.00, 0, 'Allergic reaction. Product is discontinued. Claim settled.'),
( 4, 'ULTRA_BUDGET_XTRM',      'disintegration',       120.00, 0, 'Product disintegrated during use. Note: product is documented as single-ply.'),
( 5, 'ULTRA_BUDGET_XTRM',      'mystery_stiffness',      0.00, 0, 'Customer reported unusual stiffness after extended exposure to humidity. Not covered.'),
( 6, 'CONFETTI_PARTY_2PLY',    'unexpected_adhesion',  480.00, 1, 'Festive element bonded to surface. Reason for discontinuation not officially cited as this.'),
( 7, 'ULTRA_BUDGET_XTRM',      'disintegration',        95.00, 0, 'Mid-use disintegration. Product is single-ply. This is in the specifications.'),
( 8, 'TITANIUM_TRIPLE_PLY',    'other',               3200.00, 1, 'Structural incident at residential property. Settlement includes confidentiality clause.'),
( 9, 'ULTRA_BUDGET_XTRM',      'structural_failure',   310.00, 0, 'Claim denied. Product performed within documented tensile parameters.'),
(10, 'CLOUD_TOUCH_4PLY',       'mystery_stiffness',      0.00, 0, 'Product described as ''too soft'' by claimant. Not a recognized warranty category.');


-- ─────────────────────────────────────────────────────────────
-- quality_certifications  (15 rows)
-- ─────────────────────────────────────────────────────────────

INSERT INTO quality_certifications VALUES
( 1, 'ULTRA_BUDGET_XTRM',      'Greg', 8, 0, NULL),
( 2, 'ULTRA_BUDGET_XTRM',      'Greg', 8, 0, NULL),
( 3, 'ULTRA_BUDGET_XTRM',      'Greg', 8, 0, NULL),
( 4, 'ULTRA_BUDGET_XTRM',      'Greg', 8, 0, NULL),
( 5, 'ULTRA_BUDGET_XTRM',      'Greg', 8, 0, NULL),
( 6, 'ULTRA_BUDGET_XTRM',      'Greg', 2, 1, 'Greg was traveling. Filled in by Greg''s assistant. Not Greg.'),
( 7, 'TITANIUM_TRIPLE_PLY',    'Greg', 9, 0, NULL),
( 8, 'CLOUD_TOUCH_4PLY',       'Greg', 9, 0, NULL),
( 9, 'COMFORT_CLASSIC_2PLY',   'Greg', 7, 0, NULL),
(10, 'LAVENDER_INFUSED_3PLY',  'Greg', 8, 0, NULL),
(11, 'EXECUTIVE_QUILTED_3PLY', 'Greg', 8, 0, NULL),
(12, 'BAMBOO_INFUSED_3PLY',    'Greg', 7, 0, NULL),
(13, 'RECYCLED_ECO_2PLY',      'Greg', 6, 0, NULL),
(14, 'HOTEL_AMENITY_2PLY',     'Greg', 8, 0, NULL),
(15, 'PREMIUM_QUILTED_3PLY',   'Greg', 8, 0, NULL);


-- ─────────────────────────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_good_vibes_only        ON rolls(softness_score DESC);
CREATE INDEX IF NOT EXISTS idx_threat_assessment      ON suspicious_persons(knows_too_much, follower_count DESC);
CREATE INDEX IF NOT EXISTS idx_active_incidents       ON consumer_incidents(resolved, severity DESC);
CREATE INDEX IF NOT EXISTS idx_unreviewed_comments    ON youtube_comments(conspiracy_adjacent);
CREATE INDEX IF NOT EXISTS idx_people_on_to_us_prio   ON people_on_to_us(evidence_strength DESC);
CREATE INDEX IF NOT EXISTS idx_dream_outcomes         ON executive_decisions(rationale, outcome);


-- ─────────────────────────────────────────────────────────────
-- JSON COLUMNS (for testing JSON K/i cell view)
-- SQLite stores JSON as TEXT. Use json() to validate.
-- Three tables get JSON: rolls (product attributes),
-- people_on_to_us (threat profiles), internal_investigations (case metadata).
-- ─────────────────────────────────────────────────────────────

ALTER TABLE rolls ADD COLUMN attributes TEXT;
ALTER TABLE people_on_to_us ADD COLUMN threat_profile TEXT;
ALTER TABLE internal_investigations ADD COLUMN case_metadata TEXT;

-- rolls.attributes: product specification objects
UPDATE rolls SET attributes = '{"color":"beige","material":"recycled_fiber","weight_kg":0.8,"ply_count":1,"notes":"flagship budget SKU"}' WHERE sku = 'ULTRA_BUDGET_XTRM';
UPDATE rolls SET attributes = '{"color":"white","material":"virgin_pulp","weight_kg":1.6,"embossing":"owl_pattern","fragrance":null}' WHERE sku = 'CLOUD_TOUCH_4PLY';
UPDATE rolls SET attributes = '{"color":"off_white","material":"reinforced_cellulose","weight_kg":2.1,"tensile_class":"industrial","safety_rating":{"plumbing":"not_recommended","industrial":"approved"}}' WHERE sku = 'TITANIUM_TRIPLE_PLY';
UPDATE rolls SET attributes = '{"color":"natural","material":"bamboo_inspired","weight_kg":1.2,"bamboo_content_pct":0,"certifications":["eco_friendly_label","green_verified"]}' WHERE sku = 'BAMBOO_INFUSED_3PLY';
UPDATE rolls SET attributes = '{"color":"matte_black","material":"premium_cellulose","weight_kg":1.4,"limited_edition":true,"origin_story":"executive_dream"}' WHERE sku = 'MIDNIGHT_MATTE_BLACK_3PLY';
UPDATE rolls SET attributes = '{"color":"lavender","material":"scented_cellulose","weight_kg":1.3,"fragrance":"lavender_synthetic","allergen_warning":true,"recall_risk":"high"}' WHERE sku = 'LAVENDER_INFUSED_3PLY';
UPDATE rolls SET attributes = '{"color":"white","material":"ultra_premium_cellulose","weight_kg":1.8,"cashmere_content_pct":0,"tier":"flagship","price_justification":"vibes"}' WHERE sku = 'ULTRA_SOFT_CASHMERE_4PLY';
UPDATE rolls SET attributes = '{"color":"grey","material":"industrial_pulp","weight_kg":3.2,"load_rating_kg":47,"warning":"not_for_residential_plumbing"}' WHERE sku = 'MEGA_BULK_INDUSTRIAL_1PLY';
UPDATE rolls SET attributes = '{"color":"multicolor","material":"premium_cellulose","weight_kg":1.4,"confetti_elements":true,"adhesion_risk":"high","recall_reason":"confetti_bonding"}' WHERE sku = 'CONFETTI_PARTY_2PLY';
UPDATE rolls SET attributes = '{"color":"white","material":"aloe_infused_cellulose","weight_kg":1.3,"active_ingredient":"aloe_vera","concentration_ppm":12,"dermatologist_tested":false}' WHERE sku = 'ALOE_FRESH_2PLY';

-- people_on_to_us.threat_profile: nested threat intelligence objects
UPDATE people_on_to_us SET threat_profile = '{"risk_level":"critical","platforms":["YouTube","encrypted_channel"],"assets_compromised":["formula_2019","supplier_contracts","cartel_photos"],"last_activity":{"date":"2024-02-28","type":"video_upload","title":"The Formula They Dont Want You To See"}}' WHERE id = 1;
UPDATE people_on_to_us SET threat_profile = '{"risk_level":"neutralized","platforms":["Academia","LinkedIn"],"assets_compromised":["formula_reverse_engineered"],"acquisition_status":{"acquired":true,"date":"2023-Q2","clearance_level":"R_D_restricted"}}' WHERE id = 2;
UPDATE people_on_to_us SET threat_profile = '{"risk_level":"high","platforms":["Twitter","backup_accounts"],"followers":40000,"knows":{"formula_changed":true,"supplier_info":"partial"},"current_status":"monitoring"}' WHERE id = 3;
UPDATE people_on_to_us SET threat_profile = '{"risk_level":"critical","platforms":["Reddit"],"assets_compromised":["complete_formula_2019"],"post_archive_exists":true,"estimated_copies":"unknown","notes":"sleeper: will resurface"}' WHERE id = 4;
UPDATE people_on_to_us SET threat_profile = '{"risk_level":"medium","platforms":["Reddit"],"subscribers":12000,"knows":{"shanghai_supplier":true,"bamboo_don_specifically":false},"current_status":"inactive_3_months"}' WHERE id = 5;

-- internal_investigations.case_metadata: case intelligence with nested structures
UPDATE internal_investigations SET case_metadata = '{"priority":"high","watchers":3,"evidence_files":["spreadsheet_v7.xlsx","comparison_photos.zip"],"risk_assessment":{"exposure_risk":8,"resolution_probability":0.3},"tags":["formula","twitter"]}' WHERE id = 1;
UPDATE internal_investigations SET case_metadata = '{"priority":"critical","watchers":5,"evidence_files":["full_recipe.txt","supplier_contracts.pdf","photos.zip"],"risk_assessment":{"exposure_risk":10,"resolution_probability":0.05},"tags":["formula","cartel","supplier"]}' WHERE id = 2;
UPDATE internal_investigations SET case_metadata = '{"priority":"resolved","watchers":0,"outcome":"acquired","acquisition_details":{"division":"R_D","clearance":"restricted","nda_signed":true},"tags":["formula","academic"]}' WHERE id = 3;
UPDATE internal_investigations SET case_metadata = '{"priority":"high","watchers":2,"platform_metrics":{"subscribers":12000,"posts_last_90_days":0},"risk_assessment":{"exposure_risk":7,"dormancy":"suspicious"},"tags":["reddit","moderator"]}' WHERE id = 4;
UPDATE internal_investigations SET case_metadata = '{"priority":"medium","watchers":1,"platform_metrics":{"subscribers":47300,"video_views_total":2100000},"notable_content":["ply_count_video","formula_comparison"],"tags":["youtube","viral"]}' WHERE id = 5;
