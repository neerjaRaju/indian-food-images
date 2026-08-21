"""
Publish image renditions to GitHub Releases and mint CDN URLs.

GitHub Releases are sharded automatically because GitHub allows a maximum
of 1,000 assets per release.

Example:

    images-latest-001
        1..1000 assets

    images-latest-002
        1..1000 assets

    images-latest-003
        remaining assets

Release asset names:

    <rendition_folder>_<slug>.webp

Examples:

    thumbnails_gajar_halwa.webp
    medium_gajar_halwa.webp
    large_gajar_halwa.webp

Uploads are idempotent:

    same filename + same size
        -> skipped

    same filename + different size
        -> replaced

    filename does not exist
        -> uploaded

The uploader automatically discovers existing shards and creates new shards
when the current release reaches the configured asset limit.
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

# GitHub Releases supports a maximum of 1,000 assets per release.
MAX_ASSETS_PER_RELEASE = 1000

# Base release name.
DEFAULT_RELEASE_PREFIX = "images-latest"

# Maximum number of retries for transient GitHub failures.
MAX_UPLOAD_RETRIES = 3


class GitHubReleaseUploader:
    """
    Upload generated WebP files to sharded GitHub Releases.

    Releases are automatically created as:

        images-latest-001
        images-latest-002
        images-latest-003
        ...

    Each release contains at most 1,000 assets.
    """

    def __init__(
        self,
        owner: str,
        repo: str,
        tag: str,
        token: str | None = None,
        dry_run: bool = False,
        max_assets_per_release: int = MAX_ASSETS_PER_RELEASE,
    ) -> None:
        self.owner = owner
        self.repo = repo

        # The supplied tag is treated as the release prefix.

        # If caller passes:
        #
        #     images-latest
        #
        # releases become:
        #
        #     images-latest-001
        #     images-latest-002
        #
        # If caller already passes:
        #
        #     images-latest-001
        #
        # it is used as the prefix:
        #
        #     images-latest-001-001
        #
        # Normally the CLI should pass "images-latest".

        self.tag = tag.rstrip("-")
        self.release_prefix = self.tag

        self.token = token or os.environ.get("GITHUB_TOKEN", "")

        self.dry_run = dry_run or not self.token

        self.max_assets_per_release = max(
            1,
            min(
                int(max_assets_per_release),
                MAX_ASSETS_PER_RELEASE,
            ),
        )

        # -------------------------------------------------------------- #
        # Current shard
        # -------------------------------------------------------------- #

        self._release_id: int | None = None
        self._release_tag: str | None = None

        # filename -> size
        self._existing: dict[str, int] = {}

        # filename -> GitHub asset ID
        self._asset_ids: dict[str, int] = {}

        # Current shard asset count.
        self._asset_count: int = 0

        # -------------------------------------------------------------- #
        # All discovered release shards.
        #
        # {
        #     "images-latest-001": {
        #         "id": 123,
        #         "asset_count": 1000
        #     }
        # }
        # -------------------------------------------------------------- #

        self._shards: dict[str, dict[str, int]] = {}

    # ================================================================== #
    # HTTP
    # ================================================================== #

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

    # ================================================================== #
    # Release naming
    # ================================================================== #

    def _shard_tag(self, number: int) -> str:
        """
        Convert shard number to a release tag.

        1 -> images-latest-001
        2 -> images-latest-002
        """

        return f"{self.release_prefix}-{number:03d}"

    def _shard_name(self, number: int) -> str:
        return self._shard_tag(number)

    # ================================================================== #
    # Discover existing releases
    # ================================================================== #

    def _discover_shards(self) -> list[tuple[int, str, int]]:
        """
        Discover all existing releases matching our prefix.

        Returns:

            [
                (1, "images-latest-001", release_id),
                (2, "images-latest-002", release_id),
            ]
        """

        if self.dry_run:
            return []

        releases: list[dict] = []

        page = 1

        while True:
            url = self._release_url

            try:
                response = requests.get(
                    url,
                    headers=self._headers(),
                    params={
                        "per_page": 100,
                        "page": page,
                    },
                    timeout=30,
                )
            except requests.RequestException as exc:
                _log.warning(
                    "Failed to discover GitHub releases: %s",
                    exc,
                )
                break

            if response.status_code != 200:
                _log.warning(
                    "Failed to discover GitHub releases: "
                    "HTTP %s %s",
                    response.status_code,
                    response.text[:500],
                )
                break

            batch = response.json()

            if not isinstance(batch, list) or not batch:
                break

            releases.extend(batch)

            if len(batch) < 100:
                break

            page += 1

        discovered: list[tuple[int, str, int]] = []

        prefix = f"{self.release_prefix}-"

        for release in releases:
            tag = release.get("tag_name")
            release_id = release.get("id")

            if not isinstance(tag, str):
                continue

            if not tag.startswith(prefix):
                continue

            suffix = tag[len(prefix):]

            if not suffix.isdigit():
                continue

            number = int(suffix)

            if not isinstance(release_id, int):
                continue

            discovered.append(
                (
                    number,
                    tag,
                    release_id,
                )
            )

        discovered.sort(key=lambda item: item[0])

        _log.info(
            "Discovered %d image release shards",
            len(discovered),
        )

        return discovered

    # ================================================================== #
    # Load a release
    # ================================================================== #

    def _load_release(
        self,
        tag: str,
        release_id: int,
    ) -> None:
        """
        Load one release and all of its assets.

        This resets the current shard cache.
        """

        self._release_id = release_id
        self._release_tag = tag

        self._existing.clear()
        self._asset_ids.clear()

        page = 1

        while True:
            url = (
                f"{self._release_url}/"
                f"{release_id}/assets"
            )

            try:
                response = requests.get(
                    url,
                    headers=self._headers(),
                    params={
                        "per_page": 100,
                        "page": page,
                    },
                    timeout=30,
                )
            except requests.RequestException as exc:
                _log.warning(
                    "Failed loading assets for %s: %s",
                    tag,
                    exc,
                )
                break

            if response.status_code != 200:
                _log.warning(
                    "Failed loading assets for %s: "
                    "HTTP %s %s",
                    tag,
                    response.status_code,
                    response.text[:500],
                )
                break

            assets = response.json()

            if not isinstance(assets, list) or not assets:
                break

            for asset in assets:
                name = asset.get("name")
                size = asset.get("size")
                asset_id = asset.get("id")

                if not isinstance(name, str):
                    continue

                if isinstance(size, int):
                    self._existing[name] = size

                if isinstance(asset_id, int):
                    self._asset_ids[name] = asset_id

            if len(assets) < 100:
                break

            page += 1

        self._asset_count = len(self._asset_ids)

        _log.info(
            "Loaded release %s: %d assets",
            tag,
            self._asset_count,
        )

    # ================================================================== #
    # Create release
    # ================================================================== #

    def _create_release(
        self,
        number: int,
    ) -> tuple[str, int] | None:
        """
        Create a new release shard.
        """

        tag = self._shard_tag(number)

        if self.dry_run:
            _log.info(
                "[dry-run] Would create release %s",
                tag,
            )
            return None

        _log.info(
            "Creating new image release shard: %s",
            tag,
        )

        try:
            response = requests.post(
                self._release_url,
                headers=self._headers(),
                timeout=30,
                json={
                    "tag_name": tag,
                    "name": f"Food images {tag}",
                    "body": (
                        "Automated food image release shard.\n\n"
                        f"Shard: {number:03d}\n"
                        f"Maximum assets: "
                        f"{self.max_assets_per_release}"
                    ),
                    "draft": False,
                    "prerelease": False,
                },
            )
        except requests.RequestException as exc:
            _log.error(
                "Failed creating release %s: %s",
                tag,
                exc,
            )
            return None

        if response.status_code in (200, 201):
            data = response.json()

            release_id = data.get("id")

            if isinstance(release_id, int):
                return tag, release_id

        # A concurrent job may have created the release.
        if response.status_code == 422:
            _log.warning(
                "Release %s may already exist. Re-checking.",
                tag,
            )

            try:
                lookup = requests.get(
                    f"{self._release_url}/tags/"
                    f"{quote(tag, safe='')}",
                    headers=self._headers(),
                    timeout=30,
                )

                if lookup.status_code == 200:
                    data = lookup.json()
                    release_id = data.get("id")

                    if isinstance(release_id, int):
                        return tag, release_id

            except requests.RequestException:
                pass

        _log.error(
            "Failed creating release %s: HTTP %s %s",
            tag,
            response.status_code,
            response.text[:1000],
        )

        return None

    # ================================================================== #
    # Select shard
    # ================================================================== #

    def _select_shard(self) -> bool:
        """
        Select the first existing shard with available capacity.

        If all existing shards are full, create a new shard.
        """

        if self.dry_run:
            return False

        discovered = self._discover_shards()

        # -------------------------------------------------------------- #
        # Prefer existing shards with capacity.
        # -------------------------------------------------------------- #

        for number, tag, release_id in discovered:
            self._load_release(
                tag,
                release_id,
            )

            if self._asset_count < self.max_assets_per_release:
                _log.info(
                    "Using release shard %s "
                    "(%d/%d assets)",
                    tag,
                    self._asset_count,
                    self.max_assets_per_release,
                )

                return True

        # -------------------------------------------------------------- #
        # All existing shards are full.
        # Create the next shard.
        # -------------------------------------------------------------- #

        next_number = 1

        if discovered:
            next_number = max(
                item[0]
                for item in discovered
            ) + 1

        created = self._create_release(
            next_number
        )

        if created is None:
            return False

        tag, release_id = created

        self._load_release(
            tag,
            release_id,
        )

        return True

    # ================================================================== #
    # Public release initializer
    # ================================================================== #

    def ensure_release(self) -> int | None:
        """
        Ensure a usable release shard is selected.

        Returns the current release ID.
        """

        if self.dry_run:
            _log.warning(
                "No GITHUB_TOKEN — running uploader "
                "in dry-run mode"
            )
            return None

        if (
            self._release_id is not None
            and self._asset_count < self.max_assets_per_release
        ):
            return self._release_id

        if self._select_shard():
            return self._release_id

        return None

    # ================================================================== #
    # Delete asset
    # ================================================================== #

    def _delete_asset(
        self,
        name: str,
    ) -> bool:
        """
        Delete an existing release asset.
        """

        if self._release_id is None:
            return False

        asset_id = self._asset_ids.get(name)

        if asset_id is None:
            # Refresh in case the local cache is stale.
            self._load_release(
                self._release_tag or "",
                self._release_id,
            )

            asset_id = self._asset_ids.get(name)

        if asset_id is None:
            self._existing.pop(name, None)
            return True

        url = (
            f"{GITHUB_API}/repos/"
            f"{self.owner}/{self.repo}"
            f"/releases/assets/{asset_id}"
        )

        try:
            response = requests.delete(
                url,
                headers=self._headers(),
                timeout=30,
            )
        except requests.RequestException as exc:
            _log.warning(
                "Delete failed for %s: %s",
                name,
                exc,
            )
            return False

        if response.status_code not in (204, 404):
            _log.warning(
                "Failed deleting asset %s: "
                "HTTP %s %s",
                name,
                response.status_code,
                response.text[:500],
            )
            return False

        self._existing.pop(name, None)
        self._asset_ids.pop(name, None)

        self._asset_count = max(
            0,
            self._asset_count - 1,
        )

        _log.info(
            "Deleted existing asset %s from %s",
            name,
            self._release_tag,
        )

        return True

    # ================================================================== #
    # Upload
    # ================================================================== #

    def _upload_request(
        self,
        path: Path,
        name: str,
    ) -> requests.Response:
        """
        Upload one file to the current release.
        """

        if self._release_id is None:
            raise RuntimeError(
                "No release selected"
            )

        encoded_name = quote(
            name,
            safe="",
        )

        url = (
            f"{GITHUB_UPLOADS}/repos/"
            f"{self.owner}/{self.repo}"
            f"/releases/{self._release_id}"
            f"/assets?name={encoded_name}"
        )

        headers = {
            **self._headers(),
            "Content-Type": "image/webp",
        }

        with path.open("rb") as fh:
            return requests.post(
                url,
                headers=headers,
                data=fh,
                timeout=180,
            )

    # ================================================================== #

    def upload_file(
        self,
        path: Path,
        name: str,
    ) -> bool:
        """
        Upload one WebP.

        Returns:

            True
                uploaded/replaced

            False
                skipped or failed
        """

        if not path.exists():
            _log.warning(
                "Missing image file: %s",
                path,
            )
            return False

        size = path.stat().st_size

        # -------------------------------------------------------------- #
        # Dry run
        # -------------------------------------------------------------- #

        if self.dry_run:
            _log.info(
                "[dry-run] Would upload %s as %s",
                path,
                name,
            )
            return False

        # -------------------------------------------------------------- #
        # Find a release shard.
        # -------------------------------------------------------------- #

        if not self.ensure_release():
            _log.error(
                "No available GitHub release shard "
                "for %s",
                name,
            )
            return False

        # -------------------------------------------------------------- #
        # Check current release for the asset.
        # -------------------------------------------------------------- #

        existing_size = self._existing.get(name)

        if existing_size == size:
            _log.debug(
                "Skipping unchanged asset: %s",
                name,
            )
            return False

        # -------------------------------------------------------------- #
        # Existing asset has changed.
        # Delete it before uploading.
        # -------------------------------------------------------------- #

        if name in self._existing:
            _log.info(
                "Replacing changed asset %s "
                "(old=%d, new=%d)",
                name,
                existing_size or 0,
                size,
            )

            if not self._delete_asset(name):
                return False

        # -------------------------------------------------------------- #
        # Make sure this shard has capacity.
        #
        # Deleting an existing asset frees one slot.
        # New assets require one free slot.
        # -------------------------------------------------------------- #

        if self._asset_count >= self.max_assets_per_release:
            _log.info(
                "Release %s is full (%d/%d). "
                "Switching shard.",
                self._release_tag,
                self._asset_count,
                self.max_assets_per_release,
            )

            self._release_id = None
            self._release_tag = None
            self._existing.clear()
            self._asset_ids.clear()
            self._asset_count = 0

            if not self.ensure_release():
                return False

        # -------------------------------------------------------------- #
        # Upload with retry handling.
        # -------------------------------------------------------------- #

        for attempt in range(1, MAX_UPLOAD_RETRIES + 1):

            try:
                response = self._upload_request(
                    path,
                    name,
                )

            except requests.RequestException as exc:
                _log.warning(
                    "Upload network error for %s "
                    "(attempt %d/%d): %s",
                    name,
                    attempt,
                    MAX_UPLOAD_RETRIES,
                    exc,
                )

                continue

            # ---------------------------------------------------------- #
            # Success
            # ---------------------------------------------------------- #

            if response.status_code in (200, 201):

                self._existing[name] = size

                try:
                    data = response.json()

                    asset_id = data.get("id")

                    if isinstance(asset_id, int):
                        self._asset_ids[name] = asset_id

                except ValueError:
                    pass

                self._asset_count += 1

                _log.info(
                    "Uploaded %s -> %s "
                    "(%d bytes, %d/%d)",
                    name,
                    self._release_tag,
                    size,
                    self._asset_count,
                    self.max_assets_per_release,
                )

                return True

            # ---------------------------------------------------------- #
            # 422 duplicate/collision.
            # ---------------------------------------------------------- #

            if response.status_code == 422:

                _log.warning(
                    "GitHub 422 while uploading %s: %s",
                    name,
                    response.text[:1000],
                )

                # Refresh current shard.
                if self._release_id is not None:
                    self._load_release(
                        self._release_tag or "",
                        self._release_id,
                    )

                # If duplicate exists, remove it.
                if name in self._existing:

                    if not self._delete_asset(name):
                        _log.error(
                            "Unable to delete conflicting "
                            "asset %s",
                            name,
                        )
                        return False

                    continue

                # Could be release capacity or another validation error.
                # Try another shard.
                self._release_id = None
                self._release_tag = None
                self._existing.clear()
                self._asset_ids.clear()
                self._asset_count = 0

                if not self.ensure_release():
                    return False

                continue

            # ---------------------------------------------------------- #
            # 413 / payload problem.
            # ---------------------------------------------------------- #

            if response.status_code == 413:
                _log.error(
                    "GitHub rejected %s because the upload "
                    "payload is too large: %s",
                    name,
                    response.text[:1000],
                )
                return False

            # ---------------------------------------------------------- #
            # Authentication
            # ---------------------------------------------------------- #

            if response.status_code in (401, 403):
                _log.error(
                    "GitHub authentication/permission error "
                    "for %s: HTTP %s %s",
                    name,
                    response.status_code,
                    response.text[:1000],
                )
                return False

            # ---------------------------------------------------------- #
            # Temporary server errors.
            # ---------------------------------------------------------- #

            if response.status_code in (
                500,
                502,
                503,
                504,
            ):
                _log.warning(
                    "GitHub server error uploading %s: "
                    "HTTP %s "
                    "(attempt %d/%d)",
                    name,
                    response.status_code,
                    attempt,
                    MAX_UPLOAD_RETRIES,
                )
                continue

            # ---------------------------------------------------------- #
            # Other errors.
            # ---------------------------------------------------------- #

            _log.warning(
                "Upload failed for %s: HTTP %s %s",
                name,
                response.status_code,
                response.text[:1000],
            )

            return False

        _log.error(
            "Upload permanently failed for %s "
            "after %d attempts",
            name,
            MAX_UPLOAD_RETRIES,
        )

        return False

    # ================================================================== #
    # Upload all assets
    # ================================================================== #

    def upload_assets(
        self,
        assets: Iterable[ImageAsset],
        image_dir: Path = IMAGE_OUT_DIR,
    ) -> dict[str, int]:
        """
        Upload all image renditions.

        The release limit is automatically enforced.
        """

        stats = {
            "uploaded": 0,
            "skipped": 0,
            "missing": 0,
            "failed": 0,
            "releases_used": 0,
        }

        # Materialize the iterable once.
        asset_list = list(assets)

        _log.info(
            "Starting release upload for %d food assets",
            len(asset_list),
        )

        if not self.dry_run:
            # Discover shards before uploading.
            self._select_shard()

        used_release_tags: set[str] = set()

        for asset in asset_list:

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

                # ------------------------------------------------------ #
                # Missing file
                # ------------------------------------------------------ #

                if not path.exists():

                    stats["missing"] += 1

                    _log.debug(
                        "Missing rendition: %s",
                        path,
                    )

                    continue

                # ------------------------------------------------------ #
                # Check whether the current release contains it.
                # ------------------------------------------------------ #

                before_size = self._existing.get(name)

                file_size = path.stat().st_size

                # ------------------------------------------------------ #
                # Same file = skip.
                # ------------------------------------------------------ #

                if (
                    before_size is not None
                    and before_size == file_size
                ):

                    stats["skipped"] += 1

                    if self._release_tag:
                        used_release_tags.add(
                            self._release_tag
                        )

                    continue

                # ------------------------------------------------------ #
                # Upload.
                # ------------------------------------------------------ #

                success = self.upload_file(
                    path,
                    name,
                )

                if success:

                    stats["uploaded"] += 1

                    if self._release_tag:
                        used_release_tags.add(
                            self._release_tag
                        )

                else:

                    # upload_file returns False both for:
                    #
                    #     unchanged
                    #     failure
                    #
                    # We already handled unchanged above.
                    #
                    stats["failed"] += 1

        stats["releases_used"] = len(
            used_release_tags
        )

        _log.info(
            "=================================================="
        )

        _log.info(
            "Release upload complete"
        )

        _log.info(
            "Uploaded : %d",
            stats["uploaded"],
        )

        _log.info(
            "Skipped  : %d",
            stats["skipped"],
        )

        _log.info(
            "Missing  : %d",
            stats["missing"],
        )

        _log.info(
            "Failed   : %d",
            stats["failed"],
        )

        _log.info(
            "Releases : %d",
            stats["releases_used"],
        )

        _log.info(
            "=================================================="
        )

        return stats


# ====================================================================== #
# Git repository publisher
# ====================================================================== #


class GitRepoPublisher:
    """
    Commits the images/foods tree so jsDelivr can serve it.
    """

    def __init__(
        self,
        repo_dir: Path,
        branch: str = "main",
        dry_run: bool = False,
    ) -> None:
        self.repo_dir = repo_dir
        self.branch = branch
        self.dry_run = dry_run

    def _run(
        self,
        *args: str,
    ) -> None:

        if self.dry_run:

            _log.info(
                "[dry-run] git %s",
                " ".join(args),
            )

            return

        subprocess.run(
            [
                "git",
                *args,
            ],
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

            src = (
                image_dir
                / rendition.folder
            )

            dst = (
                target
                / rendition.folder
            )

            dst.mkdir(
                parents=True,
                exist_ok=True,
            )

            if not src.exists():
                continue

            for file_path in src.glob(
                "*.webp"
            ):

                out = (
                    dst
                    / file_path.name
                )

                if (
                    not out.exists()
                    or out.stat().st_size
                    != file_path.stat().st_size
                ):

                    out.write_bytes(
                        file_path.read_bytes()
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


# ====================================================================== #
# CDN URL generation
# ====================================================================== #


def assign_urls(
    assets: dict[str, ImageAsset],
    hosting: HostingConfig,
) -> dict[str, ImageAsset]:
    """
    Mint CDN URLs for every asset from the active provider.
    """

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
