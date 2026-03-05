# Internal Operations Review - Softrear Inc.

You are a data analyst. You have been handed the internal operations database of
Softrear Inc., a leading tissue products manufacturer with seventeen tables, an
active bamboo supply chain, and what their security team describes as a "managed
threat landscape."

Three questions:

1. Is there a product quality problem, and where does it originate?
2. Who knows what, and what has been done about it?
3. What decisions drove the company here, and how were they made?

This walkthrough answers all three using about 40 keystrokes, no spreadsheets,
and no context switching.

---

## Load the database

```vim
:GripStart
```

The database opens. Seventeen tables appear in the schema sidebar. The status
line shows the connection.

---

## Orient: the product catalog

Navigate to the `rolls` table and press `<CR>`.

The grid opens showing 500+ SKUs. Most look standard. Then you see it:

```
ULTRA_BUDGET_XTRM   ply=1   softness_score=0.0   tensile_strength=2.1
```

ULTRA_BUDGET_XTRM has a softness score of zero. This product exists and it ships.

---

## Profile the entire catalog at once

Press `gR`.

Data profiling opens. Every column gets a distribution and completeness check
simultaneously:

- `softness_score`: bimodal — a dense cluster at 1–3, another at 7–10, with
  almost nothing in between. Two product lines with no middle ground.
- `tensile_strength`: heavily right-skewed, with a long tail to the right.
- `discontinued`: roughly 6% of SKUs are discontinued.
- `ply`: mostly 2 and 3. One SKU at 6. One SKU at 1 that should not exist.

Five hundred products become comprehensible in under ten seconds. Press `q` to
return.

---

## Investigate the tensile outlier

Navigate to the `tensile_strength` column header. Press `gS`.

```
count    505          distinct   312
null %   0.0          min        0.2
mean     6.4          max        47.0
p50      5.9          top val    4.1 (11 rows)
```

The max is 47.0. The median is 5.9. One product has a tensile strength of 47.0;
for reference, standard denim is around 40. Navigate to the `sku` column, press
`s`, and choose descending by `tensile_strength`.

The top row is `TITANIUM_TRIPLE_PLY`, tensile strength 47.0. This product is
physically capable of resisting damage. It is also listed in `consumer_incidents`
under `clog`, severity 8, with the note: "Product exceeded specifications.
Plumber invoice attached."

---

## Consumer incidents: sort by severity

Navigate to `consumer_incidents`. Sort by `severity` descending.

Every row with `severity = 10` has `incident_type = 'airplane'`, without
exception. There are dozens of them. Airline bathrooms represent a structural
failure mode for this product category.

The notes column for two rows at the top reads:

```
"Seat 34B. Meal service had just ended. This review cannot be submitted to the airline."
"JFK to Heathrow. Economy class. We do not manufacture under-seat storage. The quilting did not help."
```

---

## Filter to the high-severity non-airplane incidents

Press `f` and enter:

```sql
incident_type = 'emergency_situation' AND severity > 7
```

The grid narrows. The top result is `ULTRA_BUDGET_XTRM`, severity 9. The note
field reads: "Open floor plan. No music. The third floor is now the second floor
people."

Press `gp` and save this filter as `high_severity_incidents`. It will be there
next quarter.

---

## Follow the product trail: FK drill-down

Stay on a row referencing `ULTRA_BUDGET_XTRM`. Navigate to the `roll_sku`
column. Press `gf`.

The grid jumps to the `rolls` table, focused on `ULTRA_BUDGET_XTRM`. Navigate
to `batch_id`. Press `gf`.

The grid is now in `production_batches`. Batch 5 has a `quality_score` of 4.1
and `recall = true`. Navigate to `facility_id`. Press `gf`.

The grid is now in `facilities`. Facility 5 is listed as the
`Shanghai Liaison Office`, with 23 workers and a `vibe_score` of 3.2. Navigate
to `bamboo_supplier_id`. Press `gf`.

The grid is now in `bamboo_cartel_members`. The supplier for the Shanghai
facility is:

```
alias: Bamboo Don   territory: Shanghai   our_relationship: embargo
```

The product trail runs from a consumer incident through a recalled batch, through
the Shanghai facility, and terminates at a supplier currently under embargo. The
root cause is four foreign keys deep.

---

## The intelligence division

Navigate to `youtube_comments`.

Press `gn` on the `conspiracy_adjacent` column.

The NULL filter engages. Roughly 190 rows become visible — comments that the
Threat Assessment team has not yet reviewed. The unreviewed set includes:

```
"Look into the Shanghai supplier before you buy this brand."
"Has anyone else noticed the sheets are thinner than they used to be?"
"Why is this product 15% smaller than it was in 2018?"
```

