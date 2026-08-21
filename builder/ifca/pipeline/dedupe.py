"""Duplicate detection and merge.

Strategy (cheap -> expensive):
  1. exact barcode match  — packaged goods, authoritative
  2. exact match_key      — order-insensitive canonical token key
  3. blocked Jaccard      — records sharing a rare token are compared pairwise

Merging keeps the *highest-confidence* record as the base and back-fills every
null nutrient, name and serving from the losers, so a sparse IFCT row plus a
micronutrient-complete USDA row become one complete record.
"""
from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable

from ..models import NUTRIENT_FIELDS, FoodRecord
from ..util import log
from ..util.text import canonical_tokens, jaccard, match_key

_log = log.get("ifca.dedupe")

SIMILARITY_THRESHOLD = 0.80
SOURCE_PRIORITY = {
    "USDA-FDC": 5,
    "IFCT2017/NIN-curated": 6,
    "recipe-calculated": 4,
    "OpenFoodFacts": 3,
}


def _priority(rec: FoodRecord) -> tuple[float, int, int]:
    base = SOURCE_PRIORITY.get(rec.source.split("+")[0], 1)
    return (rec.confidence, base, rec.nutrition.filled_count())


def merge_pair(base: FoodRecord, other: FoodRecord) -> FoodRecord:
    """Back-fill ``base`` from ``other`` without overwriting anything set."""
    for field in NUTRIENT_FIELDS:
        if getattr(base.nutrition, field) is None:
            v = getattr(other.nutrition, field)
            if v is not None:
                setattr(base.nutrition, field, v)
    if not base.hindi_name and other.hindi_name:
        base.hindi_name = other.hindi_name
    if not base.description and other.description:
        base.description = other.description
    if not base.barcode and other.barcode:
        base.barcode = other.barcode
    if not base.brand and other.brand:
        base.brand = other.brand
    if not base.image and other.image:
        base.image = other.image
    if not base.ingredients and other.ingredients:
        base.ingredients = other.ingredients
        base.steps = other.steps or base.steps
    base.regional_names = {**other.regional_names, **base.regional_names}
    base.synonyms = sorted({*base.synonyms, *other.synonyms, other.name})
    base.tags = sorted({*base.tags, *other.tags})
    existing_units = {s.unit for s in base.servings}
    base.servings.extend(s for s in other.servings if s.unit not in existing_units)
    if other.source and other.source not in base.source:
        base.source = f"{base.source}|{other.source}"
    return base


def _rare_token_blocks(records: list[FoodRecord]) -> dict[str, list[int]]:
    freq: dict[str, int] = defaultdict(int)
    tokens: list[list[str]] = []
    for rec in records:
        toks = canonical_tokens(f"{rec.name} {rec.hindi_name}")
        tokens.append(toks)
        for t in set(toks):
            freq[t] += 1
    blocks: dict[str, list[int]] = defaultdict(list)
    for idx, toks in enumerate(tokens):
        if not toks:
            continue
        rare = min(set(toks), key=lambda t: freq[t])
        if freq[rare] <= 400:            # skip pathological blocks
            blocks[rare].append(idx)
    return blocks


def dedupe(records: Iterable[FoodRecord]) -> tuple[list[FoodRecord], dict[str, int]]:
    records = list(records)
    stats = {"input": len(records), "by_barcode": 0, "by_key": 0, "by_similarity": 0}

    # ---- pass 1: barcode -------------------------------------------------
    by_barcode: dict[str, FoodRecord] = {}
    rest: list[FoodRecord] = []
    for rec in records:
        if rec.barcode and len(rec.barcode) >= 8:
            hit = by_barcode.get(rec.barcode)
            if hit:
                winner, loser = (hit, rec) if _priority(hit) >= _priority(rec) else (rec, hit)
                by_barcode[rec.barcode] = merge_pair(winner, loser)
                stats["by_barcode"] += 1
            else:
                by_barcode[rec.barcode] = rec
        else:
            rest.append(rec)
    survivors = list(by_barcode.values()) + rest

    # ---- pass 2: canonical key ------------------------------------------
    by_key: dict[str, FoodRecord] = {}
    for rec in survivors:
        # Variants and packaged brands intentionally keep their own identity.
        if "variant" in rec.tags or rec.food_type == "packaged":
            key = f"__unique__{rec.slug}"
        else:
            key = f"{rec.food_type}:{match_key(rec.name)}"
        hit = by_key.get(key)
        if hit:
            winner, loser = (hit, rec) if _priority(hit) >= _priority(rec) else (rec, hit)
            by_key[key] = merge_pair(winner, loser)
            stats["by_key"] += 1
        else:
            by_key[key] = rec
    survivors = list(by_key.values())

    # ---- pass 3: blocked similarity -------------------------------------
    blocks = _rare_token_blocks(survivors)
    dead: set[int] = set()
    for _token, idxs in blocks.items():
        if len(idxs) < 2:
            continue
        for i in range(len(idxs)):
            a_i = idxs[i]
            if a_i in dead:
                continue
            a = survivors[a_i]
            if "variant" in a.tags or a.food_type == "packaged":
                continue
            ta = canonical_tokens(a.name)
            for j in range(i + 1, len(idxs)):
                b_i = idxs[j]
                if b_i in dead:
                    continue
                b = survivors[b_i]
                if b.food_type != a.food_type or "variant" in b.tags:
                    continue
                if jaccard(ta, canonical_tokens(b.name)) >= SIMILARITY_THRESHOLD:
                    if _priority(a) >= _priority(b):
                        merge_pair(a, b)
                        dead.add(b_i)
                    else:
                        merge_pair(b, a)
                        dead.add(a_i)
                        break
                    stats["by_similarity"] += 1
    survivors = [r for i, r in enumerate(survivors) if i not in dead]

    stats["output"] = len(survivors)
    _log.info("Dedupe %d -> %d (barcode=%d, key=%d, similarity=%d)",
              stats["input"], stats["output"], stats["by_barcode"],
              stats["by_key"], stats["by_similarity"])
    return survivors, stats
