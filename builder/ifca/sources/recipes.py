"""Recipe corpus with *computed* nutrition.

Unlike the curated dish table (which stores measured per-100 g values), a recipe
row is built bottom-up: ingredient grams -> summed nutrients -> divided by the
cooked yield. Cooked yield accounts for water loss during cooking, which is why
``ingredients.psv`` carries a ``water_loss`` column.

Recipes come from ``data/recipes.psv``; extra corpora can be dropped into
``data/recipes.d/*.psv`` (same format) and are picked up automatically, which is
how the weekly job grows the corpus without code changes.
"""
from __future__ import annotations

import csv
import re
from collections.abc import Iterable, Iterator
from pathlib import Path

from ..config import SEED_DIR
from ..models import FoodRecord, Nutrition
from ..util import log
from ..util.text import clean_name, slugify
from .base import Source
from .curated import build_servings

INGREDIENTS_FILE = SEED_DIR / "ingredients.psv"
RECIPES_FILE = SEED_DIR / "recipes.psv"
RECIPES_DIR = SEED_DIR / "recipes.d"

_log = log.get("ifca.source.recipes")

ING_COLUMNS = ("name", "kcal", "protein", "carbs", "fat", "satfat", "fiber",
               "sugar", "sodium", "potassium", "calcium", "iron", "water_loss")

REC_COLUMNS = ("name", "hindi", "category", "region", "diet", "class", "servings",
               "serving_unit", "ingredients", "steps", "prep", "cook", "tags")

# "120g onion" / "2 tbsp ghee" / "1 cup rice raw"
QTY = re.compile(r"^\s*([\d.]+)\s*(g|ml|tbsp|tsp|cup|piece|pieces|no|nos)?\s+(.*?)\s*$", re.I)

UNIT_GRAMS = {
    "g": 1.0, "ml": 1.0, "tbsp": 15.0, "tsp": 5.0, "cup": 200.0,
    "piece": 50.0, "pieces": 50.0, "no": 50.0, "nos": 50.0,
}
# Per-ingredient overrides for piece-based quantities.
PIECE_GRAMS = {"egg": 50.0, "onion": 100.0, "tomato": 90.0, "potato": 120.0,
               "green chili": 5.0, "pav bun": 45.0, "bread": 25.0, "cashew": 1.5,
               "almond": 1.2, "curry leaves": 0.3}


def _f(v: str, default: float = 0.0) -> float:
    try:
        return float((v or "").strip())
    except ValueError:
        return default


def load_ingredients(path: Path | None = None) -> dict[str, dict[str, float]]:
    path = path or INGREDIENTS_FILE
    table: dict[str, dict[str, float]] = {}
    with path.open(encoding="utf-8") as fh:
        reader = csv.reader((ln for ln in fh if ln.strip() and not ln.startswith("#")),
                            delimiter="|")
        for row in reader:
            row = row + [""] * (len(ING_COLUMNS) - len(row))
            d = dict(zip(ING_COLUMNS, row))
            table[d["name"].strip().lower()] = {k: _f(v) for k, v in d.items() if k != "name"}
    return table


class IngredientResolver:
    """Fuzzy-ish lookup so recipe authors can write natural ingredient names."""

    def __init__(self, table: dict[str, dict[str, float]]):
        self.table = table
        self._keys = sorted(table, key=len, reverse=True)

    def resolve(self, name: str) -> tuple[str, dict[str, float]] | None:
        low = name.strip().lower()
        if low in self.table:
            return low, self.table[low]
        for key in self._keys:
            if key in low or low in key:
                return key, self.table[key]
        return None


