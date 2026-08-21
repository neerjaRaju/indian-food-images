"""Polite, cached, retrying HTTP client used by every crawler."""
from __future__ import annotations

import hashlib
import json
import random
import time
from pathlib import Path
from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from ..config import CACHE_DIR, HTTP_RETRIES, HTTP_TIMEOUT, USER_AGENT
from . import log

_log = log.get("ifca.http")

_session: requests.Session | None = None
_last_call: dict[str, float] = {}
MIN_INTERVAL = 0.12  # seconds between calls to the same host


def session() -> requests.Session:
    global _session
    if _session is None:
        s = requests.Session()
        s.headers.update({"User-Agent": USER_AGENT, "Accept-Encoding": "gzip, deflate"})
        retry = Retry(
            total=HTTP_RETRIES,
            backoff_factor=0.8,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset({"GET", "HEAD"}),
            respect_retry_after_header=True,
        )
        adapter = HTTPAdapter(max_retries=retry, pool_connections=32, pool_maxsize=32)
        s.mount("https://", adapter)
        s.mount("http://", adapter)
        _session = s
    return _session


def _throttle(url: str) -> None:
    host = url.split("/")[2] if "://" in url else url
    now = time.monotonic()
    prev = _last_call.get(host, 0.0)
    wait = MIN_INTERVAL - (now - prev)
    if wait > 0:
        time.sleep(wait + random.uniform(0, 0.05))
    _last_call[host] = time.monotonic()


def _cache_path(url: str, suffix: str) -> Path:
    key = hashlib.sha256(url.encode("utf-8")).hexdigest()[:32]
    return CACHE_DIR / f"{key}{suffix}"


def get_bytes(url: str, *, cache: bool = True, timeout: int = HTTP_TIMEOUT) -> bytes:
    cp = _cache_path(url, ".bin")
    if cache and cp.exists():
        return cp.read_bytes()
    _throttle(url)
    r = session().get(url, timeout=timeout, stream=True)
    r.raise_for_status()
    data = r.content
    if cache:
        cp.write_bytes(data)
    return data


def get_text(url: str, *, cache: bool = True, timeout: int = HTTP_TIMEOUT) -> str:
    return get_bytes(url, cache=cache, timeout=timeout).decode("utf-8", "replace")


def get_json(
    url: str,
    *,
    params: dict[str, Any] | None = None,
    cache: bool = True,
    timeout: int = HTTP_TIMEOUT,
) -> Any:
    if params:
        from urllib.parse import urlencode

        url = f"{url}{'&' if '?' in url else '?'}{urlencode(params)}"
    cp = _cache_path(url, ".json")
    if cache and cp.exists():
        try:
            return json.loads(cp.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            cp.unlink(missing_ok=True)
    _throttle(url)
    r = session().get(url, timeout=timeout)
    r.raise_for_status()
    data = r.json()
    if cache:
        cp.write_text(json.dumps(data), encoding="utf-8")
    return data


def head_ok(url: str, timeout: int = 20) -> bool:
    """Used by the URL verifier. Falls back to a ranged GET for CDNs that 405 HEAD."""
    try:
        _throttle(url)
        r = session().head(url, timeout=timeout, allow_redirects=True)
        if r.status_code == 405:
            r = session().get(url, timeout=timeout, headers={"Range": "bytes=0-0"}, stream=True)
        return r.status_code in (200, 206)
    except requests.RequestException as exc:  # pragma: no cover - network dependent
        _log.debug("HEAD failed for %s: %s", url, exc)
        return False


def download_to(url: str, dest: Path, *, timeout: int = HTTP_TIMEOUT) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    _throttle(url)
    with session().get(url, timeout=timeout, stream=True) as r:
        r.raise_for_status()
        tmp = dest.with_suffix(dest.suffix + ".part")
        with tmp.open("wb") as fh:
            for chunk in r.iter_content(1 << 16):
                fh.write(chunk)
        tmp.replace(dest)
    return dest
