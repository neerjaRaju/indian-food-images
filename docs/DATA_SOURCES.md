# Data sources, licences and attribution

Nutrition data is not free-floating fact — most of it arrives under a licence
with obligations. This document records what comes from where and what each
licence requires, because getting it wrong is the kind of mistake that surfaces
after launch.

---

## Nutrition

| Source | Used for | Licence | Obligation |
| --- | --- | --- | --- |
| **IFCT 2017** (National Institute of Nutrition / ICMR) | Reference values for Indian foods and cooked dishes; the basis of the curated table | Published tables; values are facts, the *compilation* is the publisher's | Cite the source. Do not redistribute the PDF or a verbatim copy of the tables. |
| **USDA FoodData Central** | Micronutrient panels for shared ingredients; donor pool for gap-filling | Public domain (CC0) | None. Attribution is courtesy. |
| **Open Food Facts** | Packaged products, barcodes, brands | **ODbL 1.0** | Attribution, share-alike **on the derived database**, and keep it open. See below. |
| **FSSAI / government datasets** | Labelling rules, packaged-food conventions | Government publications | Cite. |
| **Computed recipes** | Recipes, from an ingredient table and cooked yield | Ours | None. |

### The ODbL obligation — read this one

Open Food Facts is licensed **ODbL 1.0**, which is share-alike *for databases*.
Practically:

1. **Attribute** — the About screen names Open Food Facts; each imported row
   keeps `source = 'OpenFoodFacts'` and its product URL.
2. **Share alike** — a database that includes OFF data and is publicly
   distributed must itself be offered under ODbL. Publishing
   `indian_food.db.gz` on a public GitHub release satisfies this, provided the
   release notes say so. `RELEASE_NOTES.md` does.
3. **Keep open** — you may not add DRM that prevents someone exercising those
   rights.

The *app* can be any licence you like; the *database* is the encumbered part.
If you would rather not carry ODbL at all, build with the OFF source disabled —
you lose barcode lookup and packaged products, and nothing else.

---

## Text

| Source | Used for | Licence | Obligation |
| --- | --- | --- | --- |
| **Wikipedia** | Dish descriptions, regional names via Wikidata | **CC BY-SA 4.0** | Attribution + share-alike on the text |

Rows enriched from Wikipedia carry the `wiki-desc` tag during the build and keep
the article URL in `source_url`. Descriptions are truncated to ~700 characters —
a short quotation with attribution and a link back, which is what CC BY-SA
expects.

---

## Images

| Source | Licences accepted | Obligation |
| --- | --- | --- |
| **Wikimedia Commons** | CC0, public domain, CC BY, CC BY-SA | Per-file credit and licence name |
| **Open Food Facts** | CC BY-SA 3.0 | Credit "Open Food Facts contributors" |

Explicitly **rejected**: anything matching NonCommercial, NoDerivatives, or
"fair use". An ad-supported app is a commercial use, so NC licences are not
usable here regardless of intent.

Every published image carries `credit`, `license`, `license_url` and
`source_url` from crawl through the manifest into the `foods` table, and
`ImageCreditLine` renders it under the hero image on the food page. This is not
decoration — CC BY and CC BY-SA require it.

For CC BY-SA images specifically: the licence covers the image, not your app.
Cropping and re-encoding to WebP produces an adapted work, which must stay under
the same licence — which it does, since the credit line names it and the image
is redistributed unchanged in substance.

---

## What the app tells the user

The About screen lists every source with a link, states plainly that cooked-dish
values are representative averages rather than lab results, explains that some
micronutrients are estimated from a food-class profile, and says the app is not
medical advice.

Individual food pages show:

- the source name and a link to it
- the photo credit and licence
- a note when micronutrients were estimated
- a note when the row is a rule-derived variant

Nothing about the data's provenance is hidden from the person using it.

---

## Adding a new source

1. Subclass `Source` in `builder/ifca/sources/`.
2. Set `key`, `display_name`, `license_note`.
3. Yield `FoodRecord`s with `source`, `source_url` and an honest `confidence`.
4. Let failures raise — `Source.run()` catches, logs, and returns partial
   results so one dead API cannot fail the weekly job.
5. Register it in `cli.stage_crawl`.
6. Add the licence to this file, to `db/builder._write_meta`, and to the About
   screen.

Step 6 is not optional. A source whose licence is undocumented is a source
nobody can safely ship.