def parse_quantity(chunk: str, resolver: IngredientResolver) -> tuple[str, float, dict[str, float]] | None:
    m = QTY.match(chunk)
    if not m:
        return None
    amount = float(m.group(1))
    unit = (m.group(2) or "g").lower()
    name = m.group(3).strip()
    hit = resolver.resolve(name)
    if not hit:
        _log.debug("Unknown ingredient %r — ignored", name)
        return None
    key, data = hit
    if unit in ("piece", "pieces", "no", "nos"):
        grams = amount * PIECE_GRAMS.get(key, UNIT_GRAMS["piece"])
    else:
        grams = amount * UNIT_GRAMS.get(unit, 1.0)
    return key, grams, data


def compute_nutrition(
    ingredient_line: str, resolver: IngredientResolver
) -> tuple[Nutrition, float, list[str]]:
    """Return (per-100 g nutrition of the cooked dish, cooked yield g, pretty list)."""
    totals = dict.fromkeys(("kcal", "protein", "carbs", "fat", "satfat", "fiber", "sugar", "sodium", "potassium", "calcium", "iron"), 0.0)
    raw_mass = 0.0
    cooked_mass = 0.0
    pretty: list[str] = []
    for chunk in ingredient_line.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        parsed = parse_quantity(chunk, resolver)
        if not parsed:
            pretty.append(chunk)
            continue
        key, grams, data = parsed
        factor = grams / 100.0
        for field, col in (("kcal", "kcal"), ("protein", "protein"), ("carbs", "carbs"),
                           ("fat", "fat"), ("satfat", "satfat"), ("fiber", "fiber"),
                           ("sugar", "sugar"), ("sodium", "sodium"),
                           ("potassium", "potassium"), ("calcium", "calcium"),
                           ("iron", "iron")):
            totals[field] += data.get(col, 0.0) * factor
        raw_mass += grams
        cooked_mass += grams * (1.0 - data.get("water_loss", 0.0))
        pretty.append(chunk)
    if cooked_mass <= 0:
        return Nutrition(), 0.0, pretty
    per100 = 100.0 / cooked_mass
    nut = Nutrition(
        calories=round(totals["kcal"] * per100, 1),
        protein_g=round(totals["protein"] * per100, 2),
        carbs_g=round(totals["carbs"] * per100, 2),
        fat_g=round(totals["fat"] * per100, 2),
        saturated_fat_g=round(totals["satfat"] * per100, 2),
        fiber_g=round(totals["fiber"] * per100, 2),
        sugar_g=round(totals["sugar"] * per100, 2),
        sodium_mg=round(totals["sodium"] * per100, 1),
        potassium_mg=round(totals["potassium"] * per100, 1),
        calcium_mg=round(totals["calcium"] * per100, 1),
        iron_mg=round(totals["iron"] * per100, 2),
    )
    return nut, round(cooked_mass, 1), pretty


def _recipe_files() -> Iterator[Path]:
    if RECIPES_FILE.exists():
        yield RECIPES_FILE
    if RECIPES_DIR.exists():
        yield from sorted(RECIPES_DIR.glob("*.psv"))


def load_recipe_rows() -> Iterator[dict[str, str]]:
    for path in _recipe_files():
        with path.open(encoding="utf-8") as fh:
            reader = csv.reader((ln for ln in fh if ln.strip() and not ln.startswith("#")),
                                delimiter="|")
            for row in reader:
                row = row + [""] * (len(REC_COLUMNS) - len(row))
                yield dict(zip(REC_COLUMNS, row))


REGION_LABEL = {"north": "North India", "south": "South India", "east": "East India",
                "west": "West India", "pan": "Pan-India"}