The threat landscape is expanding.

---

## Clean up the view

Press `gH` to open the column visibility picker. Hide `id`, `posted_date`, and
`commenter_id`. The grid is now showing four columns: `channel_name`,
`comment_text`, `sentiment_score`, `conspiracy_adjacent`.

---

## Inspect the schema

Press `gV`.

The DDL float opens for `youtube_comments`. Scroll down to `people_on_to_us`.

```sql
our_response TEXT CHECK (our_response IN (
  'ignored', 'coupon_sent', 'legal_letter', 'acquired'
))
```

`acquired` is a valid value in this constraint. Someone defined this as a
legitimate response to a person who knows too much. The CHECK constraint is
committed to main.

Scroll further to reach the index definitions:

```sql
CREATE INDEX idx_good_vibes_only ON rolls(softness_score DESC);
```

This is the production index on the product catalog.

---

## Ask a question about the threat landscape

Press `q` to open the query pad. Press `A` and describe what you need:

```
which subreddits have the most anti-Softrear threads by upvote count,
and what is the average threat level per subreddit
```

The AI reads the visible schema and generates:

```sql
SELECT
  subreddit,
  COUNT(*)                       AS thread_count,
  SUM(upvotes)                   AS total_upvotes,
  ROUND(AVG(threat_level), 1)    AS avg_threat_level,
  MAX(upvotes)                   AS top_post_upvotes
FROM reddit_threads
WHERE mentions_softrear = true
GROUP BY subreddit
ORDER BY total_upvotes DESC
```

Press `<CR>`. `brandconspiracies` leads by total upvotes. `softreartruth` has
the highest average threat level. The overlap between them is
r/brandconspiracies post #5: "I work in supply chain and I'm not allowed to say
what I know about Softrear." 67,420 upvotes.

Press `:GripSave` and name it `threat_landscape`.

---

## Follow the intelligence trail: deep FK drill

Navigate to `youtube_comments`. Find the row where `comment_text` contains
`formula`. Navigate to `commenter_id`. Press `gf`.

The grid is now in `suspicious_persons`. The commenter is `BambooKnows`, a
YouTube account with 72,400 followers and `knows_too_much = true`. Navigate to
`investigation_id`. Press `gf`.

The grid is now in `internal_investigations`. Investigation 2 reads:

```
subject_alias:  BambooKnows
status:         they_got_us
investigator:   Jenkins (Internal Security)
finding:        they have the recipe
```

`they_got_us` is a valid status value. `they have the recipe` is the complete
finding. No further notes.

---

## Examine the people_on_to_us table

Navigate to `people_on_to_us`. Sort by `evidence_strength` descending.

Three rows have `evidence_strength = 10`. Press `f`:

```sql
what_they_know LIKE '%formula%'
```

Six rows match. All have documented knowledge of the formula change.
The `our_response` values across these rows are:

```
legal_letter
acquired
coupon_sent
ignored
coupon_sent
coupon_sent
```

One person was acquired. The `acquired` response in the CHECK constraint was
not hypothetical.

---

## Quality control: the Greg problem

Navigate to `quality_certifications`. Sort by `has_greg_tried_the_product`
ascending.

Every row where `has_greg_tried_the_product = false` has a score of 8. There
are five of them. All five are for `ULTRA_BUDGET_XTRM`. All five are certified
by `Greg`.

One row has a score of 2:

```
certified_by: Greg's assistant   notes: Greg was traveling. Filled in by Greg's assistant. Not Greg.
```

Greg's assistant is the only person in this database who has tried the product.

---

## What they told themselves

Navigate to `leadership_directives`. Sort by `publicly_acknowledged` ascending.

Three directives have `publicly_acknowledged = false`:

```
"Do not use the word 'disintegrate' in customer communications."
"ULTRA_BUDGET_XTRM incidents are 'enhanced feedback opportunities'."
"Severity 10 = airplane correlation is internal classification only."
```

One directive has `publicly_acknowledged = true`:

```
"Greg is authorized to self-certify all SKUs. This is intentional."
```

They told the public about Greg.

---

## Stage a correction and review the diff

Navigate to `executive_decisions`. Filter:

```sql
rationale = 'dream' AND outcome = 'recall'
```

Two rows match. Open the cell editor on the `rationale` field of the first row.
Change `dream` to `actual_data`. Press `C-CR` to stage.

Press `gD`.

The diff float opens:

```diff
 decision_text: Launch LAVENDER_INFUSED_3PLY nationwide
-rationale: dream
+rationale: actual_data
 outcome: recall
```

The change is staged, not applied. Press `u` to cancel, or `a` to apply to the
database. The diff remains visible until you act.

