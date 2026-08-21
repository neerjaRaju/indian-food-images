"""Image manifest generation and URL verification."""
from __future__ import annotations

import concurrent.futures as cf
import datetime as dt
import json
from collections.abc import Iterable
from pathlib import Path

from ..config import HTTP_CONCURRENCY, MANIFEST_PATH, RENDITIONS, HostingConfig
from ..models import ImageAsset
from ..util import http, log

_log = log.get("ifca.imaging.manifest")


def build_manifest(assets: dict[str, ImageAsset], hosting: HostingConfig) -> dict:
    entries = []
    total_bytes = 0
    for slug, a in sorted(assets.items()):
        total_bytes += a.bytes_thumbnail + a.bytes_medium + a.bytes_large
        entries.append({
            "slug": slug,
            "thumbnail": a.thumbnail_url,
            "medium": a.medium_url,
            "large": a.large_url,
            "phash": a.phash,
            "source": a.source_name,
            "source_url": a.source_url,
            "credit": a.credit,
            "license": a.license,
            "license_url": a.license_url,
            "bytes": {"thumbnail": a.bytes_thumbnail, "medium": a.bytes_medium,
                      "large": a.bytes_large},
        })
    return {
        "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "provider": hosting.active,
        "renditions": [{"name": r.name, "size": r.size, "folder": r.folder} for r in RENDITIONS],
        "count": len(entries),
        "total_bytes": total_bytes,
        "images": entries,
    }


def write_manifest(manifest: dict, path: Path = MANIFEST_PATH) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    _log.info("Manifest written: %s (%d images, %.1f MB)",
              path, manifest["count"], manifest["total_bytes"] / 1e6)
    return path


def verify_urls(manifest: dict, *, sample: int | None = None,
                workers: int = HTTP_CONCURRENCY) -> tuple[list[str], dict]:
    """HEAD every published URL. Returns (failed_urls, stats).

    ``sample`` limits the check to the first N images — used for PR builds where
    a full sweep would be wasteful; the weekly job verifies everything.
    """
    images = manifest["images"][:sample] if sample else manifest["images"]
    urls: list[str] = []
    for entry in images:
        urls.extend(u for u in (entry["thumbnail"], entry["medium"], entry["large"]) if u)
    failed: list[str] = []
    if not urls:
        return failed, {"checked": 0, "failed": 0}
    with cf.ThreadPoolExecutor(max_workers=workers) as pool:
        for url, ok in zip(urls, pool.map(http.head_ok, urls)):
            if not ok:
                failed.append(url)
    stats = {"checked": len(urls), "failed": len(failed)}
    if failed:
        _log.warning("URL verification: %d/%d failed. First failures: %s",
                     len(failed), len(urls), failed[:5])
    else:
        _log.info("URL verification passed for %d URLs", len(urls))
    return failed, stats


def prune_missing(assets: dict[str, ImageAsset], failed_urls: Iterable[str]) -> dict[str, ImageAsset]:
    """Drop assets whose URLs did not resolve, so the DB never ships a 404."""
    bad = set(failed_urls)
    if not bad:
        return assets
    out = {}
    for slug, a in assets.items():
        if a.thumbnail_url in bad or a.medium_url in bad:
            continue
        out[slug] = a
    _log.info("Pruned %d assets with unreachable URLs", len(assets) - len(out))
    return out
