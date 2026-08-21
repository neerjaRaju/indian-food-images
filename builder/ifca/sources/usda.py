"""USDA FoodData Central — micronutrient-complete reference foods.

Used for two jobs:
  1. Import raw ingredients / generic foods (fruits, vegetables, grains, meats)
     that carry a *full* micronutrient panel.
  2. Act as the donor pool for :mod:`ifca.pipeline.micros`, which fills the
     micronutrients that Indian composition tables publish only sparsely.

Needs ``FDC_API_KEY`` (free, instant, api.data.gov). Without it the source
logs a warning and yields nothing — the build still succeeds.
"""
from __future__ import annotations

import os
from collections.abc import Iterable
from typing import Any

from ..models import FoodRecord, Nutrition
from ..util import http
from ..util.text import clean_name, slugify, truncate
from .base import Source

SEARCH = "https://api.nal.usda.gov/fdc/v1/foods/search"

# FDC nutrient id -> (our field, multiplier to our unit)
NUTRIENT_IDS: dict[int, tuple[str, float]] = {
    1008: ("calories", 1.0),          # Energy kcal
    1003: ("protein_g", 1.0),
    1005: ("carbs_g", 1.0),
    1004: ("fat_g", 1.0),
    1258: ("saturated_fat_g", 1.0),
    1079: ("fiber_g", 1.0),
    2000: ("sugar_g", 1.0),
    1093: ("sodium_mg", 1.0),
    1092: ("potassium_mg", 1.0),
    1087: ("calcium_mg", 1.0),
    1089: ("iron_mg", 1.0),
    1090: ("magnesium_mg", 1.0),
    1106: ("vitamin_a_mcg", 1.0),     # Vitamin A, RAE
    1162: ("vitamin_c_mg", 1.0),
    1114: ("vitamin_d_mcg", 1.0),     # Vitamin D (D2 + D3)
    1178: ("vitamin_b12_mcg", 1.0),
    1253: ("cholesterol_mg", 1.0),
}

# Query terms chosen to cover the ingredient space an Indian kitchen uses.
DEFAULT_QUERIES: tuple[str, ...] = (
    "rice cooked", "wheat flour", "chickpeas", "lentils cooked", "mung beans",
    "kidney beans", "chicken breast cooked", "chicken thigh", "mutton goat",
    "lamb cooked", "egg cooked", "shrimp cooked", "fish cooked", "paneer",
    "yogurt plain", "milk whole", "ghee", "coconut", "mustard oil",
    "spinach cooked", "cauliflower cooked", "okra cooked", "eggplant cooked",
    "potato cooked", "onion raw", "tomato raw", "carrot raw", "green peas",
    "mango raw", "banana raw", "papaya raw", "guava", "pomegranate",
    "almonds", "cashew nuts", "peanuts", "sesame seeds", "jaggery",
    "millet cooked", "sorghum", "oats", "semolina", "tamarind", "curry powder",
    "turmeric", "cumin seed", "coriander seed", "ginger raw", "garlic raw",
    "green chili pepper", "bitter gourd", "bottle gourd", "drumstick pods",
    "amaranth leaves", "fenugreek leaves", "mustard greens", "sweet potato",
    "buttermilk", "cottage cheese", "condensed milk", "khoa",
)

FOOD_CLASS_BY_TERM = {
    "rice": "grain", "wheat": "grain", "millet": "grain", "sorghum": "grain",
    "oats": "grain", "semolina": "grain", "chickpeas": "legume", "lentils": "legume",
    "beans": "legume", "peas": "legume", "chicken": "meat", "mutton": "meat",
    "lamb": "meat", "egg": "egg", "shrimp": "seafood", "fish": "seafood",
    "milk": "dairy", "yogurt": "dairy", "paneer": "dairy", "cheese": "dairy",
    "ghee": "fat", "oil": "fat", "mango": "fruit", "banana": "fruit",
    "papaya": "fruit", "guava": "fruit", "pomegranate": "fruit",
    "almonds": "snack", "cashew": "snack", "peanuts": "snack",
}


def _class_for(name: str) -> str:
    low = name.lower()
    for term, cls in FOOD_CLASS_BY_TERM.items():
        if term in low:
            return cls
    return "vegetable"


def _nutrition(food: dict[str, Any]) -> Nutrition:
    data: dict[str, float] = {}
    for n in food.get("foodNutrients") or []:
        nid = n.get("nutrientId") or (n.get("nutrient") or {}).get("id")
        val = n.get("value", (n.get("amount")))
        if nid in NUTRIENT_IDS and val is not None:
            field, mult = NUTRIENT_IDS[nid]
            try:
                data[field] = round(float(val) * mult, 3)
            except (TypeError, ValueError):
                continue
    return Nutrition(**data)


class UsdaSource(Source):
    key = "usda"
    display_name = "USDA FoodData Central"
    license_note = "USDA FDC data are in the public domain (CC0)."

    def __init__(self, limit: int | None = None, queries: Iterable[str] = DEFAULT_QUERIES,
                 per_query: int = 12, data_types: Iterable[str] = ("Foundation", "SR Legacy")):
        super().__init__(limit)
        self.queries = tuple(queries)
        self.per_query = per_query
        self.data_types = tuple(data_types)
        self.api_key = os.environ.get("FDC_API_KEY", "").strip()

    def _search(self, query: str) -> list[dict[str, Any]]:
        data = http.get_json(SEARCH, params={
            "api_key": self.api_key,
            "query": query,
            "dataType": ",".join(self.data_types),
            "pageSize": self.per_query,
            "requireAllWords": "false",
        })
        return data.get("foods") or []

    def fetch(self) -> Iterable[FoodRecord]:
        if not self.api_key:
            self.log.warning("FDC_API_KEY not set — skipping USDA import "
                             "(micronutrient donors will fall back to class profiles).")
            return
        for query in self.queries:
            for food in self._search(query):
                rec = self._to_record(food, query)
                if rec:
                    yield rec

    def _to_record(self, food: dict[str, Any], query: str) -> FoodRecord | None:
        name = clean_name(food.get("description") or "")
        if not name:
            return None
        nut = _nutrition(food)
        if nut.calories is None or nut.filled_count() < 6:
            return None
        food_class = _class_for(f"{query} {name}")
        grams = {"fat": 10.0, "dairy": 200.0, "fruit": 120.0, "snack": 30.0}.get(food_class, 100.0)
        unit = {"fat": "spoon", "dairy": "glass", "fruit": "piece", "snack": "bowl"}.get(food_class, "serving")
        from .curated import build_servings

        return FoodRecord(
            slug=slugify(f"usda-{name}"),
            name=name,
            category="Healthy Foods" if food_class in ("fruit", "vegetable") else "Vegetarian",
            food_type="food",
            description=truncate(food.get("additionalDescriptions") or "", 300),
            tags=["reference", "usda", food_class],
            nutrition=nut,
            servings=build_servings(unit, grams, food_class),
            source="USDA-FDC",
            source_id=str(food.get("fdcId") or ""),
            source_url=f"https://fdc.nal.usda.gov/food-details/{food.get('fdcId')}/nutrients",
            confidence=0.95,
        )

    # ---- donor pool used by pipeline/micros.py -------------------------------
    def donor_pool(self) -> dict[str, Nutrition]:
        pool: dict[str, Nutrition] = {}
        for rec in self.run():
            cls = next((t for t in rec.tags if t in set(FOOD_CLASS_BY_TERM.values())), None)
            if cls and cls not in pool:
                pool[cls] = rec.nutrition
        return pool
