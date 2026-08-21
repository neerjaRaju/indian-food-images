"""``python -m ifca`` — the one entry point CI and humans both use.

    ifca build            # full pipeline: crawl -> images -> db -> release assets
    ifca crawl            # data only, writes interim/records.json
    ifca images           # discover/process/upload images for existing records
    ifca db               # build the SQLite file from interim records
    ifca verify           # re-check every published image URL
    ifca stats            # print what is in the current database
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import shutil
import sqlite3
import sys
from pathlib import Path

from . import config
from .config import (
    DB_PATH,
    DIST_DIR,
    INTERIM_DIR,
    MANIFEST_PATH,
    METADATA_PATH,
    HostingConfig,
    write_default_hosting,
)
from .db.builder import DatabaseBuilder
from .imaging.crawler import ImageCrawler, strip_image_tags
from .imaging.manifest import build_manifest, prune_missing, verify_urls, write_manifest
from .imaging.processor import ImageProcessor
from .imaging.uploader import GitHubReleaseUploader, GitRepoPublisher, assign_urls
from .models import FoodRecord
from .pipeline import dedupe as dedupe_mod
from .pipeline import micros as micros_mod
from .pipeline import normalize as normalize_mod
from .pipeline import validate as validate_mod
from .sources.curated import CuratedIndianSource, CuratedVariantSource
from .sources.openfoodfacts import OpenFoodFactsSource
from .sources.recipes import RecipeSource, RecipeVariantSource
from .sources.usda import UsdaSource
from .sources.wikipedia import WikipediaEnricher
from .util import log

_log = log.get("ifca.cli")

RECORDS_FILE = INTERIM_DIR / "records.json"
ASSETS_FILE = INTERIM_DIR / "assets.json"


# --------------------------------------------------------------------------- #
# Stages
# --------------------------------------------------------------------------- #
def stage_crawl(args: argparse.Namespace) -> list[FoodRecord]:
    records: list[FoodRecord] = []
    records += CuratedIndianSource().run()
    records += RecipeSource().run()
    if not args.no_variants:
        records += CuratedVariantSource(max_per_base=args.variants_per_base).run()
        records += RecipeVariantSource().run()
    if args.network:
        records += UsdaSource(limit=args.usda_limit).run()
        records += OpenFoodFactsSource(limit=args.off_limit, dump_path=args.off_dump).run()

    records = normalize_mod.normalize(records)
    records, dedupe_stats = dedupe_mod.dedupe(records)

    if args.network and not args.no_wiki:
        records = WikipediaEnricher().enrich(records)

    donors: dict[str, object] = {}
    if args.network and os.environ.get("FDC_API_KEY"):
        try:
            donors = UsdaSource(limit=200).donor_pool()
        except Exception as exc:  # noqa: BLE001
            _log.warning("Donor pool unavailable: %s", exc)
    records = micros_mod.complete(records, donors)  # type: ignore[arg-type]
    records, report = validate_mod.validate(records)
    records = normalize_mod.normalize(records)

    stats = {"dedupe": dedupe_stats, "validation": report.as_dict()}
    _write_records(records, stats)
    _log.info("Crawl stage complete: %d records", len(records))
    return records


def _write_records(records: list[FoodRecord], stats: dict) -> None:
    RECORDS_FILE.parent.mkdir(parents=True, exist_ok=True)
    RECORDS_FILE.write_text(json.dumps(
        {"stats": stats, "records": [r.to_json() for r in records]},
        ensure_ascii=False), encoding="utf-8")


def _read_records() -> tuple[list[FoodRecord], dict]:
    if not RECORDS_FILE.exists():
        raise SystemExit("No interim records — run `ifca crawl` first.")
    payload = json.loads(RECORDS_FILE.read_text(encoding="utf-8"))
    return [FoodRecord.from_json(r) for r in payload["records"]], payload.get("stats", {})


def stage_images(args: argparse.Namespace, records: list[FoodRecord] | None = None
                 ) -> list[FoodRecord]:
    if records is None:
        records, _ = _read_records()
    hosting = HostingConfig.load()

    if args.skip_images:
        _log.warning("Image stage skipped (--skip-images); rows will have no image URLs")
        for r in records:
            strip_image_tags(r)
        return records

    crawler = ImageCrawler(use_network=args.network)
    # Limit the *discovery* set, not the result set — crawling every record and
    # then throwing most away would waste the whole point of the limit.
    pool = records
    if args.image_limit:
        pool = sorted(records, key=lambda r: ("variant" in r.tags, r.name))[: args.image_limit]
    candidates = crawler.crawl(pool)

    processor = ImageProcessor()
    assets = processor.process_all(candidates)

    if args.upload:
        provider = hosting.provider
        owner = os.environ.get("IFCA_IMAGE_OWNER", provider.get("owner", ""))
        repo = os.environ.get("IFCA_IMAGE_REPO", provider.get("repo", ""))
        tag = provider.get("tag", "images-latest")
        GitHubReleaseUploader(owner, repo, tag, dry_run=args.dry_run).upload_assets(assets.values())
        if args.images_repo:
            GitRepoPublisher(Path(args.images_repo), dry_run=args.dry_run).publish()

    assets = assign_urls(assets, hosting)
    manifest = build_manifest(assets, hosting)

    if args.verify_urls:
        failed, _ = verify_urls(manifest, sample=args.verify_sample)
        assets = prune_missing(assets, failed)
        manifest = build_manifest(assets, hosting)
    write_manifest(manifest)
    ASSETS_FILE.write_text(json.dumps(
        {k: dataclasses.asdict(v) for k, v in assets.items()}, ensure_ascii=False),
        encoding="utf-8")

    _attach_images(records, assets)
    _write_records(records, {"images": {"assets": len(assets)}})
    return records


def _attach_images(records: list[FoodRecord], assets: dict[str, object]) -> None:
    from .models import ImageAsset

    by_slug = {k: (v if isinstance(v, ImageAsset) else ImageAsset(**v))  # type: ignore[arg-type]
               for k, v in assets.items()}
    # Variants inherit the base dish's image: "Roti (with Ghee)" -> "roti".
    for rec in records:
        strip_image_tags(rec)
        asset = by_slug.get(rec.slug)
        if asset is None and "variant" in rec.tags:
            base_slug = rec.slug.split("_")[0]
            asset = by_slug.get(base_slug)
            if asset is None:
                for candidate_slug in by_slug:
                    if rec.slug.startswith(candidate_slug):
                        asset = by_slug[candidate_slug]
                        break
        if asset is not None:
            rec.image = asset


def stage_db(args: argparse.Namespace, records: list[FoodRecord] | None = None) -> Path:
    stats: dict = {}
    if records is None:
        records, stats = _read_records()
    if ASSETS_FILE.exists() and not any(r.image for r in records):
        _attach_images(records, json.loads(ASSETS_FILE.read_text(encoding="utf-8")))
    records.sort(key=lambda r: (-len(r.name) if False else 0, r.name.lower()))
    builder = DatabaseBuilder(DB_PATH)
    path = builder.build(records, stats=stats)
    _write_release_metadata(builder, records)
    return path


def _write_release_metadata(builder: DatabaseBuilder, records: list[FoodRecord]) -> None:
    size = builder.path.stat().st_size
    manifest_count = 0
    if MANIFEST_PATH.exists():
        manifest_count = json.loads(MANIFEST_PATH.read_text(encoding="utf-8")).get("count", 0)
    meta = {
        "schema_version": config.SCHEMA_VERSION,
        "database": builder.path.name,
        "database_bytes": size,
        "database_sha256": builder.checksum(),
        "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "release_date": dt.date.today().isoformat(),
        "food_count": len(records),
        "recipe_count": sum(1 for r in records if r.food_type == "recipe"),
        "packaged_count": sum(1 for r in records if r.food_type == "packaged"),
        "image_count": manifest_count,
        "min_app_version": "1.0.0",
    }
    METADATA_PATH.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    _log.info("Release metadata: %s", METADATA_PATH)

    notes = DIST_DIR / "RELEASE_NOTES.md"
    notes.write_text(
        f"# Database release {meta['release_date']}\n\n"
        f"- **Foods:** {meta['food_count']:,} "
        f"({meta['recipe_count']:,} recipes, {meta['packaged_count']:,} packaged)\n"
        f"- **Images published:** {meta['image_count']:,} (served via CDN, 0 MB in the APK)\n"
        f"- **Database size:** {size / 1e6:.1f} MB\n"
        f"- **Schema version:** {meta['schema_version']}\n"
        f"- **SHA-256:** `{meta['database_sha256']}`\n\n"
        "Nutrition data derives from IFCT 2017 (NIN/ICMR), USDA FoodData Central "
        "(public domain) and Open Food Facts (ODbL 1.0). Descriptions from "
        "Wikipedia (CC BY-SA 4.0). Images from Wikimedia Commons and Open Food "
        "Facts under their respective open licences; per-image credit ships in "
        "the database.\n",
        encoding="utf-8",
    )


def stage_verify(args: argparse.Namespace) -> int:
    if not MANIFEST_PATH.exists():
        raise SystemExit("No manifest — run `ifca images` first.")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    failed, stats = verify_urls(manifest, sample=args.verify_sample)
    print(json.dumps(stats, indent=1))
    return 1 if failed and args.strict else 0


def stage_stats(_args: argparse.Namespace) -> int:
    if not DB_PATH.exists():
        raise SystemExit("No database built yet.")
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    out = {
        "file": str(DB_PATH),
        "bytes": DB_PATH.stat().st_size,
        "foods": conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0],
        "recipes": conn.execute("SELECT COUNT(*) FROM recipes").fetchone()[0],
        "servings": conn.execute("SELECT COUNT(*) FROM servings").fetchone()[0],
        "with_image": conn.execute(
            "SELECT COUNT(*) FROM foods WHERE thumbnail_url <> ''").fetchone()[0],
        "with_hindi": conn.execute(
            "SELECT COUNT(*) FROM foods WHERE hindi_name <> ''").fetchone()[0],
        "alternatives": conn.execute("SELECT COUNT(*) FROM alternatives").fetchone()[0],
        "categories": [dict(r) for r in conn.execute(
            "SELECT name, food_count FROM categories ORDER BY food_count DESC LIMIT 12")],
    }
    conn.close()
    print(json.dumps(out, indent=1, ensure_ascii=False))
    return 0


def stage_bundle(args: argparse.Namespace) -> Path:
    """Copy the built DB into the Flutter app's assets folder (gzipped)."""
    import gzip

    target = Path(args.app_assets or (config.REPO_ROOT / "app" / "assets" / "db"))
    target.mkdir(parents=True, exist_ok=True)
    out = target / f"{DB_PATH.name}.gz"
    with DB_PATH.open("rb") as src, gzip.open(out, "wb", compresslevel=9) as dst:
        shutil.copyfileobj(src, dst)
    if METADATA_PATH.exists():
        shutil.copy2(METADATA_PATH, target / "metadata.json")
    _log.info("Bundled asset: %s (%.1f MB)", out, out.stat().st_size / 1e6)
    return out


# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ifca", description="Indian Food Calories database builder")
    p.add_argument("command", choices=["build", "crawl", "images", "db", "verify",
                                       "stats", "bundle", "init"])
    p.add_argument("--offline", dest="network", action="store_false", default=True,
                   help="skip every network source (curated + recipes only)")
    p.add_argument("--no-variants", action="store_true", help="skip rule-derived variants")
    p.add_argument("--variants-per-base", type=int, default=6)
    p.add_argument("--no-wiki", action="store_true", help="skip Wikipedia enrichment")
    p.add_argument("--usda-limit", type=int, default=None)
    p.add_argument("--off-limit", type=int, default=4000)
    p.add_argument("--off-dump", default=os.environ.get("IFCA_OFF_DUMP") or None)
    p.add_argument("--skip-images", action="store_true")
    p.add_argument("--image-limit", type=int, default=None)
    p.add_argument("--upload", action="store_true", help="push renditions to GitHub Releases")
    p.add_argument("--images-repo", default=os.environ.get("IFCA_IMAGES_REPO"))
    p.add_argument("--verify-urls", action="store_true")
    p.add_argument("--verify-sample", type=int, default=None)
    p.add_argument("--strict", action="store_true", help="non-zero exit on verification failure")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--app-assets", default=None)
    p.add_argument("--log-level", default=os.environ.get("IFCA_LOG_LEVEL", "INFO"))
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    log.setup(args.log_level)
    write_default_hosting()

    if args.command == "init":
        _log.info("Work dir: %s", config.WORK_DIR)
        _log.info("Hosting config: %s", config.HOSTING_FILE)
        return 0
    if args.command == "crawl":
        stage_crawl(args)
        return 0
    if args.command == "images":
        stage_images(args)
        return 0
    if args.command == "db":
        stage_db(args)
        return 0
    if args.command == "verify":
        return stage_verify(args)
    if args.command == "stats":
        return stage_stats(args)
    if args.command == "bundle":
        stage_bundle(args)
        return 0
    if args.command == "build":
        records = stage_crawl(args)
        records = stage_images(args, records)
        stage_db(args, records)
        stage_bundle(args)
        return stage_stats(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
