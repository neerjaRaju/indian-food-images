"""Publish renditions to GitHub Releases and mint CDN URLs.

GitHub Releases is the store of record for generated food images.
jsDelivr fronts the repository copy for CDN delivery.

Release assets use this layout:

    <folder>_<slug>.webp

Uploads are idempotent:
- Same filename + same size -> skipped
- Same filename + different size -> replaced
- Missing filename -> uploaded
"""

from __future__ import annotations

import os
import subprocess
from collections.abc import Iterable
from pathlib import Path
from urllib.parse import quote

import requests

from ..config import IMAGE_OUT_DIR, RENDITIONS, HostingConfig
from ..models import ImageAsset
from ..util import log

_log = log.get("ifca.imaging.uploader")

GITHUB_API = "https://api.github.com"
GITHUB_UPLOADS = "https://uploads.github.com"


class GitHubReleaseUploader:
    """Upload generated WebP images to a GitHub Release."""

    def __init__(
        self,
        owner: str,
        repo: str,
        tag: str,
        token: str | None = None,
        dry_run: bool = False,
    ) -> None:
        self.owner = owner
        self.repo = repo
        self.tag = tag

        self.token = token or os.environ.get("GITHUB_TOKEN", "")

        # Explicit dry-run always wins.
        self.dry_run = dry_run or not self.token

        self._existing: dict[str, int] = {}
        self._asset_ids: dict[str, int] = {}
        self._release_id: int | None = None

    # ------------------------------------------------------------------ #
    # GitHub helpers
    # ------------------------------------------------------------------ #

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    @property
    def _release_url(self) -> str:
        return (
            f"{GITHUB_API}/repos/"
            f"{self.owner}/{self.repo}/releases"
        )

    @property
    def _repo_url(self) -> str:
        return (
            f"{GITHUB_API}/repos/"
            f"{self.owner}/{self.repo}"
        )

    def _refresh_assets(self) -> None:
        """Refresh the local filename -> asset metadata cache."""

        if self._release_id is None:
            return

        url = (
            f"{self._release_url}/"
            f"{self._release_id}/assets"
        )

        r = requests.get(
            url,
            headers=self._headers(),
            params={"per_page": 100},
            timeout=30,
        )

        if r.status_code != 200:
            _log.warning(
                "Unable to refresh release assets: %s %s",
                r.status_code,
                r.text[:500],
            )
            return

        self._existing.clear()
        self._asset_ids.clear()

        for asset in r.json():
            name = asset.get("name")
            size = asset.get("size")
            asset_id = asset.get("id")

            if not name:
                continue

            if isinstance(size, int):
                self._existing[name] = size

            if isinstance(asset_id, int):
                self._asset_ids[name] = asset_id

        _log.info(
            "Release asset cache refreshed: %d assets",
            len(self._existing),
        )

    # ------------------------------------------------------------------ #

    def ensure_release(self) -> int | None:
        """Find the release by tag or create it."""

        if self.dry_run:
            _log.warning(
                "No GITHUB_TOKEN — running uploader in dry-run mode"
            )
            return None

        if self._release_id is not None:
            return self._release_id

        # -------------------------------------------------------------- #
        # First try to find the release by tag.
        # -------------------------------------------------------------- #

        tag_url = (
            f"{self._release_url}/tags/"
            f"{quote(self.tag, safe='')}"
        )

        r = requests.get(
            tag_url,
            headers=self._headers(),
            timeout=30,
        )

        if r.status_code == 200:
            data = r.json()

        elif r.status_code == 404:
            _log.info(
                "Release %r does not exist; creating it",
                self.tag,
            )

            r = requests.post(
                self._release_url,
                headers=self._headers(),
                timeout=30,
                json={
                    "tag_name": self.tag,
                    "name": f"Food images {self.tag}",
                    "body": (
                        "Automated image release. "
                        "Assets are WebP renditions "
                        "served through jsDelivr."
                    ),
                    "draft": False,
                    "prerelease": False,
                },
            )

            if r.status_code >= 300:
                _log.error(
                    "Failed to create GitHub release: %s %s",
                    r.status_code,
                    r.text[:1000],
                )
                r.raise_for_status()

            data = r.json()

        else:
            _log.error(
                "Failed to query GitHub release %r: %s %s",
                self.tag,
                r.status_code,
                r.text[:1000],
            )
            r.raise_for_status()
            return None

        self._release_id = data["id"]

        # Load assets immediately.
        self._refresh_assets()

        _log.info(
            "Release %s ready (%d existing assets)",
            self.tag,
            len(self._existing),
        )

        return self._release_id

    # ------------------------------------------------------------------ #

    def _delete_asset(self, name: str) -> bool:
        """Delete a release asset by filename."""

        rid = self._release_id

        if rid is None:
            return False

        # Refresh first so we have the current asset ID.
        self._refresh_assets()

        asset_id = self._asset_ids.get(name)

        if asset_id is None:
            _log.info(
                "Asset %s is already absent",
                name,
            )

            self._existing.pop(name, None)
            self._asset_ids.pop(name, None)

            return True

        url = (
            f"{self._release_url}/assets/"
            f"{asset_id}"
        )

        r = requests.delete(
            url,
            headers=self._headers(),
            timeout=30,
        )

        if r.status_code not in (204, 404):
            _log.warning(
                "Failed to delete existing asset %s: %s %s",
                name,
                r.status_code,
                r.text[:500],
            )
            return False

        # Remove from local cache.
        self._existing.pop(name, None)
        self._asset_ids.pop(name, None)

        _log.info(
            "Deleted existing release asset: %s",
            name,
        )

        return True

    # ------------------------------------------------------------------ #

    def _upload_request(
        self,
        path: Path,
        name: str,
        rid: int,
    ) -> requests.Response:
        """Perform a GitHub release asset upload."""

        encoded_name = quote(
            name,
            safe="",
        )

        url = (
            f"{GITHUB_UPLOADS}/repos/"
            f"{self.owner}/{self.repo}"
            f"/releases/{rid}/assets"
            f"?name={encoded_name}"
        )

        headers = {
            **self._headers(),
            "Content-Type": "image/webp",
        }

        # Streaming file upload avoids loading large images into RAM.
        with path.open("rb") as fh:
            return requests.post(
                url,
                headers=headers,
                data=fh,
                timeout=180,
            )

    # ------------------------------------------------------------------ #

    def upload_file(
        self,
        path: Path,
        name: str,
    ) -> bool:
        """Upload one file.

        Returns:
            True  -> uploaded/replaced
            False -> skipped or failed
        """

        if not path.exists():
            _log.warning(
                "Image file does not exist: %s",
                path,
            )
            return False

        size = path.stat().st_size

        rid = self.ensure_release()

        if rid is None:
            # Dry-run.
            _log.info(
                "[dry-run] would upload %s as %s",
                path,
                name,
            )
            return False

        # -------------------------------------------------------------- #
        # Always use fresh asset information.
        # -------------------------------------------------------------- #

        existing_size = self._existing.get(name)

        # Same filename + same byte size = no upload required.
        if existing_size == size:
            _log.debug(
                "Skipping unchanged asset: %s (%d bytes)",
                name,
                size,
            )
            return False

        # -------------------------------------------------------------- #
        # Existing asset with different size -> delete it.
        # -------------------------------------------------------------- #

        if name in self._existing:
            _log.info(
                "Replacing changed release asset: %s "
                "(old=%d bytes, new=%d bytes)",
                name,
                existing_size or 0,
                size,
            )

            if not self._delete_asset(name):
                _log.warning(
                    "Could not delete existing asset %s",
                    name,
                )
                return False

        # -------------------------------------------------------------- #
        # Upload.
        # -------------------------------------------------------------- #

        try:
            r = self._upload_request(
                path,
                name,
                rid,
            )
        except requests.RequestException as exc:
            _log.warning(
                "Network error uploading %s: %s",
                name,
                exc,
            )
            return False

        # -------------------------------------------------------------- #
        # Successful upload.
        # -------------------------------------------------------------- #

        if r.status_code in (200, 201):
            self._existing[name] = size

            try:
                data = r.json()
                asset_id = data.get("id")
                if isinstance(asset_id, int):
                    self._asset_ids[name] = asset_id
            except ValueError:
                pass

            _log.info(
                "Uploaded %s (%d bytes)",
                name,
                size,
            )

            return True

        # -------------------------------------------------------------- #
        # 422 can happen when GitHub still sees an old asset.
        #
        # Refresh -> delete -> retry once.
        # -------------------------------------------------------------- #

        if r.status_code == 422:
            _log.warning(
                "GitHub returned 422 for %s: %s",
                name,
                r.text[:1000],
            )

            _log.info(
                "Refreshing release assets and retrying %s",
                name,
            )

            self._refresh_assets()

            if name in self._existing:
                if not self._delete_asset(name):
                    _log.error(
                        "Unable to remove conflicting asset %s "
                        "after 422",
                        name,
                    )
                    return False

                # Retry exactly once.
                try:
                    retry = self._upload_request(
                        path,
                        name,
                        rid,
                    )
                except requests.RequestException as exc:
                    _log.warning(
                        "Retry failed for %s: %s",
                        name,
                        exc,
                    )
                    return False

                if retry.status_code in (200, 201):
                    self._existing[name] = size

                    try:
                        data = retry.json()
                        asset_id = data.get("id")
                        if isinstance(asset_id, int):
                            self._asset_ids[name] = asset_id
                    except ValueError:
                        pass

                    _log.info(
                        "Uploaded %s successfully after 422 retry",
                        name,
                    )

                    return True

                _log.error(
                    "Retry upload failed for %s: %s %s",
                    name,
                    retry.status_code,
                    retry.text[:1000],
                )

            return False

        # -------------------------------------------------------------- #
        # Other GitHub error.
        # -------------------------------------------------------------- #

        _log.warning(
            "Upload failed for %s: HTTP %s %s",
            name,
            r.status_code,
            r.text[:1000],
        )

        return False

    # ------------------------------------------------------------------ #

    def upload_assets(
        self,
        assets: Iterable[ImageAsset],
        image_dir: Path = IMAGE_OUT_DIR,
    ) -> dict[str, int]:
        """Upload all available renditions."""

        stats = {
            "uploaded": 0,
            "skipped": 0,
            "missing": 0,
            "failed": 0,
        }

        # Initialize release/cache before processing files.
        self.ensure_release()

        for asset in assets:
            for rendition in RENDITIONS:
                path = (
                    image_dir
                    / rendition.folder
                    / f"{asset.slug}.webp"
                )

                name = (
                    f"{rendition.folder}_"
                    f"{asset.slug}.webp"
                )

                if not path.exists():
                    stats["missing"] += 1

                    _log.debug(
                        "Missing rendition: %s",
                        path,
                    )

                    continue

                before = self._existing.get(name)

                uploaded = self.upload_file(
                    path,
                    name,
                )

                if uploaded:
                    stats["uploaded"] += 1
                elif before == path.stat().st_size:
                    stats["skipped"] += 1
                else:
                    stats["failed"] += 1

        _log.info(
            "Release upload complete: %s",
            stats,
        )

        return stats


