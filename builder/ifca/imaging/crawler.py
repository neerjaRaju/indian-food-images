"""Image discovery from open-licence sources.

Candidate order per food:
  1. an ``off_image::`` tag captured during the Open Food Facts import
  2. an ``wiki_image::`` tag captured during Wikipedia enrichment
  3. a Wikimedia Commons search on the food's name
rajendra balodiya 
Every candidate carries its licence and credit so the app can display
attribution; candidates whose licence cannot be established are dropped.
"""
from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass

from ..models import FoodRecord
from ..util import http, log

_log = log.get("ifca.imaging.crawler")

COMMONS_API = "https://commons.wikimedia.org/w/api.php"

ACCEPTED_LICENCES = re.compile(
    r"(cc[\s-]?by(?:[\s-]?sa)?|cc0|public\s*domain|pdm)", re.I
)
BLOCKED_LICENCES = re.compile(r"(non[\s-]?commercial|nc\b|nd\b|fair\s*use)", re.I)


@dataclass
class Candidate:
    url: str
    source: str
    credit: str = ""
    license: str = ""
    license_url: str = ""
    width: int = 0
    height: int = 0
    score: float = 0.0


def _tag_value(rec: FoodRecord, prefix: str) -> str | None:
    for t in rec.tags:
        if t.startswith(prefix):
            return t[len(prefix):]
    return None


def strip_image_tags(rec: FoodRecord) -> None:
    rec.tags = [t for t in rec.tags if "::" not in t]


class CommonsSearch:
    def __init__(self, per_query: int = 6) -> None:
        self.per_query = per_query

    def search(self, term: str) -> list[Candidate]:
        data = http.get_json(COMMONS_API, params={
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrsearch": f'filetype:bitmap "{term}" food',
            "gsrnamespace": 6,
            "gsrlimit": self.per_query,
            "prop": "imageinfo",
            "iiprop": "url|size|extmetadata",
            "iiurlwidth": 1600,
        })
        pages = ((data or {}).get("query") or {}).get("pages") or {}
        out: list[Candidate] = []
        for page in pages.values():
            infos = page.get("imageinfo") or []
            if not infos:
                continue
            info = infos[0]
            meta = info.get("extmetadata") or {}
            lic = (meta.get("LicenseShortName") or {}).get("value", "")
            if BLOCKED_LICENCES.search(lic) or not ACCEPTED_LICENCES.search(lic or "public domain"):
                continue
            artist = re.sub(r"<[^>]+>", "", (meta.get("Artist") or {}).get("value", "")).strip()
            out.append(Candidate(
                url=info.get("thumburl") or info.get("url", ""),
                source="wikimedia",
                credit=artist or "Wikimedia Commons contributor",
                license=lic or "Public domain",
                license_url=(meta.get("LicenseUrl") or {}).get("value", ""),
                width=int(info.get("thumbwidth") or info.get("width") or 0),
                height=int(info.get("thumbheight") or info.get("height") or 0),
                score=1.0,
            ))
        return out


class ImageCrawler:
    def __init__(self, commons: CommonsSearch | None = None, use_network: bool = True) -> None:
        self.commons = commons or CommonsSearch()
        self.use_network = use_network

    def candidates_for(self, rec: FoodRecord) -> list[Candidate]:
        out: list[Candidate] = []
        off = _tag_value(rec, "off_image::")
        if off:
            out.append(Candidate(url=off, source="openfoodfacts",
                                 credit="Open Food Facts contributors",
                                 license="CC BY-SA 3.0",
                                 license_url="https://creativecommons.org/licenses/by-sa/3.0/",
                                 score=2.0))
        wiki = _tag_value(rec, "wiki_image::")
        if wiki:
            out.append(Candidate(url=wiki, source="wikipedia",
                                 credit="Wikipedia contributors",
                                 license="CC BY-SA 4.0",
                                 license_url="https://creativecommons.org/licenses/by-sa/4.0/",
                                 score=1.5))
        if self.use_network and len(out) < 2:
            term = re.sub(r"\s*\(.*?\)\s*", "", rec.name).strip()
            try:
                out.extend(self.commons.search(term))
            except Exception as exc:  # noqa: BLE001
                _log.debug("Commons search failed for %s: %s", term, exc)
        return sorted(out, key=lambda c: (-c.score, -(c.width * c.height)))

    def crawl(self, records: Iterable[FoodRecord]) -> dict[str, list[Candidate]]:
        result: dict[str, list[Candidate]] = {}
        records = list(records)
        for i, rec in enumerate(records, 1):
            # Variants reuse their base dish's image — no separate crawl.
            if "variant" in rec.tags:
                continue
            cands = self.candidates_for(rec)
            if cands:
                result[rec.slug] = cands
            if i % 200 == 0:
                _log.info("Image discovery %d/%d (%d with candidates)", i, len(records), len(result))
        _log.info("Image candidates found for %d records", len(result))
        return result