class RecipeSource(Source):
    key = "recipes"
    display_name = "Indian recipes (ingredient-computed nutrition)"
    requires_network = False

    def __init__(self, limit: int | None = None) -> None:
        super().__init__(limit)
        self.resolver = IngredientResolver(load_ingredients())

    def fetch(self) -> Iterable[FoodRecord]:
        for row in load_recipe_rows():
            rec = self._to_record(row)
            if rec:
                yield rec

    def _to_record(self, row: dict[str, str]) -> FoodRecord | None:
        name = clean_name(row["name"])
        if not name:
            return None
        nut, cooked_g, ingredients = compute_nutrition(row["ingredients"], self.resolver)
        if nut.calories <= 0:
            _log.debug("Recipe %s produced no nutrition — skipped", name)
            return None
        portions = max(1, int(_f(row["servings"], 4)))
        per_serving_g = round(cooked_g / portions, 1) if cooked_g else 200.0
        food_class = (row["class"] or "mixed").strip()
        unit = (row["serving_unit"] or "serving").strip()
        servings = build_servings(unit, per_serving_g, food_class)
        diet = (row["diet"] or "veg").strip()
        tags = [t for t in (row["tags"] or "").split(",") if t] + ["recipe", food_class]
        return FoodRecord(
            slug=slugify(f"recipe-{name}"),
            name=name,
            hindi_name=(row["hindi"] or "").strip(),
            category=(row["category"] or "North Indian").strip(),
            region=REGION_LABEL.get((row["region"] or "pan").strip(), "Pan-India"),
            diet=diet,
            is_vegan=diet == "vegan",
            is_jain="jain" in tags,
            food_type="recipe",
            tags=tags,
            nutrition=nut,
            servings=servings,
            ingredients=ingredients,
            steps=[s.strip() for s in (row["steps"] or "").split(";") if s.strip()],
            prep_minutes=int(_f(row["prep"], 10)),
            cook_minutes=int(_f(row["cook"], 20)),
            description=(
                f"Home recipe for {portions} servings (~{per_serving_g:g} g each). "
                "Nutrition is computed from the ingredient list and cooked yield."
            ),
            source="recipe-calculated",
            confidence=0.8,
        )


class RecipeVariantSource(Source):
    """Regional / dietary spins on each base recipe, recomputed from ingredients."""

    key = "recipe_variants"
    display_name = "Recipe variants"
    requires_network = False

    SWAPS: tuple[tuple[str, str, str, tuple[str, ...]], ...] = (
        ("Jain", "जैन", "onion->cabbage;garlic->ginger", ("jain",)),
        ("Vegan", "वीगन", "ghee->coconut oil;paneer->tofu;curd->coconut milk;milk->coconut milk", ("vegan",)),
        ("Low Oil", "कम तेल", "ghee->water;sunflower oil->water;mustard oil->water", ("healthy", "low-fat")),
        ("High Protein", "हाई प्रोटीन", "water->curd", ("high-protein", "fitness")),
        ("Millet", "मिलेट", "rice raw->bajra flour;atta->ragi flour;maida->jowar flour", ("millet", "healthy")),
    )

    def __init__(self, limit: int | None = None) -> None:
        super().__init__(limit)
        self.resolver = IngredientResolver(load_ingredients())

    @staticmethod
    def _apply_swaps(line: str, swaps: str) -> str | None:
        out = line
        changed = False
        for pair in swaps.split(";"):
            if "->" not in pair:
                continue
            a, b = pair.split("->", 1)
            if a in out:
                out = out.replace(a, b)
                changed = True
        return out if changed else None

    def fetch(self) -> Iterable[FoodRecord]:
        base_source = RecipeSource()
        for row in load_recipe_rows():
            for suffix, hindi_suffix, swaps, tags in self.SWAPS:
                swapped = self._apply_swaps(row["ingredients"], swaps)
                if not swapped:
                    continue
                variant_row = dict(row)
                variant_row["ingredients"] = swapped
                variant_row["name"] = f"{row['name']} ({suffix})"
                variant_row["hindi"] = f"{row['hindi']} {hindi_suffix}".strip()
                variant_row["tags"] = ",".join(
                    [t for t in (row["tags"] or "").split(",") if t] + list(tags) + ["variant"]
                )
                rec = base_source._to_record(variant_row)  # noqa: SLF001 - same package
                if rec:
                    rec.confidence = round(rec.confidence * 0.9, 3)
                    rec.source = f"recipe-calculated+swap:{suffix}"
                    yield rec
