"""Rate-limit and shard-selection behaviour of the GitHub release uploader.

These tests exist because of a real failure: a weekly run died with

    HTTP 403: API rate limit exceeded for installation

two thirds of the way through publishing images, leaving a half-populated
release. Every test below pins one of the behaviours that turns that into
either a wait or a clear, immediate error.
"""

from __future__ import annotations

import time

import pytest

from ifca.imaging import uploader as up
from ifca.imaging.uploader import GitHubPermissionError, GitHubReleaseUploader


class FakeResponse:
    def __init__(
        self,
        status_code: int = 200,
        headers: dict | None = None,
        payload: object = None,
        text: str = "",
    ) -> None:
        self.status_code = status_code
        self.headers = headers or {}
        self._payload = payload
        self.text = text

    def json(self) -> object:
        return self._payload


class FakeSession:
    """Replays a scripted list of responses and records the calls."""

    def __init__(self, responses: list[FakeResponse]) -> None:
        self._responses = list(responses)
        self.calls: list[tuple[str, str]] = []

    def request(self, method, url, **kwargs):
        self.calls.append((method, url))
        if not self._responses:
            raise AssertionError(f"unexpected extra request: {method} {url}")
        return self._responses.pop(0)


@pytest.fixture
def no_sleep(monkeypatch):
    """Make the uploader's waits instant, but record how long it asked for."""
    slept: list[float] = []
    monkeypatch.setattr(up.time, "sleep", slept.append)
    return slept


def make_uploader(responses, **kwargs) -> GitHubReleaseUploader:
    u = GitHubReleaseUploader(
        "owner", "images", "images-latest", token="t", **kwargs,
    )
    u._session = FakeSession(responses)
    return u


# ---------------------------------------------------------------------- #
# Telling throttling apart from a permission failure
# ---------------------------------------------------------------------- #


