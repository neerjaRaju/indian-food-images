"""Publish renditions to GitHub Releases and mint CDN URLs.

GitHub Releases is the store of record (unlimited assets, no bandwidth bill);
jsDelivr fronts the *repository* copy for CDN delivery. Both layouts are
produced so a repo can serve either way:

  images/foods/{thumbnails,medium,large}/<slug>.webp   <- committed, jsDelivr
  <folder>_<slug>.webp                                 <- release asset name

Uploads are idempotent: an asset whose name and size already match is skipped,
so the weekly job only pushes what actually changed.
"""
from __future__ import annotations

import os
import subprocess
from collections.abc import Iterable
from pathlib import Path

import requests

from ..config import IMAGE_OUT_DIR, RENDITIONS, HostingConfig
from ..models import ImageAsset
from ..util import log

_log = log.get("ifca.imaging.uploader")

GITHUB_API = "https://api.github.com"


class GitHubReleaseUploader:
    def __init__(self, owner: str, repo: str, tag: str,
                 token: str | None = None, dry_run: bool = False) -> None:
        self.owner = owner
        self.repo = repo
        self.tag = tag
        self.token = token or os.environ.get("GITHUB_TOKEN", "")
        self.dry_run = dry_run or not self.token
        self._existing: dict[str, int] = {}
        self._release_id: int | None = None

    # ------------------------------------------------------------------ #
    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def ensure_release(self) -> int | None:
        if self.dry_run:
            _log.warning("No GITHUB_TOKEN — running uploader in dry-run mode")
            return None
        if self._release_id:
            return self._release_id
        base = f"{GITHUB_API}/repos/{self.owner}/{self.repo}/releases"
        r = requests.get(f"{base}/tags/{self.tag}", headers=self._headers(), timeout=30)
        if r.status_code == 200:
            data = r.json()
        else:
            r = requests.post(base, headers=self._headers(), timeout=30, json={
                "tag_name": self.tag,
                "name": f"Food images {self.tag}",
                "body": "Automated image release. Assets are WebP renditions "
                        "served through jsDelivr.",
                "draft": False, "prerelease": False,
            })
            r.raise_for_status()
            data = r.json()
        self._release_id = data["id"]
        for asset in data.get("assets", []):
            self._existing[asset["name"]] = asset["size"]
        _log.info("Release %s ready (%d existing assets)", self.tag, len(self._existing))
        return self._release_id

    def upload_file(self, path: Path, name: str) -> bool:
        size = path.stat().st_size
        if self._existing.get(name) == size:
            return False
        rid = self.ensure_release()
        if rid is None:
            return False
        if name in self._existing:      # replace changed asset
            self._delete_asset(name)
        url = (f"https://uploads.github.com/repos/{self.owner}/{self.repo}"
               f"/releases/{rid}/assets?name={name}")
        headers = {**self._headers(), "Content-Type": "image/webp"}
        r = requests.post(url, headers=headers, data=path.read_bytes(), timeout=120)
        if r.status_code >= 300:
            _log.warning("Upload failed for %s: %s %s", name, r.status_code, r.text[:200])
            return False
        self._existing[name] = size
        return True

    def _delete_asset(self, name: str) -> None:
        rid = self._release_id
        r = requests.get(f"{GITHUB_API}/repos/{self.owner}/{self.repo}/releases/{rid}/assets",
                         headers=self._headers(), timeout=30)
        if r.status_code != 200:
            return
        for a in r.json():
            if a["name"] == name:
                requests.delete(f"{GITHUB_API}/repos/{self.owner}/{self.repo}/releases/assets/{a['id']}",
                                headers=self._headers(), timeout=30)
                return

    # ------------------------------------------------------------------ #
    def upload_assets(self, assets: Iterable[ImageAsset],
                      image_dir: Path = IMAGE_OUT_DIR) -> dict[str, int]:
        stats = {"uploaded": 0, "skipped": 0, "missing": 0}
        for asset in assets:
            for r in RENDITIONS:
                path = image_dir / r.folder / f"{asset.slug}.webp"
                if not path.exists():
                    stats["missing"] += 1
                    continue
                if self.upload_file(path, f"{r.folder}_{asset.slug}.webp"):
                    stats["uploaded"] += 1
                else:
                    stats["skipped"] += 1
        _log.info("Release upload: %s", stats)
        return stats


class GitRepoPublisher:
    """Commits the ``images/foods`` tree so jsDelivr can serve it from the repo."""

    def __init__(self, repo_dir: Path, branch: str = "main", dry_run: bool = False) -> None:
        self.repo_dir = repo_dir
        self.branch = branch
        self.dry_run = dry_run

    def _run(self, *args: str) -> None:
        if self.dry_run:
            _log.info("[dry-run] git %s", " ".join(args))
            return
        subprocess.run(["git", *args], cwd=self.repo_dir, check=True,
                       capture_output=True, text=True)

    def publish(self, image_dir: Path = IMAGE_OUT_DIR, message: str = "chore: refresh images") -> None:
        target = self.repo_dir / "images" / "foods"
        target.mkdir(parents=True, exist_ok=True)
        for r in RENDITIONS:
            src = image_dir / r.folder
            dst = target / r.folder
            dst.mkdir(parents=True, exist_ok=True)
            for f in src.glob("*.webp"):
                out = dst / f.name
                if not out.exists() or out.stat().st_size != f.stat().st_size:
                    out.write_bytes(f.read_bytes())
        self._run("add", "images")
        try:
            self._run("commit", "-m", message)
        except subprocess.CalledProcessError:
            _log.info("Nothing to commit")
            return
        self._run("push", "origin", self.branch)


def assign_urls(assets: dict[str, ImageAsset], hosting: HostingConfig) -> dict[str, ImageAsset]:
    """Mint the three CDN URLs for every asset from the active provider."""
    for slug, asset in assets.items():
        for r in RENDITIONS:
            setattr(asset, f"{r.name}_url", hosting.url_for(slug, r.folder))
    _log.info("Assigned CDN URLs for %d assets via provider %r", len(assets), hosting.active)
    return assets
