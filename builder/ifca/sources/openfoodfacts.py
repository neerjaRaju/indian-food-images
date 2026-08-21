"""Open Food Facts — packaged Indian products (ODbL).

Two modes:
  * ``api``  — paged search over the OFF v2 API filtered to country=india.
  * ``dump`` — stream the public JSONL delta/full export (used in CI when the
    API rate-limits). Set ``IFCA_OFF_DUMP`` to a local or remote .jsonl.gz.

OFF is also the barcode source: every record keeps its EAN so the app's
scanner resolves offline.
"""
from __future__ import annotations

import gzip
import json
from collections.abc import Iterable, Iterator
from typing import Any

from ..config import RAW_DIR
from ..models import FoodRecord, Nutrition, ServingSize
from ..util import http
from ..util.text import clean_name, slugify, truncate
from .base import Source

API = "https://world.openfoodfacts.org/api/v2/search"
DUMP_URL = "https://static.openfoodfacts.org/data/openfoodfacts-products.jsonl.gz"

FIELDS = ",".join([
    "code", "product_name", "product_name_hi", "generic_name", "brands",
    "categories_tags", "countries_tags", "quantity", "serving_size",
    "serving_quantity", "image_url", "image_small_url", "nutriments",
    "ingredients_text", "labels_tags", "nova_group", "nutriscore_grade",
])

# OFF nutriment key -> our field, with a unit multiplier.
NUTRIMENT_MAP: dict[str, tuple[str, float]] = {
    "energy-kcal_100g": ("calories", 1.0),
    "proteins_100g": ("protein_g", 1.0),
    "carbohydrates_100g": ("carbs_g", 1.0),
    "fat_100g": ("fat_g", 1.0),
    "saturated-fat_100g": ("saturated_fat_g", 1.0),
    "fiber_100g": ("fiber_g", 1.0),
    "sugars_100g": ("sugar_g", 1.0),
    "sodium_100g": ("sodium_mg", 1000.0),        # OFF stores grams
    "salt_100g": ("__salt", 400.0),              # salt g -> sodium mg
    "potassium_100g": ("potassium_mg", 1000.0),
    "calcium_100g": ("calcium_mg", 1000.0),
    "iron_100g": ("iron_mg", 1000.0),
    "magnesium_100g": ("magnesium_mg", 1000.0),
    "vitamin-a_100g": ("vitamin_a_mcg", 1_000_000.0),
    "vitamin-c_100g": ("vitamin_c_mg", 1000.0),
    "vitamin-d_100g": ("vitamin_d_mcg", 1_000_000.0),
    "vitamin-b12_100g": ("vitamin_b12_mcg", 1_000_000.0),
    "cholesterol_100g": ("cholesterol_mg", 1000.0),
}

VEG_HINTS = ("en:vegetarian", "en:vegan", "en:green-dot")
NONVEG_HINTS = ("en:chicken", "en:meat", "en:fish", "en:seafood", "en:mutton", "en:non-vegetarian")


def _num(value: Any) -> float | None:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return f


def _nutrition(nutriments: dict[str, Any]) -> Nutrition:
    data: dict[str, float] = {}
    salt_sodium: float | None = None
    for off_key, (field, mult) in NUTRIMENT_MAP.items():
        v = _num(nutriments.get(off_key))
        if v is None:
            continue
        if field == "__salt":
            salt_sodium = v * mult
            continue
        data[field] = round(v * mult, 3)
    if "sodium_mg" not in data and salt_sodium is not None:
        data["sodium_mg"] = round(salt_sodium, 1)
    if "calories" not in data:
        kj = _num(nutriments.get("energy_100g")) or _num(nutriments.get("energy-kj_100g"))
        if kj:
            data["calories"] = round(kj / 4.184, 1)
    return Nutrition(**data)


def _diet(product: dict[str, Any]) -> str:
    labels = set(product.get("labels_tags") or []) | set(product.get("categories_tags") or [])
    if any(h in labels for h in NONVEG_HINTS):
        return "nonveg"
    if "en:vegan" in labels:
        return "vegan"
    if any(h in labels for h in VEG_HINTS):
        return "veg"
    return "veg"


