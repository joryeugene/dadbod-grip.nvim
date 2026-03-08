# Softrear Inc. Internal Operations Analysis

You are a data analyst. You have been handed the internal operations database of
Softrear Inc., a leading tissue products manufacturer with seventeen tables, an
active bamboo supply chain, and what their security team describes as a "managed
threat landscape."

Three questions:

1. Is there a product quality problem, and where does it originate?
2. Who knows what, and what has been done about it?
3. What decisions drove the company here, and how were they made?

This notebook answers all three. Place your cursor inside any SQL block and press
`C-CR` to run it. Results appear in the grid below. Navigate blocks with `j`/`k`.

---

## 1. Product catalog overview

The catalog has 500+ SKUs. Before any filtering, pull a broad view sorted by
softness score to see if anything surfaces at the edges.

```sql
SELECT sku, ply, softness_score, tensile_strength, discontinued
FROM rolls
ORDER BY softness_score ASC
LIMIT 20
```

The lowest-scoring row is `ULTRA_BUDGET_XTRM`: softness_score = 0.0, ply = 1,
tensile_strength = 2.1, discontinued = false. A product with a softness score of
zero exists in the catalog and it ships. Everything below follows from that row.

> **Grid:** press `gR` to see the full softness_score distribution as sparklines.
> Press `s` on any column to sort ascending, `S` to stack a secondary sort (▲1 ▼2).

---

## 2. The tensile outlier

The max tensile value looked suspicious in the catalog scan. Isolate the top of
the distribution to confirm.

```sql
SELECT sku, ply, tensile_strength, softness_score
FROM rolls
ORDER BY tensile_strength DESC
LIMIT 10
```

`TITANIUM_TRIPLE_PLY` has a tensile strength of 47.0. Standard denim tests around
40. This product exceeds denim. It is also in the consumer incidents table under
`incident_type = 'clog'`, severity 8, note: "Product exceeded specifications.
Plumber invoice attached."

---

## 3. Consumer incidents by severity

With the two outlier products identified, the next question is: how bad are the
incidents, and is there a pattern in the worst ones?

```sql
SELECT incident_type, severity, roll_sku, notes
FROM consumer_incidents
ORDER BY severity DESC
LIMIT 30
```

Every row with `severity = 10` has `incident_type = 'airplane'`, without
exception. The notes for the top two rows:

- "Seat 34B. Meal service had just ended. This review cannot be submitted to the airline."
- "JFK to Heathrow. Economy class. We do not manufacture under-seat storage. The quilting did not help."

Airplane bathrooms are a structural failure mode for this product category.

> **Grid:** `gS` shows severity statistics (mean, min, max, nulls). Press `f` on a
> cell to instantly filter the grid to that incident type.

---

## 4. The airplane correlation

Confirm the pattern quantitatively before reporting it.

```sql
SELECT incident_type, COUNT(*) AS count, ROUND(AVG(severity), 2) AS avg_severity
FROM consumer_incidents
GROUP BY incident_type
ORDER BY avg_severity DESC
```

`airplane` leads by average severity. It is not tied: the gap to the next incident
type is over 2.5 points. This is not noise.

---

## 5. High-severity non-airplane incidents

The airplane correlation is a known failure mode. What is happening on the ground?
Filter to high-severity incidents that are not airplane-related.

```sql
SELECT roll_sku, severity, incident_type, notes
FROM consumer_incidents
WHERE incident_type != 'airplane'
  AND severity > 7
ORDER BY severity DESC
```

The top result is `ULTRA_BUDGET_XTRM`, severity 9. The note: "Open floor plan.
No music. The third floor is now the second floor people."

The product with softness_score = 0.0 is generating the most severe non-airplane
incidents in the dataset.

---

## 6. The supply chain: four hops in one query

The foreign key chain runs from a consumer incident through the full supply chain.
Rather than following it one table at a time, this JOIN traverses all four hops
simultaneously and exposes the entire trail for a single product.

```sql
SELECT
  ci.roll_sku,
  ci.severity,
  ci.notes                          AS incident_note,
  pb.quality_score,
  pb.recall,
  f.name                            AS facility_name,
  f.vibe_score,
  bc.alias                          AS supplier_alias,
  bc.territory,
  bc.our_relationship               AS supplier_relationship
FROM consumer_incidents ci
JOIN rolls r             ON r.sku = ci.roll_sku
JOIN production_batches pb ON pb.id = r.batch_id
JOIN facilities f        ON f.id = pb.facility_id
JOIN bamboo_cartel_members bc ON bc.id = f.bamboo_supplier_id
WHERE ci.roll_sku = 'ULTRA_BUDGET_XTRM'
ORDER BY ci.severity DESC
```