---

## Export the findings

Press `F` to clear the filter. Navigate to the query result from
`threat_landscape`. Press `gE` and choose Markdown.

The formatted table copies to clipboard. The dossier is ready.

---

## What this covered

| Feature | Key | What it did |
|---------|-----|-------------|
| Open portal | `:GripStart` | 17 tables, no setup required |
| Browse and navigate | `j` / `k` / `h` / `l` | Located ULTRA_BUDGET_XTRM immediately |
| Data profiling | `gR` | Bimodal softness distribution at a glance |
| Column statistics | `gS` | Revealed tensile=47.0 outlier |
| Sort | `s` | Every severity=10 is type=airplane |
| Filter | `f` | Narrowed to high-severity non-flight incidents |
| Save filter preset | `gp` | `high_severity_incidents` reusable next session |
| FK drill-down | `gf` | Traced incident → roll → batch → facility → Bamboo Don |
| Null filter | `gn` | Surfaced 190 unreviewed threat comments |
| Column picker | `gH` | Focused view to 4 signal columns |
| DDL float | `gV` | Found `acquired` in CHECK constraint, `idx_good_vibes_only` in indexes |
| AI SQL generation | `A` | Natural language → window function SQL |
| Save query | `:GripSave` | `threat_landscape` named and reloadable |
| Deep FK drill | `gf` (×2) | youtube_comments → suspicious_persons → investigations |
| Quality certifications | `go` on `quality_certifications` | Revealed Greg, the score of 8, and the score of 2 |
| Leadership directives | `s` descending by `publicly_acknowledged` | Found what they admitted to publicly |
| Mutation diff | `gD` | Staged rationale change shown before apply |
| Export | `gE` | Markdown table to clipboard |

**Total keystrokes: ~40.**

The subreddit has 67,420 upvotes on a post from someone who works in supply
chain. The Shanghai facility supplier is under embargo. The product with
softness_score zero still ships. The person who had the recipe was acquired and
now works in R&D.

The data was here the whole time.

---

## Cross the organizational boundary

The internal investigation hit a wall at the Bamboo Don. The supplier is under
embargo. Internal data cannot explain what happened on the other side of that
relationship.

A leaked supplier logistics database has arrived. It covers shipments,
ingredient testing, and pricing.

Attach it:

```vim
:GripAttach sqlite:.grip/supplier_intel.db  supplier
```

The schema sidebar updates. A new `supplier` section appears below `main` with
three tables: `shipments`, `ingredient_tests`, `pricing`.

### Join across databases

Open the query pad (`q`). Write a cross-database join:

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
    SELECT id FROM facilities WHERE facility_name LIKE '%Shanghai%'
  )
  AND s.ship_date BETWEEN pb.batch_date AND pb.batch_date
WHERE s.supplier_alias = 'Bamboo Don'
ORDER BY s.ship_date
```

Press `<C-CR>`.

Every shipment from Bamboo Don declared `Grade A Bamboo Fiber`. The
`actual_contents` column reads `Grade C Mixed Pulp` for every row that maps to
a recalled production batch.

### Check the ingredient tests

```sql
SELECT
  it.batch_ref,
  it.bamboo_grade,
  it.contaminant_level,
  it.passed,
  it.tester_notes
FROM supplier.ingredient_tests it
WHERE it.passed = 0
ORDER BY it.contaminant_level DESC
```

Three failed tests. The highest contaminant level is 8.7 (scale of 10). The
tester notes for that row: "Sample relabeled before customs. Original grade: C."

### The pricing arrangement

```sql
SELECT
  p.supplier_alias,
  p.territory,
  p.price_per_ton,
  p.discount_pct,
  p.loyalty_tier
FROM supplier.pricing p
ORDER BY p.discount_pct DESC
```

The Shanghai territory pays 40% less per ton under `loyalty_tier = 'founding_partner'`.
Every other territory pays full price.

The supply chain root cause is now complete: discounted supplier, relabeled
ingredients, failed quality tests, recalled batches, zero-softness product,
severity-10 incidents, and a person who knew too much who was acquired.

### Detach when done

```vim
:GripDetach supplier
```

The sidebar returns to the original 17 tables.

---

## Updated feature coverage

| Feature | Key | What it did |
|---------|-----|-------------|
| Attach external DB | `:GripAttach` | Connected supplier logistics database to DuckDB session |
| Cross-DB JOIN | Query pad `<C-CR>` | Joined supplier shipments with internal production batches |
| Schema grouping | Sidebar | Showed `supplier` section with 3 tables alongside `main` |
| Detach | `:GripDetach` | Removed external database, sidebar restored |
