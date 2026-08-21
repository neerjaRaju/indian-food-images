# Deployment

From an empty GitHub account to a Play-ready build. Everything here stays inside
free tiers.

---

## 1. Repositories

Two repos, both public (jsDelivr only serves public repos):

| Repo | Holds |
| --- | --- |
| `indian-food-app` | this codebase; publishes database releases |
| `indian-food-images` | `images/foods/{thumbnails,medium,large}/*.webp` and the image release |

Keeping images separate keeps the code repo cloneable in seconds and lets the
image repo grow to hundreds of megabytes without punishing contributors.

```bash
gh repo create indian-food-app --public --source=. --push
gh repo create indian-food-images --public --clone
```

---

## 2. Point the config at your repos

Three places, all one-liners:

```yaml
# builder/hosting.yaml
active: jsdelivr
providers:
  jsdelivr:
    owner: YOUR_GITHUB_USERNAME
    repo: indian-food-images
```

```jsonc
// app/assets/config/image_hosting.json
"providers": { "jsdelivr": { "owner": "YOUR_GITHUB_USERNAME", ... } },
"updateFeed": { "owner": "YOUR_GITHUB_USERNAME", "repo": "indian-food-app" }
```

CI overrides both with `IFCA_IMAGE_OWNER` / `IFCA_IMAGE_REPO`, so the committed
values only matter for local runs and for the app.

> Until `updateFeed.owner` is set, the in-app update check exits immediately and
> silently. That is deliberate — a fresh clone should not hammer a placeholder.

---

## 3. Secrets and variables

**Repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Needed for | How to get it |
| --- | --- | --- |
| `FDC_API_KEY` | USDA import and micronutrient donors | Free, instant: <https://fdc.nal.usda.gov/api-key-signup.html> |
| `IMAGES_TOKEN` | Pushing to the images repo | Fine-grained PAT with **Contents: Read and write** on `indian-food-images` |
| `KEYSTORE_BASE64` | Signed releases | `base64 -w0 upload-keystore.jks` |
| `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD` | Signed releases | From keystore creation |
| `ADMOB_BANNER`, `ADMOB_INTERSTITIAL`, `ADMOB_REWARDED`, `ADMOB_NATIVE` | Live ads | AdMob console |

**Repository variable:** `IMAGES_REPO` if your image repo is not named
`indian-food-images`.

Without `FDC_API_KEY` the USDA source logs a warning and yields nothing; without
the keystore the release build signs with debug keys.

`IMAGES_TOKEN` is the one that is **not** optional for a publishing run.
`GITHUB_TOKEN` is a GitHub App installation token: it is scoped to the
repository the workflow runs in, and it has no access to the separate images
repository at all. Calls to it come back as

```
HTTP 403: API rate limit exceeded for installation
```

which reads like throttling but means "not installed here". The weekly workflow
now checks `IMAGES_TOKEN` in one request before crawling anything, so a missing
or under-scoped token fails in ten seconds instead of five hours in.

Even with the right token there is a budget: 5,000 requests/hour for a PAT
against 1,000/hour for an installation token, plus a secondary limit on bursts
of uploads. The uploader reads `Retry-After` and `x-ratelimit-reset` and waits
those windows out rather than failing the run — a slow publish is recoverable, a
half-published image release is not.

### When the upload 403s

The releases API needs **Contents: Read and write**. Not Administration, and
Read-only is not enough — creating a release and uploading an asset are both
writes. In order of how often it is the answer:

1. The fine-grained PAT has `Contents: Read-only`. Change it to Read and write.
2. The token's **Repository access** does not actually list the images repo.
3. The repository owner is an organisation and the token is still awaiting
   owner approval, so it behaves as if it has nothing.
4. The value in `IMAGES_TOKEN` is a `GITHUB_TOKEN`, which cannot reach any
   repository other than the one its workflow runs in.

The preflight step only proves the repo is *reachable*. It deliberately does
not fail on the `permissions.push` field the API reports: GitHub has no
supported way to introspect a fine-grained PAT's grants, that field predates
them, and it can read `false` for a token that really does hold Contents:
write. Blocking a correct run on an unreliable signal is worse than letting the
first real write decide — which it does, within seconds, with the list above in
the error.

---

## 4. AdMob

1. Create an AdMob app for the Android package `com.zrix.indian_food_calories`.
2. Create four ad units: banner, interstitial, rewarded, native.
3. Put the **app ID** in `AndroidManifest.xml`:

```xml
<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"
           android:value="ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"/>
```

4. Put the **unit IDs** in the release secrets. They reach the app through
   `--dart-define`, and `AdUnits` only uses them in release builds — debug always
   uses Google's test IDs so you never click your own live ads.

⚠️ The manifest currently contains Google's public sample app ID. Shipping it
violates AdMob policy and earns nothing.

---

## 5. Signing

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload

cp app/android/key.properties app/android/key.properties
# fill in the four values; the file is git-ignored
```

Back the keystore up somewhere you will still have in five years. Losing it
means you can never update the app on Play under the same listing (unless Play
App Signing is enabled, which you should also turn on).

---

## 6. First database build

Run the weekly workflow by hand first:

```
Actions → Weekly database & image refresh → Run workflow
  skip_images: true
  dry_run: true
```

That proves the crawl and build work in CI without publishing anything. Then run
it for real:

```
Actions → Weekly database & image refresh → Run workflow
  image_limit: 200      # sanity-check the image path on a small set first
  dry_run: false
```

Check the job summary, then run once more with no limit. After that, the Sunday
cron takes over.

---

## 7. App release

```bash
git tag v1.0.0 && git push origin v1.0.0
```

`release-app.yml` downloads the newest published database, builds split APKs and
an AAB, enforces the size budget, and attaches everything to the GitHub release.

For Play:

1. Upload the `.aab`.
2. Data safety form: the app collects **no** personal data, stores everything
   locally, and shows ads. Declare the AdMob advertising ID.
3. Health disclaimer: describe it as a reference and tracking tool, not medical
   advice. The About screen already carries that wording — mirror it in the
   listing so review does not flag a mismatch.
4. Content rating: Everyone.
5. Target audience: not children.

---

## 8. Local development

```bash
# database
cd builder && pip install -r requirements.txt
python -m ifca build --offline --skip-images     # ~15 s, no network

# app
cd app && flutter pub get && flutter run

# before pushing
cd builder && ruff check ifca tests && python -m pytest tests -q
cd app && dart format lib test && flutter analyze --fatal-infos && flutter test
```

---

## Troubleshooting

**"The food database could not be opened" on first launch.** The gzipped asset
is inflated into app support storage on first run. On a device with almost no
free space that write fails. Free space and relaunch.

**Images are all placeholders.** Either the database was built with
`--skip-images`, or `owner` is still `CHANGE_ME`. Check
`SELECT thumbnail_url FROM foods WHERE thumbnail_url <> '' LIMIT 1`.

**jsDelivr 404s right after a publish.** `@latest` resolves through the newest
git tag and takes a few minutes to propagate. The verify job sleeps 120 s for
exactly this reason; wait, or pin an explicit tag.

**The weekly job publishes a suspiciously small database.** It should not — the
job refuses to publish below 500 foods or above 150 MB. If it fails there, a
source is down; the artifact is still uploaded so you can inspect it.

**Rewarded ads never load.** In debug you should get Google's test ad. If not,
check that `MobileAds.instance.initialize()` succeeded — `AdsService` logs and
continues without ads rather than crashing, so the app will look normal while
every ad slot renders nothing.
