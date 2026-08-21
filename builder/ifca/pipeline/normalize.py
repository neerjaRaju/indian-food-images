"""Normalisation: canonical names, categories, diet flags, synonyms, servings."""
from __future__ import annotations

import datetime as dt
from collections.abc import Iterable

from ..models import SERVING_UNITS, FoodRecord, ServingSize
from ..util import log
from ..util.text import clean_name, slugify

_log = log.get("ifca.normalize")

CANONICAL_CATEGORIES: tuple[str, ...] = (
    "North Indian", "South Indian", "Gujarati", "Punjabi", "Bengali",
    "Maharashtrian", "Rajasthani", "Kashmiri", "Assamese", "Odia", "Bihari",
    "Goan", "Vegetarian", "Vegan", "Jain", "Seafood", "Chicken", "Mutton",
    "Eggs", "Fast Food", "Healthy Foods", "Snacks", "Sweets", "Drinks",
    "Fruits", "Vegetables", "Dairy", "Street Food", "Recipes", "Packaged",
    "Restaurant",
)

_CATEGORY_LOOKUP = {c.lower(): c for c in CANONICAL_CATEGORIES}

# Secondary categories every row also belongs to, derived from tags/diet.
DERIVED_CATEGORY_RULES = (
    (lambda r: r.diet == "vegan" or r.is_vegan, "Vegan"),
    (lambda r: r.is_jain, "Jain"),
    (lambda r: r.diet in ("veg", "vegan"), "Vegetarian"),
    (lambda r: r.diet == "egg", "Eggs"),
    (lambda r: "chicken" in r.name.lower(), "Chicken"),
    (lambda r: "mutton" in r.name.lower() or "lamb" in r.name.lower(), "Mutton"),
    (lambda r: any(t in r.tags for t in ("seafood", "coastal")) or "fish" in r.name.lower()
     or "prawn" in r.name.lower(), "Seafood"),
    (lambda r: "sweet" in r.tags, "Sweets"),
    (lambda r: "snack" in r.tags or "namkeen" in r.tags, "Snacks"),
    (lambda r: "beverage" in r.tags, "Drinks"),
    (lambda r: "fruit" in r.tags, "Fruits"),
    (lambda r: "vegetable" in r.tags and r.food_type == "food"
     and "ingredient" in r.tags, "Vegetables"),
    (lambda r: "dairy" in r.tags, "Dairy"),
    (lambda r: "street" in r.tags, "Street Food"),
    (lambda r: "healthy" in r.tags, "Healthy Foods"),
    (lambda r: r.food_type == "recipe", "Recipes"),
    (lambda r: r.food_type == "packaged", "Packaged"),
    (lambda r: r.food_type == "restaurant" or "restaurant" in r.tags, "Restaurant"),
)


def canonical_category(value: str) -> str:
    v = (value or "").strip()
    return _CATEGORY_LOOKUP.get(v.lower(), v if v in CANONICAL_CATEGORIES else "North Indian")


def derived_categories(rec: FoodRecord) -> list[str]:
    out: list[str] = [rec.category]
    for pred, cat in DERIVED_CATEGORY_RULES:
        try:
            if pred(rec) and cat not in out:
                out.append(cat)
        except Exception:  # noqa: BLE001 - a bad predicate must not kill the build
            continue
    return out


def _fix_servings(rec: FoodRecord) -> None:
    valid: list[ServingSize] = []
    seen = set()
    for s in rec.servings:
        unit = s.unit if s.unit in SERVING_UNITS else "serving"
        if unit in seen:
            continue
        grams = float(s.grams or 0)
        if unit != "custom" and grams <= 0:
            continue
        if unit != "custom" and grams > 2000:
            grams = 2000.0
        seen.add(unit)
        valid.append(ServingSize(unit, s.label or unit, round(grams, 1), s.is_default, s.sort_order))
    if not any(s.unit == "100g" for s in valid):
        valid.insert(0, ServingSize("100g", "100 g", 100.0, False, 0))
    if not any(s.is_default for s in valid):
        target = next((s for s in valid if s.unit not in ("100g", "custom")), valid[0])
        target.is_default = True
    if not any(s.unit == "custom" for s in valid):
        valid.append(ServingSize("custom", "Custom grams", 1.0, False, 99))
    valid.sort(key=lambda s: s.sort_order)
    rec.servings = valid


def normalize(records: Iterable[FoodRecord], *, today: str | None = None) -> list[FoodRecord]:
    stamp = today or dt.date.today().isoformat()
    out: list[FoodRecord] = []
    slugs: dict[str, int] = {}
    for rec in records:
        rec.name = clean_name(rec.name, strip_parens=False)
        if not rec.name:
            continue
        rec.category = canonical_category(rec.category)
        rec.hindi_name = (rec.hindi_name or "").strip()
        rec.tags = sorted({t.strip() for t in rec.tags if t and t.strip()})
        rec.synonyms = sorted({
            s.strip() for s in rec.synonyms
            if s and s.strip() and s.strip().lower() != rec.name.lower()
        })
        rec.regional_names = {k: v.strip() for k, v in (rec.regional_names or {}).items() if v}
        if rec.diet == "vegan":
            rec.is_vegan = True
        if rec.is_vegan and rec.diet == "veg":
            rec.diet = "vegan"
        rec.last_updated = rec.last_updated or stamp
        _fix_servings(rec)

        base = rec.slug or slugify(rec.name)
        n = slugs.get(base, 0)
        slugs[base] = n + 1
        rec.slug = base if n == 0 else f"{base}_{n + 1}"
        out.append(rec)
    _log.info("Normalized %d records", len(out))
    return out
