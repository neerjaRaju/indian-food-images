"""Curated Indian core table + rule-based variant expansion.

The core PSV holds researched per-100 g values for canonical Indian dishes.
``VariantExpander`` then multiplies that core into the long tail users actually
search for ("Paneer Butter Masala without cream", "Jain Pav Bhaji", "Roti with
ghee") by applying *explicit, auditable* transformation rules. Every generated
row is stamped with ``derived_from`` and a reduced ``confidence`` so the app can
label it and so a future IFCT import can overwrite it.
"""
from __future__ import annotations

import csv
from collections.abc import Iterable, Iterator
from dataclasses import replace
from pathlib import Path

from ..config import SEED_DIR
from ..models import FoodRecord, Nutrition, ServingSize
from ..util.text import clean_name, slugify
from .base import Source

CORE_FILE = SEED_DIR / "indian_core.psv"

COLUMNS = (
    "name", "hindi", "category", "region", "diet", "kcal", "protein", "carbs",
    "fat", "satfat", "fiber", "sugar", "sodium", "class", "unit", "grams", "tags",
)

REGION_LABEL = {
    "north": "North India", "south": "South India", "east": "East India",
    "west": "West India", "pan": "Pan-India",
}


# --------------------------------------------------------------------------- #
# Variant rules
# --------------------------------------------------------------------------- #
class Rule:
    """A named transformation of a base dish.

    ``deltas`` are *multipliers* on the per-100 g macro values; ``adds`` are
    absolute per-100 g additions applied after multiplication.
    """

    __slots__ = ("suffix", "hindi_suffix", "deltas", "adds", "tags", "diet",
                 "applies_to", "excludes", "confidence")

    def __init__(self, suffix, hindi_suffix="", deltas=None, adds=None, tags=(),
                 diet=None, applies_to=(), excludes=(), confidence=0.62):
        self.suffix = suffix
        self.hindi_suffix = hindi_suffix
        self.deltas = deltas or {}
        self.adds = adds or {}
        self.tags = tuple(tags)
        self.diet = diet
        self.applies_to = tuple(applies_to)      # food classes; empty == any
        self.excludes = tuple(excludes)          # tags that block the rule
        self.confidence = confidence

    def matches(self, rec: FoodRecord, food_class: str) -> bool:
        if self.applies_to and food_class not in self.applies_to:
            return False
        return not any(t in rec.tags for t in self.excludes)


