"""Nutrition validation: bounds, Atwater cross-check, macro-mass sanity."""
from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass

from ..config import ATWATER_TOLERANCE, NUTRIENT_BOUNDS
from ..models import NUTRIENT_FIELDS, FoodRecord
from ..util import log

_log = log.get("ifca.validate")


@dataclass
class ValidationReport:
    total: int = 0
    clamped: int = 0
    recomputed_calories: int = 0
    dropped: int = 0
    macro_mass_fixed: int = 0
    reasons: dict[str, int] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.reasons is None:
            self.reasons = {}

    def note(self, reason: str) -> None:
        self.reasons[reason] = self.reasons.get(reason, 0) + 1

    def as_dict(self) -> dict:
        return {
            "total": self.total, "clamped": self.clamped,
            "recomputed_calories": self.recomputed_calories,
            "macro_mass_fixed": self.macro_mass_fixed,
            "dropped": self.dropped, "reasons": self.reasons,
        }


def atwater_calories(rec: FoodRecord) -> float:
    n = rec.nutrition
    return (n.protein_g or 0) * 4 + (n.carbs_g or 0) * 4 + (n.fat_g or 0) * 9


def validate(records: Iterable[FoodRecord]) -> tuple[list[FoodRecord], ValidationReport]:
    report = ValidationReport()
    kept: list[FoodRecord] = []
    for rec in records:
        report.total += 1
        n = rec.nutrition
        # 1. hard bounds ---------------------------------------------------
        for field in NUTRIENT_FIELDS:
            v = getattr(n, field)
            if v is None:
                continue
            lo, hi = NUTRIENT_BOUNDS[field]
            if v < lo or v > hi:
                setattr(n, field, max(lo, min(hi, float(v))))
                report.clamped += 1
                report.note(f"bounds:{field}")

        # 2. macro mass cannot exceed 100 g per 100 g ----------------------
        macro_mass = (n.protein_g or 0) + (n.carbs_g or 0) + (n.fat_g or 0)
        if macro_mass > 100.5:
            scale = 100.0 / macro_mass
            n.protein_g = round((n.protein_g or 0) * scale, 2)
            n.carbs_g = round((n.carbs_g or 0) * scale, 2)
            n.fat_g = round((n.fat_g or 0) * scale, 2)
            report.macro_mass_fixed += 1
            report.note("macro_mass>100")

        # 3. saturated fat cannot exceed total fat -------------------------
        if n.saturated_fat_g is not None and n.fat_g is not None and n.saturated_fat_g > n.fat_g:
            n.saturated_fat_g = round(n.fat_g, 2)
            report.note("satfat>fat")

        # 4. sugar cannot exceed carbs -------------------------------------
        if n.sugar_g is not None and n.carbs_g is not None and n.sugar_g > n.carbs_g + 0.5:
            n.sugar_g = round(n.carbs_g, 2)
            report.note("sugar>carbs")

        # 5. fibre cannot exceed carbs (fibre is counted inside carbs here) -
        if n.fiber_g is not None and n.carbs_g is not None and n.fiber_g > n.carbs_g + 0.5:
            n.fiber_g = round(n.carbs_g, 2)
            report.note("fiber>carbs")

        # 6. Atwater cross-check -------------------------------------------
        derived = atwater_calories(rec)
        if derived > 0:
            if not n.calories or n.calories <= 0:
                n.calories = round(derived, 1)
                report.recomputed_calories += 1
                report.note("calories_missing")
            else:
                drift = abs(n.calories - derived) / max(derived, 1.0)
                if drift > ATWATER_TOLERANCE:
                    n.calories = round(derived, 1)
                    report.recomputed_calories += 1
                    report.note("atwater_drift")

        # 7. drop rows with no usable energy signal -------------------------
        if (n.calories or 0) <= 0:
            report.dropped += 1
            report.note("no_calories")
            continue

        # 8. plausibility: vegetarian rows should not carry cholesterol -----
        if rec.diet in ("veg", "vegan") and (n.cholesterol_mg or 0) > 0 and "dairy" not in rec.tags:
            n.cholesterol_mg = 0.0
            report.note("veg_cholesterol")

        kept.append(rec)

    _log.info("Validated %d records (clamped=%d, kcal recomputed=%d, dropped=%d)",
              report.total, report.clamped, report.recomputed_calories, report.dropped)
    return kept, report
