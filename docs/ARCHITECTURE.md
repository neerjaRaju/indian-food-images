# Architecture

## The shape of the problem

A nutrition app is mostly a search problem over a medium-sized, slowly-changing
corpus, wrapped in a diary. Three constraints drove every structural decision:

1. **No backend.** There is no server to query, so the corpus must live on the
   device and be searchable there.
2. **APK under 100 MB.** A 15,000-food corpus with photographs cannot fit. So
   the *data* ships and the *pictures* stream.
3. **Data must refresh weekly.** Without a backend, refresh means downloading a
   new file — which has to be safe even when it fails halfway.

Everything below follows from those three.

---

## Two databases, not one

```
app support dir/
  db/indian_food.db        read-only, replaced wholesale by an update
  db/indian_food.db.staged a finished download waiting for the next launch
<databases path>/
  user.db                  diary, favourites, water, weight, plans, rewards
```

Mixing user data into the content database would turn every weekly refresh into
a migration with a real risk of losing someone's diary. Splitting them makes an
update a file rename.

The content database is opened **read-only with no journal**. Nothing writes to
it, so WAL files would be dead weight on device; the builder switches the
artifact to `journal_mode = DELETE` before shipping precisely so it is a single
self-contained file.

### The update dance

```
check GitHub Releases → newer release_date than installed?
  → stream download → gunzip on an isolate → verify SHA-256
  → write to db/indian_food.db.staged
  → (next launch) close db → delete live → rename staged → live
```

The live file is never touched until a complete, checksum-verified copy exists.
A mid-download kill leaves a `.part` file that is ignored and overwritten. A
checksum mismatch discards the download and reports it.

---

## Search

FTS5 with a **standalone** (not external-content) table:

```sql
CREATE VIRTUAL TABLE foods_fts USING fts5(
  name, hindi_name, regional, synonyms, tags, brand,
  tokenize = "unicode61 remove_diacritics 2",
  prefix = "2 3 4"
);
```

Standalone because the searchable blob is not a projection of `foods` — it mixes
JSON-decoded regional names and synonyms that have no column of their own.
`rowid` is kept equal to `foods.id`, so the join back is a direct rowid lookup
rather than an index probe.

`prefix = "2 3 4"` builds prefix indexes so `pan*` is answered from an index
instead of a scan — that is what makes search-as-you-type feel instant on a
budget phone.

Ranking is `bm25(...)` with per-column weights (name 10, hindi 8, regional 6,
synonyms 4, tags 1, brand 3) minus a popularity term, so "roti" returns *Roti*
before *Tandoori Roti (Restaurant Style)*.

### User input never reaches FTS raw

`FoodRepository.buildMatchExpression` splits on anything that is not a letter,
digit or **combining mark** — the mark class matters, because Devanagari matras
are marks and without them `दाल` would be split into `द` and `ल` and never
match. Each token is then double-quoted, which neutralises `NEAR`, `OR`, `-`,
`*` and unbalanced quotes, and the final token gets a prefix star.

---

## State management

Provider, with plain `ChangeNotifier` controllers:

| Controller | Owns |
| --- | --- |
| `FoodSearchController` | query text, filters, paged results, debounce |
| `DiaryController` | the visible day, its entries, water, quick-add |
| `FavoritesController` | favourite ids, recently viewed |
| `PremiumController` | which rewarded unlocks are active and when they expire |
| `DatabaseUpdateService` | update check, download progress, staging |
| `PreferencesService` | profile, goals, theme, hosting choice |

Repositories (`FoodRepository`, `UserRepository`) are plain `Provider` values —
they hold no state, so nothing rebuilds when they are read.

The search debounce is 220 ms. FTS over ~100k rows is fast, but issuing a query
per keystroke still costs frames on a low-end device; 220 ms skips most
intermediate queries while still feeling immediate.

---

## Images

SQLite stores **URLs only** — this is the single decision that keeps the APK
small. Three renditions per food (200/512/1024 WebP) are published to GitHub and
served through jsDelivr.

`ImageHostingService` rewrites stored URLs onto whichever provider is
configured. Because every URL ends in `/<folder>/<slug>.webp`, those two
segments can be re-templated onto any host — so moving the entire catalogue from
jsDelivr to Cloudflare R2 is a one-line JSON edit, not a database rebuild.

`FoodImage` walks a fallback list: active provider first, then the configured
fallbacks, then whatever the database stored. A jsDelivr outage degrades to
GitHub Pages rather than to a screen of grey boxes. Foods without a photo get a
deterministic coloured tile with a class-appropriate emoji, which reads far
better than an empty rectangle.

Caching is `flutter_cache_manager` with a 30-day stale period and 3,000 objects.
Thumbnails are 5–20 KB, so that is a few tens of megabytes at most, and it makes
repeat browsing fully offline.

---

## Monetisation

Rewarded ads unlock a **named feature for a bounded time**, persisted in the
`rewards` table:

```
unlimitedMealPlans  7 days     compareFoods        6 hours
advancedMacros     12 hours    pdfExport           2 hours
nutritionReports   12 hours    advancedFilters     6 hours
smartRecommendations 12 hours  adFreeSession       1 hour
```

`PremiumController.unlock` only grants when `showRewarded()` reports the user
actually earned the reward — dismissing early unlocks nothing. A timer expires
grants without a restart.

The banner lives in the shell, not in each screen, so switching tabs does not
reload it (and does not bill a fresh impression). Interstitials are rate-limited
to one per four minutes and suppressed entirely during an ad-free session.

---

## The builder

A single Python package with one entry point:

```
ifca crawl   → build/interim/records.json
ifca images  → build/images/**, build/dist/image_manifest.json
ifca db      → build/dist/indian_food.db + metadata.json + RELEASE_NOTES.md
ifca bundle  → app/assets/db/indian_food.db.gz
ifca build   → all four
```

Stages are independently runnable so CI can cache between them and a human can
re-run just the part that failed.

**Sources never kill the build.** `Source.run()` catches everything, logs, and
returns what it collected. A rate-limited Open Food Facts or a missing
`FDC_API_KEY` produces a smaller database, not a red X. That is what lets an
unattended Sunday job be trustworthy.

The pipeline order matters:

```
normalize → dedupe → enrich(wikipedia) → micros → validate → normalize
```

Dedupe runs before enrichment so we do not spend Wikipedia calls on rows that
are about to merge. `micros` runs before `validate` so that filled values are
bounds-checked like measured ones. `normalize` runs again at the end because
merging can produce duplicate slugs.

---

## Why these choices and not the obvious alternatives

**Why not Drift/Floor instead of raw sqflite?** The content database is
generated by Python, not by Dart migrations. A code-generated ORM would model a
schema it does not own, and the win — type-safe queries — is small when there
are ~15 queries total, all in one repository class.

**Why not bundle images at low resolution?** 15,000 thumbnails at 15 KB is
225 MB before the medium and large sizes. It breaks the APK budget on its own.

**Why FTS5 rather than LIKE?** `LIKE '%paneer%'` cannot use an index and scans
every row on every keystroke. At 100k rows on a low-end phone that is visible
lag.

**Why a rules engine for variants instead of hand-writing them?** Because
"Paneer Butter Masala without cream" has to be *findable*, and hand-authoring
six variants for each of 330 dishes is 2,000 rows of manual data entry that
would drift out of sync with the base the moment a base value is corrected.