COOKING_RULES: tuple[Rule, ...] = (
    Rule("with Ghee", "घी के साथ",
         adds={"calories": 90, "fat_g": 10.0, "saturated_fat_g": 6.2},
         tags=("ghee",), applies_to=("grain", "legume", "mixed", "vegetable")),
    Rule("without Oil", "बिना तेल",
         deltas={"fat_g": 0.25, "saturated_fat_g": 0.25},
         tags=("low-fat", "healthy"), applies_to=("vegetable", "legume", "mixed", "grain")),
    Rule("Low Oil", "कम तेल",
         deltas={"fat_g": 0.55, "saturated_fat_g": 0.55},
         tags=("low-fat", "healthy"), applies_to=("vegetable", "legume", "mixed", "grain", "meat")),
    Rule("Restaurant Style", "रेस्टोरेंट स्टाइल",
         deltas={"fat_g": 1.5, "saturated_fat_g": 1.6, "sodium_mg": 1.35},
         tags=("restaurant",), applies_to=("vegetable", "legume", "meat", "dairy", "mixed")),
    Rule("Homemade", "घर का बना",
         deltas={"fat_g": 0.85, "sodium_mg": 0.8},
         tags=("homemade",), applies_to=("vegetable", "legume", "meat", "dairy", "mixed", "grain")),
    Rule("with Cream", "क्रीम के साथ",
         adds={"calories": 62, "fat_g": 6.4, "saturated_fat_g": 4.0, "protein_g": 0.5},
         tags=("creamy",), applies_to=("dairy", "meat", "legume", "vegetable")),
    Rule("without Cream", "बिना क्रीम",
         deltas={"fat_g": 0.7, "saturated_fat_g": 0.62},
         tags=("lighter",), applies_to=("dairy", "meat"), excludes=("low-fat",)),
    Rule("Air Fried", "एयर फ्राइड",
         deltas={"calories": 0.68, "fat_g": 0.35, "saturated_fat_g": 0.35},
         tags=("healthy", "air-fried"), applies_to=("fried", "street")),
    Rule("Baked", "बेक्ड",
         deltas={"calories": 0.72, "fat_g": 0.4, "saturated_fat_g": 0.4},
         tags=("healthy", "baked"), applies_to=("fried", "street", "snack")),
    Rule("Whole Wheat", "गेहूं का",
         deltas={"fiber_g": 2.6}, adds={"protein_g": 1.4},
         tags=("wholegrain", "healthy"), applies_to=("grain", "fried")),
    Rule("Multigrain", "मल्टीग्रेन",
         deltas={"fiber_g": 2.4}, adds={"protein_g": 1.8},
         tags=("wholegrain", "healthy"), applies_to=("grain",)),
    Rule("Sugar Free", "शुगर फ्री",
         deltas={"sugar_g": 0.05, "calories": 0.62, "carbs_g": 0.55},
         tags=("sugar-free", "diabetic"), applies_to=("sweet", "beverage")),
    Rule("Less Sugar", "कम चीनी",
         deltas={"sugar_g": 0.5, "calories": 0.82, "carbs_g": 0.76},
         tags=("diabetic",), applies_to=("sweet", "beverage")),
    Rule("Jain", "जैन",
         deltas={}, tags=("jain",), applies_to=("vegetable", "legume", "mixed", "street"),
         excludes=("nonveg",)),
    Rule("Vegan", "वीगन",
         deltas={"saturated_fat_g": 0.35}, adds={"cholesterol_mg": -8},
         tags=("vegan",), applies_to=("vegetable", "legume", "mixed", "grain")),
    Rule("High Protein", "हाई प्रोटीन",
         adds={"protein_g": 6.0, "calories": 28},
         tags=("high-protein", "fitness"), applies_to=("grain", "mixed", "legume", "vegetable")),
    Rule("Spicy", "तीखा",
         deltas={"sodium_mg": 1.12}, tags=("spicy",),
         applies_to=("vegetable", "legume", "meat", "street", "mixed")),
    Rule("Dhaba Style", "ढाबा स्टाइल",
         deltas={"fat_g": 1.4, "sodium_mg": 1.3}, tags=("dhaba", "restaurant"),
         applies_to=("legume", "meat", "vegetable", "dairy")),
)

PORTION_RULES: tuple[Rule, ...] = ()  # portions are modelled as serving sizes, not rows


# --------------------------------------------------------------------------- #
# Serving templates per food class
# --------------------------------------------------------------------------- #
SERVING_TEMPLATES: dict[str, list[tuple[str, str, float]]] = {
    "grain": [("serving", "1 serving", 1.0), ("plate", "1 plate", 2.5), ("bowl", "1 bowl", 1.8)],
    "legume": [("bowl", "1 katori", 1.0), ("cup", "1 cup", 1.3), ("plate", "1 plate", 2.0),
               ("spoon", "1 tbsp", 0.09)],
    "vegetable": [("bowl", "1 katori", 1.0), ("cup", "1 cup", 1.2), ("spoon", "1 tbsp", 0.1)],
    "meat": [("bowl", "1 katori", 1.0), ("plate", "1 plate", 1.8), ("piece", "1 piece", 0.4)],
    "seafood": [("bowl", "1 katori", 1.0), ("piece", "1 piece", 0.5)],
    "dairy": [("bowl", "1 katori", 1.0), ("cup", "1 cup", 1.3), ("spoon", "1 tbsp", 0.1)],
    "sweet": [("piece", "1 piece", 1.0), ("bowl", "1 katori", 1.6), ("plate", "1 plate", 2.5)],
    "snack": [("bowl", "1 small bowl", 1.0), ("serving", "1 packet", 1.6), ("spoon", "1 tbsp", 0.25)],
    "beverage": [("glass", "1 glass", 1.0), ("cup", "1 cup", 0.7)],
    "fruit": [("piece", "1 whole", 1.0), ("bowl", "1 bowl", 1.2), ("cup", "1 cup", 0.9)],
    "fried": [("piece", "1 piece", 1.0), ("plate", "1 plate", 3.0)],
    "street": [("plate", "1 plate", 1.0), ("serving", "1 serving", 0.8)],
    "mixed": [("plate", "1 plate", 1.0), ("bowl", "1 bowl", 0.75)],
    "egg": [("piece", "1 egg", 1.0), ("serving", "1 serving", 2.0)],
    "soup": [("bowl", "1 bowl", 1.0), ("cup", "1 cup", 0.8)],
    "fat": [("spoon", "1 tsp", 0.5), ("serving", "1 tbsp", 1.0)],
}

