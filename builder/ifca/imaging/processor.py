"""Download -> validate -> dedupe (pHash) -> square crop -> WebP renditions."""
from __future__ import annotations

import io
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import imagehash
from PIL import Image, ImageOps, UnidentifiedImageError

from ..config import (
    IMAGE_OUT_DIR,
    IMAGE_SRC_DIR,
    MIN_SOURCE_EDGE,
    PHASH_DISTANCE_THRESHOLD,
    RENDITIONS,
)
from ..models import ImageAsset
from ..util import http, log
from .crawler import Candidate

_log = log.get("ifca.imaging.processor")

Image.MAX_IMAGE_PIXELS = 80_000_000  # decompression-bomb guard


@dataclass
class ProcessResult:
    slug: str
    asset: ImageAsset | None
    reason: str = ""


class PerceptualIndex:
    """Rejects near-duplicate photos across the whole corpus."""

    def __init__(self, threshold: int = PHASH_DISTANCE_THRESHOLD) -> None:
        self.threshold = threshold
        self._buckets: dict[str, list[tuple[imagehash.ImageHash, str]]] = {}

    @staticmethod
    def _bucket_key(h: imagehash.ImageHash) -> str:
        # First 16 bits as the bucket — near-duplicates share a prefix often
        # enough to make this a useful pre-filter without missing matches,
        # because we also probe the neighbouring buckets.
        return str(h)[:4]

    def find(self, h: imagehash.ImageHash) -> str | None:
        key = self._bucket_key(h)
        probes = {key}
        for i in range(len(key)):
            for c in "0123456789abcdef":
                probes.add(key[:i] + c + key[i + 1:])
        for p in probes:
            for other, slug in self._buckets.get(p, ()):
                if h - other <= self.threshold:
                    return slug
        return None

    def add(self, h: imagehash.ImageHash, slug: str) -> None:
        self._buckets.setdefault(self._bucket_key(h), []).append((h, slug))


def _open(data: bytes) -> Image.Image | None:
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        _log.debug("Corrupt image: %s", exc)
        return None
    return img


def square_crop(img: Image.Image) -> Image.Image:
    """Centre crop to a square, honouring EXIF orientation first."""
    img = ImageOps.exif_transpose(img)
    if img.mode not in ("RGB", "L") or img.mode == "L":
        img = img.convert("RGB")
    w, h = img.size
    edge = min(w, h)
    left = (w - edge) // 2
    top = int((h - edge) * 0.42)  # bias slightly above centre — food sits high
    top = max(0, min(top, h - edge))
    return img.crop((left, top, left + edge, top + edge))


def encode_webp(img: Image.Image, size: int, quality: int, max_bytes: int) -> bytes:
    """Resize then step quality down until the rendition fits its byte budget."""
    resized = img.resize((size, size), Image.Resampling.LANCZOS)
    q = quality
    data = b""
    for _ in range(6):
        buf = io.BytesIO()
        resized.save(buf, format="WEBP", quality=q, method=6)
        data = buf.getvalue()
        if len(data) <= max_bytes or q <= 40:
            break
        q -= 8
    return data


class ImageProcessor:
    def __init__(self, out_dir: Path = IMAGE_OUT_DIR, src_dir: Path = IMAGE_SRC_DIR) -> None:
        self.out_dir = out_dir
        self.src_dir = src_dir
        self.index = PerceptualIndex()
        for r in RENDITIONS:
            (self.out_dir / r.folder).mkdir(parents=True, exist_ok=True)
        self.src_dir.mkdir(parents=True, exist_ok=True)

    def process(self, slug: str, candidates: Iterable[Candidate]) -> ProcessResult:
        last_reason = "no candidates"
        for cand in candidates:
            if not cand.url:
                continue
            try:
                data = http.get_bytes(cand.url)
            except Exception as exc:  # noqa: BLE001
                last_reason = f"download failed: {exc}"
                continue
            img = _open(data)
            if img is None:
                last_reason = "corrupt"
                continue
            if min(img.size) < MIN_SOURCE_EDGE:
                last_reason = f"too small ({img.size[0]}x{img.size[1]})"
                continue
            phash = imagehash.phash(img)
            clash = self.index.find(phash)
            if clash and clash != slug:
                last_reason = f"duplicate of {clash}"
                continue

            square = square_crop(img)
            asset = ImageAsset(
                slug=slug, source_url=cand.url, source_name=cand.source,
                credit=cand.credit, license=cand.license, license_url=cand.license_url,
                phash=str(phash), width=img.size[0], height=img.size[1],
            )
            for r in RENDITIONS:
                blob = encode_webp(square, r.size, r.quality, r.max_bytes)
                path = self.out_dir / r.folder / f"{slug}.webp"
                path.write_bytes(blob)
                setattr(asset, f"bytes_{r.name}", len(blob))
            self.index.add(phash, slug)
            return ProcessResult(slug=slug, asset=asset)
        return ProcessResult(slug=slug, asset=None, reason=last_reason)

    def process_all(self, candidates_by_slug: dict[str, list[Candidate]]) -> dict[str, ImageAsset]:
        assets: dict[str, ImageAsset] = {}
        skipped: dict[str, str] = {}
        total = len(candidates_by_slug)
        for i, (slug, cands) in enumerate(candidates_by_slug.items(), 1):
            res = self.process(slug, cands)
            if res.asset:
                assets[slug] = res.asset
            else:
                skipped[slug] = res.reason
            if i % 100 == 0:
                _log.info("Processed %d/%d images (%d ok)", i, total, len(assets))
        _log.info("Image processing done: %d ok, %d skipped", len(assets), len(skipped))
        if skipped:
            reasons: dict[str, int] = {}
            for r in skipped.values():
                head = r.split(":")[0]
                reasons[head] = reasons.get(head, 0) + 1
            _log.info("Skip reasons: %s", reasons)
        return assets
