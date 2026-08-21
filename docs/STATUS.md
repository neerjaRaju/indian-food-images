# Status: what is real, what is scaffolded

The brief asked for a 15,000+ food corpus. This document is an honest map of
where the delivered system stands against that, so nobody is surprised at
release time.

## Built and verified

| Component | State | Evidence |
| --- | --- | --- |
| Flutter Android app | Complete — 20 screens, all listed features | `flutter analyze --fatal-infos` clean, 41 tests pass |
| SQLite schema + FTS5 + indexes | Complete | 11 integrity tests run against the real built file |
| Builder pipeline (all 20 steps) | Complete | 29 unit tests, end-to-end build runs in ~15 s offline |
| Image pipeline | Complete and exercised | Real Wikimedia downloads → pHash dedupe → 3 WebP renditions inside byte budgets |
| GitHub Actions (weekly + CI + release) | Written, not yet run in anger | Needs a repository and secrets to execute |
| Offline-first behaviour | Complete | DB inflated from a gzipped asset, staged updates, atomic swap |
| AdMob + rewarded unlocks | Complete, wired to Google test IDs | Replace IDs before publishing |

## The corpus gap

The shipped build produces **1,830 foods** (331 of them recipes) from:

- ~330 curated Indian dishes with researched per-100 g values
- ~1,150 rule-derived variants ("Low Oil", "Restaurant Style", "Jain", …), each
  labelled and confidence-reduced
- ~330 recipes whose nutrition is computed bottom-up from an 80-ingredient
  reference table and cooked yield

That is a genuinely useful database, and every row is defensible. It is not
15,000. Reaching that number needs volume the pipeline is built to ingest but
cannot fabricate:

| Gap | Target | How the existing pipeline closes it |
| --- | --- | --- |
| Packaged foods | 2,000+ | `OpenFoodFactsSource` already paginates the India-filtered API. Run `python -m ifca build` with network access — a single full run typically yields several thousand Indian products with barcodes. In CI this is the `--off-limit 6000` step. |
| Reference ingredients | ~700 | `UsdaSource` needs only `FDC_API_KEY` (free, instant). It also feeds the micronutrient donor pool, which upgrades estimated micros to measured ones. |
| Recipes | 5,000+ | Drop additional `*.psv` corpora into `builder/data/recipes.d/`. The loader picks them up with no code change, and `RecipeVariantSource` multiplies each by five dietary swaps. A 1,000-recipe corpus becomes ~6,000 rows. |
| Restaurant foods | 500+ | Not yet sourced. The schema has `restaurant` and `food_type='restaurant'`; a source module following `sources/base.py` is the only missing piece. Menu nutrition disclosures are the practical origin. |
| Regional / street / festival depth | — | The curated table covers all 12 named cuisines but shallowly. This is manual nutrition work; the PSV format is designed so a domain expert can extend it without touching Python. |

**Bottom line:** the ceiling is data acquisition, not engineering. Every
ingestion path exists, is tested, and degrades gracefully when a source is
unavailable.

## Images

Ten dishes were processed end-to-end as a live test — Wikimedia Commons →
licence filter → square crop → WebP at 200/512/1024. Sizes landed at 5–13 KB,
22–48 KB and 64–133 KB, inside the targets. A full run over the catalogue is a
matter of CI minutes, not code.

Nothing was uploaded, because that needs a repository and a token. The URLs
currently in the manifest point at `CHANGE_ME` — see
[DEPLOYMENT.md](DEPLOYMENT.md) step 2.

## Known limitations

1. **Micronutrients are partly estimated.** Indian composition tables publish
   energy and macros for most cooked dishes but micronutrients for few. Rows
   where a value was filled from a food-class profile set `micros_estimated = 1`
   and say so on screen. Importing USDA donors reduces this; it does not
   eliminate it.
2. **Variant nutrition is derived, not measured.** A "with Ghee" row applies a
   documented, auditable delta to its base and lowers its confidence score. It
   is labelled in the description.
3. **The APK was never built on real hardware here.** No Android SDK was
   available in the build environment, so `flutter build apk` has not run.
   Analysis, tests and dependency resolution all pass. The 100 MB budget check
   is wired into CI and will be the first real signal.
4. **Ad units are Google's public test IDs.** Shipping them to production
   violates AdMob policy and earns nothing.
5. **Barcode coverage depends entirely on Open Food Facts.** Indian coverage
   there is improving but patchy; the scanner tells the user plainly when a code
   is not in the database rather than pretending.

## Suggested order of work from here

1. Create the two GitHub repositories and set secrets → run the weekly workflow
   once by hand (`workflow_dispatch`, `dry_run: true`).
2. Get an `FDC_API_KEY` and run a full networked build — this alone roughly
   triples the corpus and upgrades micronutrients.
3. Let the image job run unlimited once; expect 300–700 MB published and 0 MB
   added to the APK.
4. Extend `data/recipes.psv` (or add corpora under `data/recipes.d/`) toward the
   recipe target.
5. Replace AdMob IDs, generate an upload keystore, build the AAB, submit.
