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

import contextlib
import os
import random
import subprocess
import time
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

# ---------------------------------------------------------------------- #
# Rate limiting
#
# GitHub's limits are the binding constraint on this pipeline, not
# bandwidth. The numbers that matter:
#
#     GITHUB_TOKEN (a GitHub App installation token)
#         1,000 requests/hour *per repository*, and no access at all to a
#         repository outside the workflow's own. Publishing images to a
#         separate images repo therefore needs a PAT, not GITHUB_TOKEN.
#
#     Personal access token
#         5,000 requests/hour, plus an undocumented "secondary" limit on
#         bursts of content-creating requests.
#
# Both are reported the same way: HTTP 403 (sometimes 429) with either a
# Retry-After header or x-ratelimit-remaining: 0 plus x-ratelimit-reset.
# We wait those out rather than failing the run, because a half-published
# image release is worse than a slow one.
# ---------------------------------------------------------------------- #

# Never sleep longer than this for one rate-limit response.
RATE_LIMIT_MAX_WAIT = 15 * 60

# How many times one request may be re-sent after a rate-limit response.
MAX_RATE_LIMIT_RETRIES = 5

# Sleep when fewer than this many requests remain in the window, so a burst
# of uploads does not slam into the wall mid-shard.
RATE_LIMIT_FLOOR = 25