def test_exhausted_quota_is_rate_limiting_not_permission():
    response = FakeResponse(
        403,
        {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1"},
        text="API rate limit exceeded for installation.",
    )
    assert GitHubReleaseUploader._is_rate_limited(response) is True


def test_retry_after_header_is_rate_limiting():
    assert GitHubReleaseUploader._is_rate_limited(
        FakeResponse(403, {"retry-after": "30"})
    ) is True


def test_secondary_limit_message_is_rate_limiting():
    assert GitHubReleaseUploader._is_rate_limited(
        FakeResponse(403, text="You have exceeded a secondary rate limit.")
    ) is True


def test_plain_forbidden_is_not_rate_limiting():
    assert GitHubReleaseUploader._is_rate_limited(
        FakeResponse(403, text="Resource not accessible by integration")
    ) is False


# ---------------------------------------------------------------------- #
# Waiting instead of dying
# ---------------------------------------------------------------------- #


def test_rate_limited_request_is_retried_after_waiting(no_sleep):
    u = make_uploader([
        FakeResponse(403, {"retry-after": "5"}, text="rate limit"),
        FakeResponse(200, {"x-ratelimit-remaining": "900"}, payload={"ok": True}),
    ])

    response = u._api("GET", "https://api.github.com/x")

    assert response is not None
    assert response.status_code == 200
    assert len(no_sleep) == 1
    assert 5 <= no_sleep[0] <= 11  # the header, plus padding and jitter


def test_retry_delay_prefers_retry_after_over_reset():
    response = FakeResponse(
        403,
        {"retry-after": "42", "x-ratelimit-reset": str(int(time.time()) + 9999)},
    )
    assert 42 <= GitHubReleaseUploader._retry_delay(response) <= 48


def test_retry_delay_falls_back_to_reset_header():
    response = FakeResponse(403, {"x-ratelimit-reset": str(int(time.time()) + 100)})
    assert 95 <= GitHubReleaseUploader._retry_delay(response) <= 110


def test_retry_delay_is_capped():
    response = FakeResponse(403, {"retry-after": "999999"})
    assert GitHubReleaseUploader._retry_delay(response) == up.RATE_LIMIT_MAX_WAIT


def test_nearly_spent_window_pauses_before_hitting_zero(no_sleep):
    u = make_uploader([
        FakeResponse(
            200,
            {
                "x-ratelimit-remaining": "1",
                "x-ratelimit-reset": str(int(time.time()) + 30),
            },
            payload={},
        ),
    ])

    u._api("GET", "https://api.github.com/x")

    assert no_sleep, "should have paused with only one request left"


def test_healthy_window_does_not_pause(no_sleep):
    u = make_uploader([
        FakeResponse(200, {"x-ratelimit-remaining": "4000"}, payload={}),
    ])

    u._api("GET", "https://api.github.com/x")

    assert no_sleep == []


# ---------------------------------------------------------------------- #
# A bad token stops the run immediately
# ---------------------------------------------------------------------- #


def test_permission_failure_is_fatal_and_names_the_fix():
    u = make_uploader([
        FakeResponse(403, text="Resource not accessible by integration"),
    ])

    u._api("GET", "https://api.github.com/x")

    assert u._fatal is not None
    assert "IMAGES_TOKEN" in u._fatal

    # And every later call refuses to spend more quota.
    with pytest.raises(GitHubPermissionError):
        u._api("GET", "https://api.github.com/y")


def test_preflight_rejects_a_repo_the_token_cannot_push_to():
    u = make_uploader([
        FakeResponse(200, payload={"permissions": {"pull": True, "push": False}}),
    ])

    assert u.preflight() is False
    assert "contents: write" in (u._fatal or "")


def test_preflight_explains_a_404_as_a_token_scope_problem():
    u = make_uploader([FakeResponse(404, payload={})])

    assert u.preflight() is False
    assert "installation token" in (u._fatal or "")


def test_preflight_passes_for_a_writable_repo():
    u = make_uploader([
        FakeResponse(200, payload={"permissions": {"push": True}}),
    ])

    assert u.preflight() is True
    assert u._fatal is None


def test_upload_aborts_up_front_when_preflight_fails(tmp_path):
    u = make_uploader([FakeResponse(404, payload={})])

    stats = u.upload_assets([])

    assert stats["aborted"] == 1
    assert stats["uploaded"] == 0


# ---------------------------------------------------------------------- #
# Request economy
# ---------------------------------------------------------------------- #


def _release(number: int, asset_count: int) -> dict:
    return {
        "tag_name": f"images-latest-{number:03d}",
        "id": 1000 + number,
        "assets": [
            {"name": f"medium_food{i}.webp", "size": 100 + i, "id": 5000 + i}
            for i in range(asset_count)
        ],
    }


def test_shard_selection_costs_one_request_regardless_of_shard_count():
    """The old code paged every shard's assets just to count them."""
    u = make_uploader([
        FakeResponse(
            200,
            {"x-ratelimit-remaining": "900"},
            payload=[_release(1, 3), _release(2, 3), _release(3, 1)],
        ),
    ])
    u.max_assets_per_release = 3

    assert u._select_shard() is True

    # One list-releases call. Nothing else.
    assert len(u._session.calls) == 1
    # First shard with capacity is the third; the first two are full.
    assert u._release_tag == "images-latest-003"
    assert u._asset_count == 1


def test_selected_shard_carries_its_asset_sizes_without_extra_calls():
    u = make_uploader([
        FakeResponse(200, {"x-ratelimit-remaining": "900"}, payload=[_release(1, 2)]),
    ])

    assert u._select_shard() is True
    assert u._existing == {"medium_food0.webp": 100, "medium_food1.webp": 101}
    assert u._asset_ids == {"medium_food0.webp": 5000, "medium_food1.webp": 5001}


def test_deleting_an_uncached_asset_makes_no_request():
    u = make_uploader([])
    u._release_id = 1
    u._release_tag = "images-latest-001"

    assert u._delete_asset("not_here.webp") is True
    assert u._session.calls == []