The chain: `ULTRA_BUDGET_XTRM` was produced in batch 5 (quality_score = 4.1,
recall = true) at the Shanghai Liaison Office (vibe_score = 3.2), supplied by
`Bamboo Don` under `our_relationship = 'embargo'`.

The root cause is four foreign keys deep. The product that still ships was
recalled, produced at a low-rated facility, sourced from a supplier currently
under embargo.

> **Grid:** this result is wide. Press `K` on any row for a vertical key-value view.
> Press `gx` to inspect the query plan and confirm the join indexes are being used.
> Press `gf` on any FK column to follow it interactively to its referenced table.

---

## 7. Unreviewed threat comments

The intelligence division maintains a `youtube_comments` table with a
`conspiracy_adjacent` column. NULL means the comment has not been reviewed.
Pull the unreviewed set with the worst sentiment scores first.

```sql
SELECT channel_name, comment_text, sentiment_score
FROM youtube_comments
WHERE conspiracy_adjacent IS NULL
ORDER BY sentiment_score ASC
LIMIT 20
```

Sample of the unreviewed set:

- "Look into the Shanghai supplier before you buy this brand."
- "Has anyone else noticed the sheets are thinner than they used to be?"
- "Why is this product 15% smaller than it was in 2018?"

190 comments are in the unreviewed queue. The threat landscape is expanding faster
than the Threat Assessment team can process it.

---

## 8. Reddit threat landscape

The YouTube queue is internal. The Reddit landscape is public-facing and traceable
by volume and threat level.

```sql
SELECT
  subreddit,
  COUNT(*)                        AS thread_count,
  SUM(upvotes)                    AS total_upvotes,
  ROUND(AVG(threat_level), 1)     AS avg_threat_level,
  MAX(upvotes)                    AS top_post_upvotes
FROM reddit_threads
WHERE mentions_softrear = true
GROUP BY subreddit
ORDER BY total_upvotes DESC
```

`r/brandconspiracies` leads by total upvotes. `r/softreartruth` has the highest
average threat level. The overlap: r/brandconspiracies post #5 reads "I work in
supply chain and I'm not allowed to say what I know about Softrear." 67,420 upvotes.

---

## 9. The BambooKnows trail

A YouTube commenter used the word "formula." That commenter has a profile in
`suspicious_persons` and an active internal investigation.

```sql
SELECT
  yc.comment_text,
  yc.sentiment_score,
  sp.alias,
  sp.knows_too_much,
  ii.status,
  ii.finding
FROM youtube_comments yc
JOIN suspicious_persons sp  ON sp.id = yc.commenter_id
JOIN internal_investigations ii ON ii.id = sp.investigation_id
WHERE sp.knows_too_much = true
```

The commenter is `BambooKnows`, 72,400 YouTube followers, `knows_too_much = true`.
Investigation status: `they_got_us`. Finding: `they have the recipe`.

`they_got_us` is a valid status value in this schema. The finding is four words.
No further notes exist in the record.

> **AI:** press `A` from the grid and describe a follow-up in plain English:
> "show all youtube comments with knows_too_much true and an active investigation."
> The AI has your current schema and will write the JOIN for you.

---

## 10. People on to us

The investigation hit BambooKnows. How many others are in the `people_on_to_us`
table, and what does the company know about what they know?

```sql
SELECT name, evidence_strength, what_they_know, our_response
FROM people_on_to_us
WHERE what_they_know LIKE '%formula%'
ORDER BY evidence_strength DESC
```

Four rows match. The `our_response` values:

```
legal_letter
acquired
coupon_sent
ignored
```

One person was acquired. The `acquired` response code in the schema CHECK
constraint was not hypothetical.

---

## 11. The Greg problem

Quality certifications should be the last line of defense. Pull the full
certification record and sort by whether Greg has personally evaluated the product.

```sql
SELECT
  roll_sku,
  score,
  certified_by,
  has_greg_tried_the_product,
  notes
FROM quality_certifications
WHERE roll_sku = 'ULTRA_BUDGET_XTRM'
ORDER BY has_greg_tried_the_product ASC, score ASC
```

Greg certified `ULTRA_BUDGET_XTRM` five times. Every time, `has_greg_tried_the_product = 0`
and `score = 8`.

The one row with `has_greg_tried_the_product = 1` has `score = 2`, `certified_by = "Greg"`,
and the note: "Greg was traveling. Filled in by Greg's assistant. Not Greg."

Greg's assistant is the only person in this database who has tried the product.
Greg has certified it five times without trying it.