def _category(product: dict[str, Any]) -> str:
    cats = product.get("categories_tags") or []
    mapping = [
        ("en:snacks", "Fast Food"), ("en:biscuits", "Snacks"), ("en:beverages", "Drinks"),
        ("en:dairies", "Vegetarian"), ("en:breakfast", "Healthy Foods"),
        ("en:sweet-snacks", "Snacks"), ("en:meals", "Fast Food"),
        ("en:cereals", "Healthy Foods"), ("en:spreads", "Vegetarian"),
    ]
    for tag, cat in mapping:
        if tag in cats:
            return cat
    return "Fast Food"


def product_to_record(product: dict[str, Any]) -> FoodRecord | None:
    name = clean_name(product.get("product_name") or product.get("generic_name") or "")
    if not name or len(name) < 3:
        return None
    nutriments = product.get("nutriments") or {}
    nut = _nutrition(nutriments)
    if not nut.calories and not nut.protein_g and not nut.carbs_g:
        return None
    brand = (product.get("brands") or "").split(",")[0].strip()
    code = str(product.get("code") or "").strip()
    display = f"{name} ({brand})" if brand and brand.lower() not in name.lower() else name
    serving_g = _num(product.get("serving_quantity")) or 30.0
    servings = [
        ServingSize("100g", "100 g", 100.0, False, 0),
        ServingSize("serving", product.get("serving_size") or f"1 serving ({serving_g:g} g)",
                    round(serving_g, 1), True, 1),
        ServingSize("piece", "1 piece / packet", round(serving_g, 1), False, 2),
        ServingSize("custom", "Custom grams", 1.0, False, 99),
    ]
    rec = FoodRecord(
        slug=slugify(f"{display}-{code[-5:]}" if code else display),
        name=display,
        hindi_name=clean_name(product.get("product_name_hi") or ""),
        category=_category(product),
        food_type="packaged",
        brand=brand,
        barcode=code,
        diet=_diet(product),
        description=truncate(product.get("generic_name") or product.get("ingredients_text") or "", 400),
        tags=["packaged", "barcode"] + ([f"nova{product['nova_group']}"] if product.get("nova_group") else []),
        nutrition=nut,
        servings=servings,
        source="OpenFoodFacts",
        source_id=code,
        source_url=f"https://world.openfoodfacts.org/product/{code}" if code else "",
        confidence=0.72,
    )
    rec.is_vegan = rec.diet == "vegan"
    return rec


class OpenFoodFactsSource(Source):
    key = "openfoodfacts"
    display_name = "Open Food Facts (packaged, India)"
    license_note = "Product data © Open Food Facts contributors, ODbL 1.0."

    def __init__(self, limit: int | None = 4000, page_size: int = 100,
                 dump_path: str | None = None) -> None:
        super().__init__(limit)
        self.page_size = page_size
        self.dump_path = dump_path

    # ---------------- API mode ----------------
    def _iter_api(self) -> Iterator[dict[str, Any]]:
        page = 1
        seen = 0
        target = self.limit or 4000
        while seen < target and page <= 60:
            data = http.get_json(API, params={
                "countries_tags_en": "india",
                "fields": FIELDS,
                "page_size": self.page_size,
                "page": page,
                "sort_by": "unique_scans_n",
            })
            products = data.get("products") or []
            if not products:
                return
            for p in products:
                seen += 1
                yield p
            self.log.info("OFF page %d -> %d products (total %d)", page, len(products), seen)
            page += 1

    # ---------------- Dump mode ----------------
    def _iter_dump(self) -> Iterator[dict[str, Any]]:
        src = self.dump_path or DUMP_URL
        if src.startswith("http"):
            local = RAW_DIR / "off-products.jsonl.gz"
            http.download_to(src, local)
        else:
            local = RAW_DIR / src
        with gzip.open(local, "rt", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    p = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "en:india" in (p.get("countries_tags") or []):
                    yield p

    def fetch(self) -> Iterable[FoodRecord]:
        it = self._iter_dump() if self.dump_path else self._iter_api()
        for product in it:
            rec = product_to_record(product)
            if rec:
                # keep the OFF image URL as an image candidate for the imaging stage
                img = product.get("image_url") or product.get("image_small_url")
                if img:
                    rec.source_url = rec.source_url or img
                    rec.tags.append(f"off_image::{img}")
                yield rec
