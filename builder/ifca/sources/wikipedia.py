"""Wikipedia / Wikidata enrichment: descriptions, regional names, image leads.

This is an *enricher*, not a standalone source: it takes records that already
exist and adds prose + multilingual names + a Commons image candidate.
Text from Wikipedia is CC BY-SA 4.0, so every enriched record records the
article URL and the licence for in-app attribution.
"""
from __future__ import annotations

from collections.abc import Iterable

from ..models import FoodRecord
from ..util import http, log
from ..util.text import truncate

WIKI_API = "https://en.wikipedia.org/w/api.php"
WIKIDATA_API = "https://www.wikidata.org/w/api.php"

LANG_CODES = {
    "hi": "hindi", "bn": "bengali", "ta": "tamil", "te": "telugu", "ml": "malayalam",
    "kn": "kannada", "mr": "marathi", "gu": "gujarati", "pa": "punjabi",
    "or": "odia", "as": "assamese", "ur": "urdu", "ne": "nepali",
}

LICENSE = "CC BY-SA 4.0"

_log = log.get("ifca.source.wikipedia")


class WikipediaEnricher:
    def __init__(self, batch: int = 20, enabled: bool = True) -> None:
        self.batch = batch
        self.enabled = enabled

    # ------------------------------------------------------------------ #
    def _query_extracts(self, titles: list[str]) -> dict[str, dict]:
        if not titles:
            return {}
        data = http.get_json(WIKI_API, params={
            "action": "query",
            "format": "json",
            "prop": "extracts|pageimages|pageprops",
            "exintro": 1,
            "explaintext": 1,
            "piprop": "original",
            "ppprop": "wikibase_item",
            "redirects": 1,
            "titles": "|".join(titles),
        })
        pages = ((data or {}).get("query") or {}).get("pages") or {}
        out: dict[str, dict] = {}
        # Follow the normalisation/redirect maps so we can key by our query title.
        alias: dict[str, str] = {}
        for m in ((data.get("query") or {}).get("normalized") or []):
            alias[m["from"]] = m["to"]
        for m in ((data.get("query") or {}).get("redirects") or []):
            alias[m["from"]] = m["to"]
        by_title = {p.get("title"): p for p in pages.values() if p.get("title")}
        for t in titles:
            resolved = alias.get(t, t)
            page = by_title.get(resolved)
            if page and "missing" not in page:
                out[t] = page
        return out

    def _labels(self, qid: str) -> dict[str, str]:
        if not qid:
            return {}
        data = http.get_json(WIKIDATA_API, params={
            "action": "wbgetentities",
            "format": "json",
            "ids": qid,
            "props": "labels",
            "languages": "|".join(LANG_CODES),
        })
        ent = ((data or {}).get("entities") or {}).get(qid) or {}
        labels = ent.get("labels") or {}
        return {LANG_CODES[k]: v["value"] for k, v in labels.items() if k in LANG_CODES}

    # ------------------------------------------------------------------ #
    def enrich(self, records: Iterable[FoodRecord]) -> list[FoodRecord]:
        records = list(records)
        if not self.enabled:
            return records
        # Only enrich canonical (non-variant, non-packaged) rows: variants
        # inherit from their base and packaged goods have no encyclopedia entry.
        targets = [r for r in records if "variant" not in r.tags and r.food_type != "packaged"]
        _log.info("Enriching %d/%d records from Wikipedia", len(targets), len(records))
        for i in range(0, len(targets), self.batch):
            chunk = targets[i:i + self.batch]
            titles = [r.name for r in chunk]
            try:
                pages = self._query_extracts(titles)
            except Exception as exc:  # noqa: BLE001
                _log.warning("Wikipedia batch failed (%s) — skipping %d records", exc, len(chunk))
                continue
            for rec in chunk:
                page = pages.get(rec.name)
                if not page:
                    continue
                extract = (page.get("extract") or "").strip()
                if extract and len(extract) > 60:
                    rec.description = truncate(extract, 700)
                    rec.source_url = rec.source_url or (
                        "https://en.wikipedia.org/wiki/" + page["title"].replace(" ", "_")
                    )
                    rec.tags.append("wiki-desc")
                original = (page.get("original") or {}).get("source")
                if original:
                    rec.tags.append(f"wiki_image::{original}")
                qid = (page.get("pageprops") or {}).get("wikibase_item")
                if qid:
                    try:
                        labels = self._labels(qid)
                    except Exception:  # noqa: BLE001
                        labels = {}
                    if labels:
                        rec.regional_names.update(labels)
                        if not rec.hindi_name and labels.get("hindi"):
                            rec.hindi_name = labels["hindi"]
                        rec.synonyms.extend(v for v in labels.values() if v)
        return records


def description_attribution(rec: FoodRecord) -> dict[str, str] | None:
    if "wiki-desc" not in rec.tags:
        return None
    return {"source": "Wikipedia", "license": LICENSE, "url": rec.source_url}