class GitRepoPublisher:
    """Commits the ``images/foods`` tree so jsDelivr can serve it."""

    def __init__(
        self,
        repo_dir: Path,
        branch: str = "main",
        dry_run: bool = False,
    ) -> None:
        self.repo_dir = repo_dir
        self.branch = branch
        self.dry_run = dry_run

    def _run(self, *args: str) -> None:
        if self.dry_run:
            _log.info(
                "[dry-run] git %s",
                " ".join(args),
            )
            return

        subprocess.run(
            ["git", *args],
            cwd=self.repo_dir,
            check=True,
            capture_output=True,
            text=True,
        )

    def publish(
        self,
        image_dir: Path = IMAGE_OUT_DIR,
        message: str = "chore: refresh images",
    ) -> None:
        target = (
            self.repo_dir
            / "images"
            / "foods"
        )

        target.mkdir(
            parents=True,
            exist_ok=True,
        )

        for rendition in RENDITIONS:
            src = image_dir / rendition.folder
            dst = target / rendition.folder

            dst.mkdir(
                parents=True,
                exist_ok=True,
            )

            for f in src.glob("*.webp"):
                out = dst / f.name

                if (
                    not out.exists()
                    or out.stat().st_size != f.stat().st_size
                ):
                    out.write_bytes(
                        f.read_bytes()
                    )

        self._run(
            "add",
            "images",
        )

        try:
            self._run(
                "commit",
                "-m",
                message,
            )
        except subprocess.CalledProcessError:
            _log.info(
                "Nothing to commit"
            )
            return

        self._run(
            "push",
            "origin",
            self.branch,
        )


def assign_urls(
    assets: dict[str, ImageAsset],
    hosting: HostingConfig,
) -> dict[str, ImageAsset]:
    """Mint the three CDN URLs for every asset."""

    for slug, asset in assets.items():
        for rendition in RENDITIONS:
            setattr(
                asset,
                f"{rendition.name}_url",
                hosting.url_for(
                    slug,
                    rendition.folder,
                ),
            )

    _log.info(
        "Assigned CDN URLs for %d assets via provider %r",
        len(assets),
        hosting.active,
    )

    return assets