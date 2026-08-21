# Indian Food Calories

An offline-first Android app for Indian food calories and nutrition, plus the
automated pipeline that builds its database and publishes its images.

The whole product runs at **zero monthly hosting cost**: the food database ships
inside the APK, photographs are served from GitHub + jsDelivr, and there is no
backend, no login and no server to pay for.

```
indian_food_app/
├── app/          Flutter Android application
├── builder/      Python pipeline: crawl → normalise → images → SQLite
├── docs/         Architecture, database, deployment, data sources
└── .github/      CI, weekly database refresh, release automation
```

---

## Quick start

### 1. Build a database

```bash
cd builder
pip3 install -r requirements.txt
python3 -m ifca build --offline --skip-images
export FDC_API_KEY=V5ddudSVLtXrqAWofkdtfX0tgIEGbhzooss9ve0l
python3 -m ifca build
```

The database lands in `builder/build/dist/indian_food.db` and a gzipped copy is
placed in `app/assets/db/` for the Flutter build.

### 2. Run the app

```bash
cd app
flutter pub get
flutter run
```

### 3. Ship it

```bash
flutter build apk --release --split-per-abi
# or, for Play:
flutter build appbundle --release
```

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for signing, AdMob IDs, the image
repository and the weekly automation.

---

## What the app does

**Find food.** FTS5 full-text search over English names, Hindi names, regional
names in eleven scripts, synonyms, tags and brands — with prefix matching so
results appear while you type. Voice search (Hindi-first) and a barcode scanner
resolve packaged products entirely offline.

**Understand it.** Every food carries all seventeen required nutrients, a
per-100 g baseline and real Indian portions — roti, chapati, idli, dosa,
paratha, katori, cup, glass, plate, piece or custom grams. The detail screen
shows %RDA against ICMR reference intakes, a macro split by calories, lighter
swaps precomputed at build time, and full provenance for the numbers.

**Track it.** Diary with four meal slots, calorie ring, water, weight with a
trend chart, and a weekly report.

**Plan it.** BMI, BMR, TDEE, macro and protein calculators, weight loss and
weight gain planners with safety floors, and a meal planner that builds a week
around your calorie target.

**Pay nothing.** Monetisation is AdMob only: a banner in the shell, a rate-limited
interstitial, and rewarded ads that unlock a feature for a bounded time. No
subscriptions, no in-app purchases, no account.

---

## How the pieces fit

```
┌──────────────── builder (Python, runs in CI) ────────────────┐
│  sources/          pipeline/           imaging/       db/     │
│  curated  ─┐       normalize           crawl          schema  │
│  recipes  ─┤       dedupe        ┌──►  pHash dedupe   FTS5    │
│  usda     ─┼──►    validate  ────┤     square crop    indexes │
│  off      ─┤       micros        │     WebP ×3        VACUUM  │
│  wikipedia─┘                     └──►  upload → CDN           │
└──────────────────────────┬────────────────────────────────────┘
                           │  indian_food.db.gz + image_manifest.json
                           ▼
              GitHub Release  ──jsDelivr──►  images
                           │
                           ▼
┌──────────────── app (Flutter, on device) ────────────────────┐
│  indian_food.db  (read-only, inflated on first launch)        │
│  user.db         (diary, favourites, water, weight, plans)    │
│  cached_network_image → CDN, cached 30 days offline           │
└───────────────────────────────────────────────────────────────┘
```

Two databases, deliberately. The content database is replaced wholesale by the
weekly update; the user database is never touched. That is what makes a refresh
a single atomic file swap instead of a migration.

---

## Automation

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `weekly-database.yml` | Sundays 02:00 UTC | Re-crawls sources, refreshes images, rebuilds SQLite, verifies every published URL, publishes a GitHub Release |
| `ci.yml` | push / PR | Ruff + pytest, `flutter analyze --fatal-infos`, `flutter test`, debug APK, and a hard 100 MB release-APK budget |
| `release-app.yml` | `v*` tag | Pulls the newest published database, builds signed split APKs and an AAB |

The app checks that release feed every few days, downloads the gzipped
database, verifies its SHA-256, and stages it for the next launch. A failed or
corrupt download is discarded without touching the working copy.

---

## Verification

```bash
cd builder && ruff check ifca tests && python -m pytest tests -q   # 29 tests
cd app     && flutter analyze --fatal-infos && flutter test        # 41 tests
```

The Flutter suite includes eleven integrity tests that run against the *real*
built database through sqlite FFI: Atwater consistency, no negative nutrients,
macro mass ≤ 100 g per 100 g, unique barcodes, no orphan FTS rows, every food
reachable from a category, and every image URL https + `.webp`.

---

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the app and pipeline are put together, and why
- [docs/DATABASE.md](docs/DATABASE.md) — schema, indexes, FTS design, query cookbook
- [docs/IMAGE_PIPELINE.md](docs/IMAGE_PIPELINE.md) — crawling, deduplication, renditions, hosting, switching providers
- [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) — where every number comes from and what each licence requires
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — first-time setup, secrets, signing, Play submission
- [docs/STATUS.md](docs/STATUS.md) — what is built, what is scaffolded, and what a full-scale corpus still needs

---

## Licence and attribution

Code in this repository is yours to license as you wish. The **data is not**:

- Open Food Facts product data is **ODbL 1.0** — share-alike applies to derived databases
- Wikipedia text is **CC BY-SA 4.0** — attribution and share-alike
- Wikimedia Commons photographs carry per-file licences (CC0 / CC BY / CC BY-SA)
- USDA FoodData Central is public domain

The database stores the credit, licence and source URL for every image and every
description, and the app displays them. Do not strip that plumbing — it is what
makes shipping this data lawful. [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md)
has the details.