class GitHubPermissionError(RuntimeError):
    """Raised when the token cannot act on the images repository at all."""


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

        # One connection pool for every call to GitHub.
        self._session = requests.Session()

        # Set once the token is proven unable to write here. Every
        # subsequent call short-circuits instead of burning more quota.
        self._fatal: str | None = None

        # Requests issued, for the end-of-run summary.
        self._api_calls = 0

        # Seconds spent parked on rate limits.
        self._rate_limited_seconds = 0.0

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

    # ------------------------------------------------------------------ #
    # Rate-limit interpretation
    # ------------------------------------------------------------------ #

    @staticmethod
    def _is_rate_limited(
        response: requests.Response,
    ) -> bool:
        """
        Distinguish "you are going too fast" from "you may not do this".

        Both arrive as HTTP 403, and treating the first as the second is
        exactly how a run ends up dying two thirds of the way through a
        shard.
        """

        if response.status_code not in (403, 429):
            return False

        if response.headers.get("x-ratelimit-remaining") == "0":
            return True

        if response.headers.get("retry-after"):
            return True

        body = response.text[:1000].lower()

        return (
            "rate limit" in body
            or "secondary rate" in body
            or "abuse detection" in body
        )

    @staticmethod
    def _retry_delay(
        response: requests.Response,
    ) -> float:
        """
        How long to wait before re-sending a rate-limited request.

        Retry-After wins when present; otherwise x-ratelimit-reset gives
        the wall-clock second the window rolls over.
        """

        retry_after = response.headers.get("retry-after")

        if retry_after:
            try:
                wait = float(retry_after)
            except ValueError:
                wait = 60.0
        else:
            wait = 60.0

            reset = response.headers.get("x-ratelimit-reset")

            if reset:
                with contextlib.suppress(ValueError):
                    wait = float(reset) - time.time()

        # A little padding, a little jitter: several jobs may be waiting
        # on the same reset and should not all resume in the same second.
        wait = wait + 2.0 + random.uniform(0, 3)

        return max(1.0, min(wait, RATE_LIMIT_MAX_WAIT))

    def _respect_remaining_budget(
        self,
        response: requests.Response,
    ) -> None:
        """
        Pause *before* hitting zero when the window is nearly spent.
        """

        remaining = response.headers.get("x-ratelimit-remaining")
        reset = response.headers.get("x-ratelimit-reset")

        if not remaining or not reset:
            return

        try:
            left = int(remaining)
            resets_at = float(reset)
        except ValueError:
            return

        if left > RATE_LIMIT_FLOOR:
            return

        wait = min(
            max(resets_at - time.time() + 2.0, 1.0),
            RATE_LIMIT_MAX_WAIT,
        )

        _log.warning(
            "Only %d GitHub requests left in this window; "
            "sleeping %.0fs for the reset",
            left,
            wait,
        )

        self._rate_limited_seconds += wait

        time.sleep(wait)

    # ------------------------------------------------------------------ #
    # The one place a GitHub request is made
    # ------------------------------------------------------------------ #

    def _api(
        self,
        method: str,
        url: str,
        **kwargs: object,
    ) -> requests.Response | None:
        """
        Issue one GitHub request, waiting out rate limits.

        Returns None when the request could not be completed at all
        (network failure, or the limit outlasted our patience). A returned
        response may still carry an error status — callers interpret it.

        Raises GitHubPermissionError when the token is not allowed to act
        on this repository, because retrying that is pointless and the
        rest of the run should stop immediately.
        """

        if self._fatal:
            raise GitHubPermissionError(self._fatal)

        kwargs.setdefault("timeout", 30)

        headers = {
            **self._headers(),
            **(kwargs.pop("headers", None) or {}),  # type: ignore[dict-item]
        }

        response: requests.Response | None = None

        for attempt in range(1, MAX_RATE_LIMIT_RETRIES + 1):

            try:
                self._api_calls += 1

                response = self._session.request(
                    method,
                    url,
                    headers=headers,
                    **kwargs,  # type: ignore[arg-type]
                )

            except requests.RequestException as exc:
                _log.warning(
                    "%s %s failed: %s",
                    method,
                    url,
                    exc,
                )
                return None

            if not self._is_rate_limited(response):

                if response.status_code in (401, 403):
                    self._note_permission_failure(response)

                self._respect_remaining_budget(response)

                return response

            if attempt == MAX_RATE_LIMIT_RETRIES:
                break

            wait = self._retry_delay(response)

            _log.warning(
                "GitHub rate limit on %s %s — waiting %.0fs "
                "(attempt %d/%d)",
                method,
                url,
                wait,
                attempt,
                MAX_RATE_LIMIT_RETRIES,
            )

            self._rate_limited_seconds += wait

            time.sleep(wait)

        _log.error(
            "Gave up on %s %s after %d rate-limited attempts",
            method,
            url,
            MAX_RATE_LIMIT_RETRIES,
        )

        return response

    def _note_permission_failure(
        self,
        response: requests.Response,
    ) -> None:
        """
        Turn a genuine 401/403 into a single, readable, fatal message.
        """

        hint = (
            f"{response.status_code} from GitHub for "
            f"{self.owner}/{self.repo}. "
        )

        if not self.token:
            hint += "No token was supplied."
        else:
            hint += (
                "The token cannot write releases here. Fixes, most likely "
                "first: (1) give the fine-grained PAT in IMAGES_TOKEN "
                "`Contents: Read and write` on "
                f"{self.owner}/{self.repo} — Read-only is not enough, and "
                "the releases API needs Contents, not Administration; "
                "(2) check the token's Repository access actually lists "
                "that repository; (3) if the owner is an organisation, "
                "check the token is not still awaiting owner approval; "
                "(4) if this is GITHUB_TOKEN, it cannot reach any "
                "repository other than the one the workflow runs in."
            )

        self._fatal = hint

        _log.error("%s", hint)

    # ------------------------------------------------------------------ #
    # Preflight
    # ------------------------------------------------------------------ #

    def preflight(self) -> bool:
        """
        Prove, in one request, that we can reach the images repository.

        Cheap insurance: without it the first sign of a bad token is a
        wall of failures several thousand uploads deep.
        """

        if self.dry_run:
            return True

        try:
            response = self._api(
                "GET",
                f"{GITHUB_API}/repos/{self.owner}/{self.repo}",
            )
        except GitHubPermissionError:
            return False

        if response is None:
            _log.error(
                "Could not reach %s/%s",
                self.owner,
                self.repo,
            )
            return False

        if response.status_code == 404:
            self._fatal = (
                f"{self.owner}/{self.repo} does not exist, or the token "
                "cannot see it. A GitHub App installation token returns "
                "404 for repositories it was not installed on."
            )
            _log.error("%s", self._fatal)
            return False

        if response.status_code != 200:
            _log.error(
                "Preflight on %s/%s failed: HTTP %s %s",
                self.owner,
                self.repo,
                response.status_code,
                response.text[:500],
            )
            return False

        permissions = response.json().get("permissions") or {}

        # A warning, deliberately not a failure.
        #
        # GitHub documents this object as the authenticated token's
        # capabilities, but it predates fine-grained PATs and there is no
        # supported way to introspect one's grants. In practice `push` can
        # read false for a token that really does hold Contents: write, and
        # refusing to start on that basis blocks a correctly configured run.
        #
        # The authoritative test is a write, so we let the first one decide:
        # creating or reusing a release shard is the uploader's very next
        # step, and a genuine 403 there aborts the run through
        # _note_permission_failure a couple of seconds later.
        if permissions and not permissions.get("push", False):
            _log.warning(
                "%s/%s reports no write access for this token "
                "(permissions=%s). Continuing anyway — this field is "
                "unreliable for fine-grained PATs. If the upload fails "
                "with 403, grant the token `Contents: Read and write` on "
                "that repository.",
                self.owner,
                self.repo,
                permissions,
            )
            return True

        _log.info(
            "Preflight OK: %s/%s is reachable",
            self.owner,
            self.repo,
        )

        return True

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

    def _discover_shards(self) -> list[dict]:
        """
        Discover all existing releases matching our prefix.

        The list-releases response already embeds each release's assets,
        so this is the only place we need to ask. The previous version
        called _load_release() on every shard just to count its assets —
        ten paged requests per shard, before a single byte was uploaded,
        which on its own could exhaust an installation token's hourly
        budget.

        Returns, ordered by shard number:

            [
                {
                    "number": 1,
                    "tag": "images-latest-001",
                    "id": 123,
                    "sizes": {"medium_dosa.webp": 41231, ...},
                    "asset_ids": {"medium_dosa.webp": 9988, ...},
                },
            ]
        """

        if self.dry_run:
            return []

        releases: list[dict] = []

        page = 1

        while True:
            response = self._api(
                "GET",
                self._release_url,
                params={
                    # Each release object carries its whole asset array,
                    # so a large per_page makes for a very large body.
                    "per_page": 30,
                    "page": page,
                },
            )

            if response is None:
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

            if len(batch) < 30:
                break

            page += 1

        discovered: list[dict] = []

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

            if not isinstance(release_id, int):
                continue

            sizes, asset_ids = self._index_assets(
                release.get("assets")
            )

            discovered.append(
                {
                    "number": int(suffix),
                    "tag": tag,
                    "id": release_id,
                    "sizes": sizes,
                    "asset_ids": asset_ids,
                }
            )

        discovered.sort(key=lambda item: item["number"])

        _log.info(
            "Discovered %d image release shards in %d request(s)",
            len(discovered),
            page,
        )

        return discovered

    @staticmethod
    def _index_assets(
        assets: object,
    ) -> tuple[dict[str, int], dict[str, int]]:
        """
        Turn an asset array into name->size and name->id maps.
        """

        sizes: dict[str, int] = {}
        asset_ids: dict[str, int] = {}

        if not isinstance(assets, list):
            return sizes, asset_ids

        for asset in assets:
            if not isinstance(asset, dict):
                continue

            name = asset.get("name")
            size = asset.get("size")
            asset_id = asset.get("id")

            if not isinstance(name, str):
                continue

            if isinstance(size, int):
                sizes[name] = size

            if isinstance(asset_id, int):
                asset_ids[name] = asset_id

        return sizes, asset_ids

    # ================================================================== #
    # Load a release
    # ================================================================== #

    def _adopt_shard(
        self,
        shard: dict,
    ) -> None:
        """
        Make a shard discovered by _discover_shards() the current one.

        No network traffic: the asset maps came back with the release.
        """

        self._release_id = shard["id"]
        self._release_tag = shard["tag"]

        self._existing = dict(shard["sizes"])
        self._asset_ids = dict(shard["asset_ids"])

        self._asset_count = len(self._asset_ids)

        _log.info(
            "Using release shard %s (%d/%d assets)",
            self._release_tag,
            self._asset_count,
            self.max_assets_per_release,
        )

    def _load_release(
        self,
        tag: str,
        release_id: int,
    ) -> None:
        """
        Re-read one release and all of its assets from GitHub.

        Only used to recover from a 422 collision, where the local cache
        is known to be stale. The happy path never calls this.
        """

        self._release_id = release_id
        self._release_tag = tag

        self._existing.clear()
        self._asset_ids.clear()

        page = 1

        while True:
            response = self._api(
                "GET",
                f"{self._release_url}/{release_id}/assets",
                params={
                    "per_page": 100,
                    "page": page,
                },
            )

            if response is None:
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

            sizes, asset_ids = self._index_assets(assets)

            self._existing.update(sizes)
            self._asset_ids.update(asset_ids)

            if len(assets) < 100:
                break

            page += 1

        self._asset_count = len(self._asset_ids)

        _log.info(
            "Reloaded release %s: %d assets",
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

        response = self._api(
            "POST",
            self._release_url,
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

        if response is None:
            _log.error(
                "Failed creating release %s: no response",
                tag,
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

            lookup = self._api(
                "GET",
                f"{self._release_url}/tags/"
                f"{quote(tag, safe='')}",
            )

            if lookup is not None and lookup.status_code == 200:
                data = lookup.json()
                release_id = data.get("id")

                if isinstance(release_id, int):
                    return tag, release_id

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
        # Prefer existing shards with capacity. The asset counts came back
        # with the release list, so choosing a shard costs nothing extra.
        # -------------------------------------------------------------- #

        for shard in discovered:
            if len(shard["asset_ids"]) < self.max_assets_per_release:
                self._adopt_shard(shard)
                return True

        # -------------------------------------------------------------- #
        # All existing shards are full.
        # Create the next shard.
        # -------------------------------------------------------------- #

        next_number = 1

        if discovered:
            next_number = max(
                shard["number"]
                for shard in discovered
            ) + 1

        created = self._create_release(
            next_number
        )

        if created is None:
            return False

        tag, release_id = created

        self._adopt_shard(
            {
                "id": release_id,
                "tag": tag,
                "sizes": {},
                "asset_ids": {},
            }
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
            # Sizes and ids are always cached together, so a missing id
            # means the asset is not there. The old code re-paged the
            # whole release here — up to ten requests to learn nothing.
            self._existing.pop(name, None)
            return True

        url = (
            f"{GITHUB_API}/repos/"
            f"{self.owner}/{self.repo}"
            f"/releases/assets/{asset_id}"
        )

        response = self._api("DELETE", url)

        if response is None:
            _log.warning(
                "Delete failed for %s: no response",
                name,
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
    ) -> requests.Response | None:
        """
        Upload one file to the current release.

        The body is read into memory rather than streamed from a file
        handle: a rate-limited request gets re-sent, and a consumed handle
        would replay as an empty body.
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

        return self._api(
            "POST",
            url,
            headers={"Content-Type": "image/webp"},
            data=path.read_bytes(),
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

            response = self._upload_request(
                path,
                name,
            )

            if response is None:
                _log.warning(
                    "Upload failed for %s with no response "
                    "(attempt %d/%d)",
                    name,
                    attempt,
                    MAX_UPLOAD_RETRIES,
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

            # _api() has already waited out any rate limiting and, for a
            # genuine permission failure, recorded a fatal reason. Either
            # way there is nothing to gain by trying this file again.
            if response.status_code in (401, 403):
                if self._fatal:
                    raise GitHubPermissionError(self._fatal)

                _log.error(
                    "GitHub rejected %s after exhausting rate-limit "
                    "retries: HTTP %s %s",
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
            "aborted": 0,
            "api_calls": 0,
        }

        # Materialize the iterable once.
        asset_list = list(assets)

        _log.info(
            "Starting release upload for %d food assets",
            len(asset_list),
        )

        if not self.dry_run:
            # One request that answers "can this token publish here?"
            # before we spend an hour finding out the hard way.
            if not self.preflight():
                stats["aborted"] = 1
                stats["failed"] = len(asset_list) * len(RENDITIONS)
                stats["api_calls"] = self._api_calls
                _log.error(
                    "Aborting image upload: %s",
                    self._fatal or "images repository is not reachable",
                )
                return stats

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

                try:
                    success = self.upload_file(
                        path,
                        name,
                    )
                except GitHubPermissionError as exc:
                    # Nothing that follows can succeed either. Stop here
                    # rather than issuing thousands of doomed requests.
                    stats["aborted"] = 1
                    _log.error(
                        "Stopping image upload after %d uploads: %s",
                        stats["uploaded"],
                        exc,
                    )
                    break

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

            if stats["aborted"]:
                break

        stats["releases_used"] = len(
            used_release_tags
        )

        stats["api_calls"] = self._api_calls

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
            "API calls: %d",
            stats["api_calls"],
        )

        if self._rate_limited_seconds:
            _log.info(
                "Rate-limit wait: %.0fs",
                self._rate_limited_seconds,
            )

        if stats["aborted"]:
            _log.error(
                "Run aborted before completion: %s",
                self._fatal or "unknown reason",
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
