# Database reference

Everything below describes `indian_food.db`, the read-only content database the
app ships and the weekly job replaces. User data lives in a separate `user.db`
whose schema is in `app/lib/data/db/user_database.dart`.

## Build settings

| Setting | Value | Why |
| --- | --- | --- |
| `page_size` | 4096 | Matches the Android filesystem block size |
| `journal_mode` (build) | WAL | Fast bulk insert |
| `journal_mode` (shipped) | DELETE | The artifact must be one self-contained file |
| `synchronous` (build) | OFF | The file is disposable until it is verified |
| Final steps | `INSERT INTO foods_fts('optimize')`, `ANALYZE`, `VACUUM` | Merges FTS b-trees, writes `sqlite_stat1` so the planner picks the right index, removes free pages |

Bump `SCHEMA_VERSION` in `builder/ifca/config.py` whenever `schema.sql` changes
shape. The app reads it from `meta` and can refuse an incompatible download.

---

## Tables

### `foods`

The main row. Nutrition is always **per 100 g** (or per 100 ml for liquids);
portions are applied at read time.

| Group | Columns |
| --- | --- |
| Identity | `id`, `slug` (unique), `name`, `hindi_name`, `regional_names` (JSON), `synonyms` (JSON), `description` |
| Classification | `category_id`, `food_type` (`food`/`recipe`/`packaged`/`restaurant`), `diet` (`veg`/`vegan`/`egg`/`nonveg`), `is_vegan`, `is_jain`, `region`, `food_class`, `tags` |
| Commerce | `barcode`, `brand`, `restaurant` |
| Nutrition | `calories`, `protein_g`, `carbs_g`, `fat_g`, `saturated_fat_g`, `fiber_g`, `sugar_g`, `sodium_mg`, `potassium_mg`, `calcium_mg`, `iron_mg`, `magnesium_mg`, `vitamin_a_mcg`, `vitamin_c_mg`, `vitamin_d_mcg`, `vitamin_b12_mcg`, `cholesterol_mg` |
| Images | `thumbnail_url`, `image_url`, `large_url`, `image_source`, `image_credit`, `license`, `license_url` |
| Provenance | `source`, `source_url`, `confidence`, `micros_estimated`, `completeness`, `popularity`, `last_updated` |

`food_class` is the coarse kind of food (`grain`, `legume`, `dairy`, `meat`,
`sweet`, `beverage`, …). It drives micronutrient estimation, serving templates,
placeholder emoji and the "lighter swaps" query — a swap only makes sense
between foods of the same class.

`micros_estimated = 1` means at least one micronutrient came from a food-class
profile rather than a source table. The app labels these rows.

### `servings`

One row per portion a food supports; always includes `100g` and `custom`, plus
whatever units make sense for the class. `grams` for the `custom` row is `1` —
it is a multiplier, not a portion.

### `categories` / `food_categories`

31 canonical categories in three kinds (`cuisine`, `diet`, `course`, `source`).
A food has one primary `category_id` and many `food_categories` links, derived
at build time from diet flags, tags and name heuristics — so *Palak Paneer*
appears under Punjabi, Vegetarian and Dairy without duplicating the row.

### `recipes`

`ingredients` and `steps` as JSON arrays, plus prep/cook minutes. Present only
for `food_type = 'recipe'`.

### `alternatives`

Precomputed lighter swaps: same `food_class`, at most 78 % of the calories, at
least 70 % of the protein, ranked by calorie saving then popularity, capped at
four per food. Computing this at build time means the app never scans at
runtime.

### `foods_fts`

See [ARCHITECTURE.md](ARCHITECTURE.md#search).

### `meta`

Key/value: `schema_version`, `generated_at`, `database_date`, `counts` (JSON),
`pipeline_stats` (JSON), `attribution` (JSON).

---

## Indexes

```sql
idx_foods_category, idx_foods_type, idx_foods_diet
idx_foods_class      (food_class, calories)      -- alternatives + class browse
idx_foods_calories, idx_foods_protein
idx_foods_popularity (popularity DESC, id)       -- default ordering
idx_foods_name_nocase
idx_foods_barcode    UNIQUE WHERE barcode <> ''  -- partial: only real barcodes
idx_servings_food    (food_id, sort_order)
idx_foodcat_category (category_id, food_id)
idx_alt_food         (food_id, rank)
idx_foods_browse     (category_id, popularity DESC, id, name, calories, thumbnail_url)
```

`idx_foods_browse` is a **covering** index: the category list screen reads
everything it needs from the index without touching the table. `idx_foods_barcode`
is partial so the thousands of rows with no barcode do not collide on `''`.

---

## Query cookbook

**Search, ranked, with filters**

```sql
SELECT f.*, c.name AS category_name
FROM foods_fts
JOIN foods f ON f.id = foods_fts.rowid
JOIN categories c ON c.id = f.category_id
WHERE foods_fts MATCH ?              -- '"paneer" AND "butt"*'
  AND f.diet = ?
ORDER BY bm25(foods_fts, 10.0, 8.0, 6.0, 4.0, 1.0, 3.0) - (f.popularity / 20.0)
LIMIT 40 OFFSET 0;
```

**Barcode lookup** — one index probe:

```sql
SELECT * FROM foods WHERE barcode = ? LIMIT 1;
```

**A food's portions**

```sql
SELECT unit, label, grams, is_default
FROM servings WHERE food_id = ? ORDER BY sort_order;
```

**Lighter swaps**

```sql
SELECT f.*, a.reason, a.kcal_delta
FROM alternatives a
JOIN foods f ON f.id = a.alt_food_id
WHERE a.food_id = ? ORDER BY a.rank LIMIT 4;
```

**Category browse** (served entirely from `idx_foods_browse`)

```sql
SELECT f.id, f.name, f.calories, f.thumbnail_url
FROM foods f
JOIN food_categories fc ON fc.food_id = f.id
WHERE fc.category_id = ?
ORDER BY f.popularity DESC, f.name COLLATE NOCASE
LIMIT 40 OFFSET ?;
```

---

## Data quality rules enforced at build time

| Rule | Action on violation |
| --- | --- |
| Every nutrient within its plausible envelope | Clamped, counted in the report |
| `protein + carbs + fat ≤ 100 g` per 100 g | Macros rescaled proportionally |
| `saturated_fat ≤ fat`, `sugar ≤ carbs`, `fiber ≤ carbs` | Capped |
| Calories within 35 % of Atwater (`4/4/9`) | Recomputed from macros |
| No usable energy signal | Row dropped |
| Vegetarian rows carrying cholesterol (non-dairy) | Zeroed |
| Vegan rows carrying B12 | Capped at 0.1 µg |

The counts land in `meta.pipeline_stats`, and the same invariants are asserted
from the Flutter side in `app/test/database_integration_test.dart` — so a
regression in the Python fails the Dart build.

---

## Size

The current offline build is **2.8 MB** for 1,830 foods, ~1.5 KB per row. The
brief's 60–120 MB target assumes a 15,000+ corpus with long descriptions;
extrapolating, 15,000 foods with Wikipedia intros lands around 30–60 MB, and the
gzipped asset roughly a third of that. The CI budget check enforces the ceiling
that actually matters — the 100 MB APK.