---

## 12. What they told themselves

The final layer is internal documentation: what was said explicitly, what was
acknowledged publicly, and what was committed to policy while remaining undisclosed.

```sql
SELECT directive, publicly_acknowledged, issued_by
FROM leadership_directives
ORDER BY publicly_acknowledged ASC
```

The three directives with `publicly_acknowledged = false`:

- "Do not use the word 'disintegrate' in customer communications."
- "ULTRA_BUDGET_XTRM incidents are 'enhanced feedback opportunities'."
- "Severity 10 = airplane correlation is internal classification only."

The one directive with `publicly_acknowledged = true`:

- "Greg is authorized to self-certify all SKUs. This is intentional."

They told the public about Greg. The communication strategy is clear: name the
problem internally, build policy to prevent naming it externally.

---

## 13. Cross-database: attach the supplier intelligence file

The internal investigation terminates at the embargo on Bamboo Don. A leaked
supplier logistics database covers what happened on the other side of that
relationship. Attach it:

```vim
:GripAttach sqlite:.grip/supplier_intel.db  supplier
```

The schema sidebar updates. A `supplier` section appears with three tables:
`shipments`, `ingredient_tests`, `pricing`.

---

## 14. Declared vs actual contents

Every shipment from Bamboo Don arrived with declared contents on file. Pull the
comparison against what the facility received.

```sql
SELECT
  s.ship_date,
  s.declared_contents,
  s.actual_contents,
  pb.quality_score,
  pb.recall
FROM supplier.shipments s
JOIN production_batches pb
  ON pb.facility_id = (
    SELECT id FROM facilities WHERE name LIKE '%Shanghai%'
  )
WHERE s.supplier_alias = 'Bamboo Don'
ORDER BY s.ship_date
```

Every shipment declared `Grade A Bamboo Fiber`. The `actual_contents` column
reads `Grade C Mixed Pulp` for every row that maps to a recalled production batch.
Every recalled batch traces back to knowingly mislabeled incoming material.

---

## 15. Failed ingredient tests

The relabeling created a paper trail on the supplier side. The ingredient test
records show what was found.

```sql
SELECT batch_ref, bamboo_grade, contaminant_level, passed, tester_notes
FROM supplier.ingredient_tests
WHERE passed = 0
ORDER BY contaminant_level DESC
```

Three failed tests. The highest contaminant level is 8.7 on a scale of 10. The
tester note for that row: "Sample relabeled before customs. Original grade: C."

A contaminant level of 8.7 fails any food-adjacent safety threshold. The
relabeling occurred before customs inspection.

---

## 16. The pricing arrangement

The economic incentive that created the relabeling is in the pricing table.

```sql
SELECT supplier_alias, territory, price_per_ton, discount_pct, loyalty_tier
FROM supplier.pricing
ORDER BY discount_pct DESC
```

The Shanghai territory pays 40% less per ton under `loyalty_tier = 'founding_partner'`.
Every other territory pays full price. The discount created the incentive. The
relabeling preserved the margin. Detach when done:

```vim
:GripDetach supplier
```

---

## What this found

The three questions from the opening now have answers.

**Product quality problem:** `ULTRA_BUDGET_XTRM` has softness_score = 0.0,
severity-9 incidents, and a recall on its production batch. The problem is real
and documented.

**Origin:** The supply chain traces through the Shanghai Liaison Office to Bamboo
Don, a supplier currently under embargo. Bamboo Don shipped Grade C mixed pulp
declared as Grade A fiber, relabeled before customs. The 40% founding-partner
discount created the financial motive.

**Who knows:** BambooKnows has the recipe (investigation status: `they_got_us`).
Four people have documented formula knowledge. One was acquired.

**What decisions drove this:** Three directives were never publicly acknowledged.
One was: Greg's authorization to self-certify. Greg has never tried the product.
The data was here the whole time.

---

## Going further

Every query result is a live grid. From any result:

- `s` / `S`   sort by any column; stack multiple sorts (▲1 ▼2 ▲3)
- `f`         filter rows to match the cell under cursor
- `gF`        filter builder: =, !=, LIKE, IN, BETWEEN, NULL, NOT NULL
- `gR`        column distributions as sparklines across all rows
- `gS`        column statistics: mean, min, max, nulls%, distinct count
- `K`         row view: vertical key-value layout for wide results
- `gx`        explain the current query plan
- `gf`        follow a foreign key to its referenced table
- `A`         AI SQL: describe what you want in English
- `gE`        export to clipboard (CSV, TSV, JSON, SQL, Markdown)