UNIT_ALIASES = {"roti", "chapati", "idli", "dosa", "paratha"}


def build_servings(unit: str, grams: float, food_class: str) -> list[ServingSize]:
    """Always emit 100 g + the dish's natural unit + class-appropriate portions."""
    out: list[ServingSize] = [
        ServingSize(unit="100g", label="100 g", grams=100.0, is_default=False, sort_order=0)
    ]
    order = 1
    primary_label = {
        "roti": "1 roti", "chapati": "1 chapati", "idli": "1 idli", "dosa": "1 dosa",
        "paratha": "1 paratha", "piece": "1 piece", "bowl": "1 katori (bowl)",
        "cup": "1 cup", "glass": "1 glass", "plate": "1 plate", "spoon": "1 tbsp",
        "serving": "1 serving",
    }.get(unit, f"1 {unit}")
    out.append(ServingSize(unit=unit, label=primary_label, grams=round(grams, 1),
                           is_default=True, sort_order=order))
    order += 1
    seen = {"100g", unit}
    for u, label, factor in SERVING_TEMPLATES.get(food_class, []):
        if u in seen:
            continue
        seen.add(u)
        out.append(ServingSize(unit=u, label=label, grams=round(grams * factor, 1),
                               is_default=False, sort_order=order))
        order += 1
    if unit in UNIT_ALIASES:
        # e.g. a roti row should also answer "2 rotis" via piece
        out.append(ServingSize(unit="piece", label=f"1 {unit}", grams=round(grams, 1),
                               is_default=False, sort_order=order))
        order += 1
    out.append(ServingSize(unit="custom", label="Custom grams", grams=1.0,
                           is_default=False, sort_order=99))
    return out


# --------------------------------------------------------------------------- #
# Loader
# --------------------------------------------------------------------------- #
def _f(v: str, default: float | None = None) -> float | None:
    v = (v or "").strip()
    if not v or v in {"-", "NA", "null"}:
        return default
    try:
        return float(v)
    except ValueError:
        return default


def load_core_rows(path: Path | None = None) -> Iterator[dict[str, str]]:
    path = path or CORE_FILE
    with path.open(encoding="utf-8") as fh:
        reader = csv.reader((ln for ln in fh if ln.strip() and not ln.startswith("#")),
                            delimiter="|")
        for row in reader:
            if len(row) < len(COLUMNS):
                row = row + [""] * (len(COLUMNS) - len(row))
            yield dict(zip(COLUMNS, row))


