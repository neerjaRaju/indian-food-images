# Image pipeline

**Zero image bytes ship in the APK.** SQLite stores three URLs per food; the
bytes live on a CDN and are cached on device after first view.

## Flow

```
for each food (variants inherit their base dish's image):
  1. gather candidates   OFF image tag → Wikipedia lead image → Commons search
  2. reject by licence   accept CC0 / CC BY / CC BY-SA / public domain only
  3. download            polite, throttled, disk-cached
  4. reject corrupt      PIL open+load; decompression-bomb guard at 80 MP
  5. reject small        shorter edge < 300 px
  6. pHash               reject if within Hamming distance 6 of an existing image
  7. square crop         EXIF-corrected, centred horizontally, 42 % from the top
  8. encode WebP ×3      200 / 512 / 1024, quality stepped down to hit budgets
  9. upload              GitHub Release assets + committed images/foods tree
 10. mint URLs           from the active provider template
 11. manifest            slug, three URLs, phash, credit, licence, byte sizes
 12. verify              HEAD (or ranged GET) every URL; prune failures
```

Steps 11–12 matter more than they look: pruning unreachable URLs before the
database is written is what guarantees the app never renders a broken image.

## Why these specific choices

**Licence filter first, not last.** Downloading then discarding wastes
bandwidth and, worse, tempts a future maintainer to "just use" a file already on
disk. The regex accepts CC0/CC BY/CC BY-SA/public-domain and explicitly rejects
anything with NC, ND or "fair use".

**Perceptual hash, not file hash.** The same dish photo appears on Commons at
several resolutions with different bytes. pHash catches those; MD5 would not.
The index buckets on the first 16 bits and probes neighbouring buckets, which
keeps the comparison sub-linear without missing matches that a strict bucket
would drop.

**42 % from the top, not centre.** Food photographs are usually shot with the
plate slightly below centre and headroom above. A true centre crop shaves the
bottom of the dish; biasing the crop upward keeps the food.

**Quality stepping, not fixed quality.** A busy thali at quality 80 blows past
20 KB while a plain dal sails under it. The encoder retries at −8 quality until
the rendition fits its budget or hits a floor of 40, so budgets hold across very
different images without over-compressing simple ones.

**Two upload layouts.** Release assets are `medium_butter_chicken.webp` (flat —
releases have no directories); the committed tree is
`images/foods/medium/butter_chicken.webp` (what jsDelivr serves). Publishing
both means either delivery path works from the same run.

## Budgets

| Rendition | Size | Target bytes | Observed on a real run |
| --- | --- | --- | --- |
| thumbnail | 200×200 | 10–20 KB | 5–13 KB |
| medium | 512×512 | 20–50 KB | 22–48 KB |
| large | 1024×1024 | 50–120 KB | 64–133 KB |

At 15,000 foods that is roughly 300–700 MB published — and 0 MB in the APK.

## Hosting

`builder/hosting.yaml` (builder side) and
`app/assets/config/image_hosting.json` (app side) both describe the same
providers. Nine are preconfigured: jsDelivr, GitHub Releases, GitHub Pages,
Cloudflare R2, Cloudflare CDN, Netlify, Vercel, Firebase Hosting, and any HTTPS
static host.

### Switching providers

Because every stored URL ends in `/<folder>/<slug>.webp`, the app captures those
two segments and re-templates them onto the chosen provider. Consequences:

- Changing host **does not require rebuilding the database**.
- The app can even change host at runtime (Settings → Image host).
- The fallback chain is tried in order on error, per image.

```jsonc
// app/assets/config/image_hosting.json
"active": "jsdelivr",
"fallbackOrder": ["jsdelivr", "github_pages", "github_releases"]
```

On the builder side, set the provider once:

```bash
export IFCA_HOSTING_PROVIDER=cloudflare_r2
export IFCA_IMAGE_OWNER=my-org
export IFCA_IMAGE_REPO=indian-food-images
python -m ifca images --upload
```

### jsDelivr notes

- `@latest` resolves to the newest git tag; a fresh push takes a few minutes to
  propagate, which is why the verify job sleeps 120 s before checking.
- Pin a tag (`@v3`) instead of `@latest` if you want the app frozen to a known
  image set.
- jsDelivr caches aggressively. Publishing a *changed* image under the same
  slug can serve stale bytes for up to 24 h; publish under a new slug when the
  photo genuinely changes.

## Attribution is not optional

Every asset carries `credit`, `license`, `license_url` and `source_url` from
crawl through manifest into the `foods` table, and `ImageCreditLine` renders it
under the hero image. CC BY and CC BY-SA both *require* this. Stripping it makes
distribution unlawful, not merely impolite.

## Running it

```bash
# small live test
python -m ifca images --image-limit 20

# full run, publish, verify
export GITHUB_TOKEN=ghp_...
export IFCA_IMAGE_OWNER=my-org IFCA_IMAGE_REPO=indian-food-images
python -m ifca images --upload --verify-urls

# re-check published URLs later
python -m ifca verify --strict
```

`build/images/` is cached in CI, so weekly runs only process foods that do not
already have a rendition.
