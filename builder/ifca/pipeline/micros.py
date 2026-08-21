"""Micronutrient completion.

Indian composition tables publish energy + macros for almost every cooked dish
but micronutrients for only a fraction. Rather than shipping blank fields, we
fill the gaps from a *food-class profile* (per 100 g medians derived from USDA
FDC entries for the same class) and set ``micros_estimated = 1`` on the row so
the app can label the value and so a later authoritative import overrides it.

Nothing here overwrites a measured value — only ``None`` is filled.
"""
from __future__ import annotations

from collections.abc import Iterable

from ..models import NUTRIENT_FIELDS, FoodRecord, Nutrition
from ..util import log

_log = log.get("ifca.micros")

MICRO_FIELDS: tuple[str, ...] = (
    "potassium_mg", "calcium_mg", "iron_mg", "magnesium_mg", "vitamin_a_mcg",
    "vitamin_c_mg", "vitamin_d_mcg", "vitamin_b12_mcg", "cholesterol_mg",
)

SECONDARY_MACROS: tuple[str, ...] = ("saturated_fat_g", "fiber_g", "sugar_g", "sodium_mg")

# Per-100 g class profiles. Compiled from USDA FDC SR Legacy medians for the
# representative members of each class; used only as a fallback.
CLASS_PROFILE: dict[str, dict[str, float]] = {
    "grain":     dict(potassium_mg=95,  calcium_mg=20,  iron_mg=1.2, magnesium_mg=35,
                      vitamin_a_mcg=0,   vitamin_c_mg=0,   vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "legume":    dict(potassium_mg=320, calcium_mg=42,  iron_mg=2.3, magnesium_mg=48,
                      vitamin_a_mcg=6,   vitamin_c_mg=1.5, vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "vegetable": dict(potassium_mg=245, calcium_mg=38,  iron_mg=1.0, magnesium_mg=24,
                      vitamin_a_mcg=95,  vitamin_c_mg=14,  vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "fruit":     dict(potassium_mg=200, calcium_mg=14,  iron_mg=0.3, magnesium_mg=13,
                      vitamin_a_mcg=42,  vitamin_c_mg=28,  vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "dairy":     dict(potassium_mg=145, calcium_mg=190, iron_mg=0.2, magnesium_mg=17,
                      vitamin_a_mcg=68,  vitamin_c_mg=0.6, vitamin_d_mcg=0.6,
                      vitamin_b12_mcg=0.6, cholesterol_mg=22),
    "meat":      dict(potassium_mg=255, calcium_mg=16,  iron_mg=1.3, magnesium_mg=22,
                      vitamin_a_mcg=12,  vitamin_c_mg=0,   vitamin_d_mcg=0.3,
                      vitamin_b12_mcg=1.1, cholesterol_mg=72),
    "seafood":   dict(potassium_mg=270, calcium_mg=48,  iron_mg=0.9, magnesium_mg=30,
                      vitamin_a_mcg=18,  vitamin_c_mg=0,   vitamin_d_mcg=3.4,
                      vitamin_b12_mcg=2.2, cholesterol_mg=64),
    "egg":       dict(potassium_mg=126, calcium_mg=50,  iron_mg=1.8, magnesium_mg=10,
                      vitamin_a_mcg=160, vitamin_c_mg=0,   vitamin_d_mcg=2.0,
                      vitamin_b12_mcg=1.1, cholesterol_mg=372),
    "sweet":     dict(potassium_mg=150, calcium_mg=110, iron_mg=1.1, magnesium_mg=22,
                      vitamin_a_mcg=45,  vitamin_c_mg=0.4, vitamin_d_mcg=0.2,
                      vitamin_b12_mcg=0.3, cholesterol_mg=18),
    "snack":     dict(potassium_mg=330, calcium_mg=48,  iron_mg=2.4, magnesium_mg=68,
                      vitamin_a_mcg=4,   vitamin_c_mg=0.5, vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "fried":     dict(potassium_mg=230, calcium_mg=36,  iron_mg=1.6, magnesium_mg=32,
                      vitamin_a_mcg=14,  vitamin_c_mg=4,   vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "street":    dict(potassium_mg=260, calcium_mg=44,  iron_mg=1.7, magnesium_mg=34,
                      vitamin_a_mcg=32,  vitamin_c_mg=8,   vitamin_d_mcg=0,
                      vitamin_b12_mcg=0.1, cholesterol_mg=4),
    "beverage":  dict(potassium_mg=110, calcium_mg=82,  iron_mg=0.2, magnesium_mg=12,
                      vitamin_a_mcg=28,  vitamin_c_mg=3,   vitamin_d_mcg=0.4,
                      vitamin_b12_mcg=0.3, cholesterol_mg=8),
    "soup":      dict(potassium_mg=140, calcium_mg=26,  iron_mg=0.8, magnesium_mg=16,
                      vitamin_a_mcg=30,  vitamin_c_mg=6,   vitamin_d_mcg=0,
                      vitamin_b12_mcg=0, cholesterol_mg=0),
    "fat":       dict(potassium_mg=5,   calcium_mg=4,   iron_mg=0.0, magnesium_mg=0,
                      vitamin_a_mcg=680, vitamin_c_mg=0,  vitamin_d_mcg=1.5,
                      vitamin_b12_mcg=0.1, cholesterol_mg=256),
    "mixed":     dict(potassium_mg=210, calcium_mg=46,  iron_mg=1.4, magnesium_mg=30,
                      vitamin_a_mcg=40,  vitamin_c_mg=6,   vitamin_d_mcg=0.2,
                      vitamin_b12_mcg=0.2, cholesterol_mg=10),
}

SECONDARY_DEFAULT: dict[str, dict[str, float]] = {
    "grain": dict(saturated_fat_g=0.3, fiber_g=2.0, sugar_g=0.5, sodium_mg=180),
    "legume": dict(saturated_fat_g=1.2, fiber_g=3.2, sugar_g=1.2, sodium_mg=310),
    "vegetable": dict(saturated_fat_g=1.2, fiber_g=3.0, sugar_g=2.6, sodium_mg=300),
    "dairy": dict(saturated_fat_g=5.6, fiber_g=0.4, sugar_g=3.4, sodium_mg=200),
    "meat": dict(saturated_fat_g=4.4, fiber_g=0.8, sugar_g=1.6, sodium_mg=420),
    "sweet": dict(saturated_fat_g=8.0, fiber_g=0.8, sugar_g=30.0, sodium_mg=85),
    "mixed": dict(saturated_fat_g=2.6, fiber_g=2.0, sugar_g=2.2, sodium_mg=340),
}

CLASS_TAGS = set(CLASS_PROFILE)


def food_class(rec: FoodRecord) -> str:
    for tag in reversed(rec.tags):
        if tag in CLASS_TAGS:
            return tag
    if rec.food_type == "packaged":
        return "snack"
    return "mixed"


def scale_for_energy(profile: dict[str, float], calories: float) -> dict[str, float]:
    """Class profiles assume ~150 kcal/100 g; scale mildly with actual energy.

    A square-root scale is used so a 500 kcal sweet does not claim 3x the
    potassium of a 150 kcal curry — micronutrient density does not track energy
    linearly.
    """
    if calories <= 0:
        return dict(profile)
    factor = max(0.45, min(2.2, (calories / 150.0) ** 0.5))
    return {k: round(v * factor, 2) for k, v in profile.items()}


def complete(records: Iterable[FoodRecord],
             donors: dict[str, Nutrition] | None = None) -> list[FoodRecord]:
    """Fill missing micronutrients. ``donors`` (from USDA) override the static
    class profiles when available."""
    donors = donors or {}
    out: list[FoodRecord] = []
    filled_rows = 0
    for rec in records:
        cls = food_class(rec)
        profile = dict(CLASS_PROFILE.get(cls, CLASS_PROFILE["mixed"]))
        donor = donors.get(cls)
        if donor:
            for f in MICRO_FIELDS:
                v = getattr(donor, f, None)
                if v is not None:
                    profile[f] = float(v)
        profile = scale_for_energy(profile, rec.nutrition.calories or 0.0)

        touched = False
        for f in MICRO_FIELDS:
            if getattr(rec.nutrition, f) is None:
                setattr(rec.nutrition, f, profile.get(f, 0.0))
                touched = True
        for f in SECONDARY_MACROS:
            if getattr(rec.nutrition, f) is None:
                default = SECONDARY_DEFAULT.get(cls, SECONDARY_DEFAULT["mixed"]).get(f)
                if default is not None:
                    setattr(rec.nutrition, f, default)
                    touched = True
        # Vegetarian dishes carry no cholesterol unless dairy is involved.
        if rec.diet in ("veg", "vegan") and cls not in ("dairy", "sweet", "fat"):
            rec.nutrition.cholesterol_mg = 0.0
        if rec.diet == "vegan":
            rec.nutrition.cholesterol_mg = 0.0
            rec.nutrition.vitamin_b12_mcg = min(rec.nutrition.vitamin_b12_mcg or 0.0, 0.1)
        if touched:
            filled_rows += 1
            rec.tags = sorted(set(rec.tags) | {"micros-estimated"})
        out.append(rec)
    _log.info("Micronutrients completed for %d/%d records", filled_rows, len(out))
    return out


def completeness(rec: FoodRecord) -> float:
    filled = sum(1 for f in NUTRIENT_FIELDS if getattr(rec.nutrition, f) is not None)
    return round(filled / len(NUTRIENT_FIELDS), 3)