def row_to_record(row: dict[str, str]) -> FoodRecord:
    name = clean_name(row["name"])
    food_class = (row["class"] or "mixed").strip()
    grams = _f(row["grams"], 100.0) or 100.0
    unit = (row["unit"] or "serving").strip()
    tags = [t for t in (row["tags"] or "").split(",") if t]
    diet = (row["diet"] or "veg").strip()
    rec = FoodRecord(
        slug=slugify(name),
        name=name,
        hindi_name=(row["hindi"] or "").strip(),
        category=(row["category"] or "North Indian").strip(),
        region=REGION_LABEL.get((row["region"] or "pan").strip(), "Pan-India"),
        diet=diet,
        is_vegan=diet == "vegan" or "vegan" in tags,
        is_jain="jain" in tags,
        food_type="food",
        tags=tags + [food_class],
        nutrition=Nutrition(
            calories=_f(row["kcal"], 0.0) or 0.0,
            protein_g=_f(row["protein"], 0.0) or 0.0,
            carbs_g=_f(row["carbs"], 0.0) or 0.0,
            fat_g=_f(row["fat"], 0.0) or 0.0,
            saturated_fat_g=_f(row["satfat"]),
            fiber_g=_f(row["fiber"]),
            sugar_g=_f(row["sugar"]),
            sodium_mg=_f(row["sodium"]),
        ),
        servings=build_servings(unit, grams, food_class),
        source="IFCT2017/NIN-curated",
        source_url="https://www.nin.res.in/ifct2017.html",
        confidence=0.88,
    )
    return rec


class CuratedIndianSource(Source):
    key = "curated"
    display_name = "Curated Indian core (IFCT/NIN aligned)"
    requires_network = False
    license_note = "Values compiled from public nutrition tables; text is original."

    def fetch(self) -> Iterable[FoodRecord]:
        for row in load_core_rows():
            yield row_to_record(row)


# --------------------------------------------------------------------------- #
# Variant expansion
# --------------------------------------------------------------------------- #
def _apply(nut: Nutrition, rule: Rule) -> Nutrition:
    data = nut.as_dict()
    for field, mult in rule.deltas.items():
        if data.get(field) is not None:
            data[field] = round(data[field] * mult, 2)
    for field, add in rule.adds.items():
        base = data.get(field)
        data[field] = round(max(0.0, (base or 0.0) + add), 2)
    # Re-derive calories from macros when a rule changed a macro but not kcal.
    if "calories" not in rule.deltas and "calories" not in rule.adds:
        kcal = (data["protein_g"] or 0) * 4 + (data["carbs_g"] or 0) * 4 + (data["fat_g"] or 0) * 9
        if kcal > 0:
            data["calories"] = round(kcal, 1)
    for k, v in list(data.items()):
        if v is not None and v < 0:
            data[k] = 0.0
    return Nutrition(**data)


class VariantExpander:
    """Expands curated base records into searchable, clearly-labelled variants."""

    def __init__(self, rules: Iterable[Rule] = COOKING_RULES, max_per_base: int = 6):
        self.rules = tuple(rules)
        self.max_per_base = max_per_base

    def expand(self, base: FoodRecord) -> list[FoodRecord]:
        food_class = base.tags[-1] if base.tags else "mixed"
        out: list[FoodRecord] = []
        for rule in self.rules:
            if len(out) >= self.max_per_base:
                break
            if not rule.matches(base, food_class):
                continue
            name = f"{base.name} ({rule.suffix})"
            hindi = f"{base.hindi_name} {rule.hindi_suffix}".strip() if base.hindi_name else ""
            rec = replace(
                base,
                slug=slugify(name),
                name=name,
                hindi_name=hindi,
                nutrition=_apply(base.nutrition, rule),
                tags=sorted(set(list(base.tags) + list(rule.tags) + ["variant"])),
                confidence=round(base.confidence * rule.confidence + 0.15, 3),
                source=f"{base.source}+rule:{rule.suffix}",
                servings=[replace(s) for s in base.servings],
            )
            if "jain" in rule.tags:
                rec.is_jain = True
            if "vegan" in rule.tags:
                rec.is_vegan = True
                rec.diet = "vegan"
            rec.description = (
                f"Rule-derived variant of {base.name}: {rule.suffix.lower()}. "
                "Values are estimated from the base dish, not separately measured."
            )
            out.append(rec)
        return out


class CuratedVariantSource(Source):
    key = "curated_variants"
    display_name = "Curated variants (rule-derived)"
    requires_network = False

    def __init__(self, limit: int | None = None, max_per_base: int = 6) -> None:
        super().__init__(limit)
        self.expander = VariantExpander(max_per_base=max_per_base)

    def fetch(self) -> Iterable[FoodRecord]:
        for row in load_core_rows():
            base = row_to_record(row)
            yield from self.expander.expand(base)
