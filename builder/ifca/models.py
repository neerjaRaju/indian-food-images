"""Canonical in-memory records shared by every pipeline stage."""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from typing import Any

NUTRIENT_FIELDS: tuple[str, ...] = (
    "calories",
    "protein_g",
    "carbs_g",
    "fat_g",
    "saturated_fat_g",
    "fiber_g",
    "sugar_g",
    "sodium_mg",
    "potassium_mg",
    "calcium_mg",
    "iron_mg",
    "magnesium_mg",
    "vitamin_a_mcg",
    "vitamin_c_mg",
    "vitamin_d_mcg",
    "vitamin_b12_mcg",
    "cholesterol_mg",
)

# Unit vocabulary supported by the app's portion selector.
SERVING_UNITS: tuple[str, ...] = (
    "100g",
    "serving",
    "bowl",
    "cup",
    "glass",
    "spoon",
    "plate",
    "piece",
    "roti",
    "chapati",
    "idli",
    "dosa",
    "paratha",
    "custom",
)


@dataclass
class Nutrition:
    """Nutrition per 100 g (or per 100 ml for liquids)."""

    calories: float = 0.0
    protein_g: float = 0.0
    carbs_g: float = 0.0
    fat_g: float = 0.0
    saturated_fat_g: float | None = None
    fiber_g: float | None = None
    sugar_g: float | None = None
    sodium_mg: float | None = None
    potassium_mg: float | None = None
    calcium_mg: float | None = None
    iron_mg: float | None = None
    magnesium_mg: float | None = None
    vitamin_a_mcg: float | None = None
    vitamin_c_mg: float | None = None
    vitamin_d_mcg: float | None = None
    vitamin_b12_mcg: float | None = None
    cholesterol_mg: float | None = None

    def as_dict(self) -> dict[str, float | None]:
        return {f: getattr(self, f) for f in NUTRIENT_FIELDS}

    def filled_count(self) -> int:
        return sum(1 for f in NUTRIENT_FIELDS if getattr(self, f) is not None)


@dataclass
class ServingSize:
    unit: str                 # one of SERVING_UNITS
    label: str                # display label, e.g. "1 medium roti"
    grams: float              # grams (or ml) this portion represents
    is_default: bool = False
    sort_order: int = 0


@dataclass
class ImageAsset:
    slug: str
    source_url: str
    source_name: str          # "wikimedia" | "openfoodfacts" | "self" | ...
    credit: str = ""
    license: str = ""
    license_url: str = ""
    phash: str = ""
    thumbnail_url: str = ""
    medium_url: str = ""
    large_url: str = ""
    width: int = 0
    height: int = 0
    bytes_thumbnail: int = 0
    bytes_medium: int = 0
    bytes_large: int = 0


@dataclass
class FoodRecord:
    """One row of the ``foods`` table before it is written."""

    slug: str
    name: str
    category: str
    hindi_name: str = ""
    regional_names: dict[str, str] = field(default_factory=dict)
    synonyms: list[str] = field(default_factory=list)
    description: str = ""
    food_type: str = "food"          # food | recipe | packaged | restaurant
    diet: str = "veg"                # veg | nonveg | egg | vegan | jain
    is_vegan: bool = False
    is_jain: bool = False
    barcode: str = ""
    brand: str = ""
    restaurant: str = ""
    region: str = ""
    tags: list[str] = field(default_factory=list)
    nutrition: Nutrition = field(default_factory=Nutrition)
    servings: list[ServingSize] = field(default_factory=list)
    image: ImageAsset | None = None
    source: str = ""                 # provenance key e.g. "IFCT2017"
    source_id: str = ""
    source_url: str = ""
    confidence: float = 0.8
    last_updated: str = ""
    # recipe extras
    ingredients: list[str] = field(default_factory=list)
    steps: list[str] = field(default_factory=list)
    prep_minutes: int = 0
    cook_minutes: int = 0

    def to_json(self) -> dict[str, Any]:
        d = dataclasses.asdict(self)
        return d

    @staticmethod
    def from_json(d: dict[str, Any]) -> FoodRecord:
        d = dict(d)
        nut = d.pop("nutrition", {}) or {}
        srv = d.pop("servings", []) or []
        img = d.pop("image", None)
        rec = FoodRecord(**d)
        rec.nutrition = Nutrition(**nut)
        rec.servings = [ServingSize(**s) for s in srv]
        rec.image = ImageAsset(**img) if img else None
        return rec
