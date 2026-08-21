"""Unit tests for the database builder pipeline."""
from __future__ import annotations

import sqlite3

import pytest

from ifca.config import NUTRIENT_BOUNDS, HostingConfig
from ifca.db.builder import DatabaseBuilder
from ifca.models import NUTRIENT_FIELDS, FoodRecord, Nutrition, ServingSize
from ifca.pipeline import dedupe as dedupe_mod
from ifca.pipeline import micros as micros_mod
from ifca.pipeline import normalize as normalize_mod
from ifca.pipeline import validate as validate_mod
from ifca.sources.curated import CuratedIndianSource, VariantExpander, build_servings
from ifca.sources.recipes import (
    IngredientResolver,
    RecipeSource,
    compute_nutrition,
    load_ingredients,
)
from ifca.util.text import canonical_tokens, clean_name, match_key, slugify


# --------------------------------------------------------------------------- #
# text helpers
# --------------------------------------------------------------------------- #
def test_slugify_is_url_safe():
    assert slugify("Paneer Butter Masala") == "paneer_butter_masala"
    assert slugify("Chhena Poda (Odia)") == "chhena_poda_odia"
    assert slugify("!!!") == "item"


def test_clean_name_can_keep_our_own_variant_labels():
    assert clean_name("rice, white (raw)") == "Rice, White"
    assert clean_name("Roti (with Ghee)", strip_parens=False) == "Roti (with Ghee)"


def test_match_key_is_order_insensitive_and_spelling_tolerant():
    assert match_key("Chana Masala") == match_key("masala chana")
    # dal/daal/dhal all fold to the same token
    assert match_key("Daal Tadka") == match_key("Dal Tadka")


def test_stopwords_do_not_dominate_a_match_key():
    assert "curry" not in canonical_tokens("Chicken Curry")
    assert "chicken" in canonical_tokens("Chicken Curry")


# --------------------------------------------------------------------------- #
# curated source
# --------------------------------------------------------------------------- #
def test_curated_source_loads_and_every_row_has_energy():
    records = CuratedIndianSource().run()
    assert len(records) > 200
    assert all(r.nutrition.calories > 0 for r in records)
    assert all(r.hindi_name for r in records), "every curated row carries a native name"


def test_curated_rows_have_unique_slugs_after_normalisation():
    records = normalize_mod.normalize(CuratedIndianSource().run())
    slugs = [r.slug for r in records]
    assert len(slugs) == len(set(slugs))


def test_build_servings_always_includes_100g_and_custom():
    servings = build_servings("roti", 40, "grain")
    units = [s.unit for s in servings]
    assert "100g" in units and "custom" in units
    default = [s for s in servings if s.is_default]
    assert len(default) == 1 and default[0].unit == "roti"


def test_variant_expander_reduces_fat_for_low_oil():
    base = CuratedIndianSource().run()[0]
    variants = VariantExpander().expand(base)
    assert variants, "at least one rule should apply to a staple"
    for v in variants:
        assert v.slug != base.slug
        assert "variant" in v.tags
        assert v.confidence < base.confidence


def test_variant_recomputes_calories_from_macros():
    rec = FoodRecord(
        slug="x", name="X", category="North Indian",
        nutrition=Nutrition(calories=200, protein_g=5, carbs_g=20, fat_g=10),
        tags=["vegetable"],
    )
    variants = VariantExpander().expand(rec)
    low_oil = next(v for v in variants if "Low Oil" in v.name)
    assert low_oil.nutrition.fat_g == pytest.approx(5.5, abs=0.01)
    # 5*4 + 20*4 + 5.5*9 = 149.5
    assert low_oil.nutrition.calories == pytest.approx(149.5, abs=0.6)


# --------------------------------------------------------------------------- #
# recipes
# --------------------------------------------------------------------------- #
def test_recipe_nutrition_is_computed_from_ingredients():
    resolver = IngredientResolver(load_ingredients())
    nut, cooked, pretty = compute_nutrition(
        "100g rice raw; 200g water; 10g ghee; 5g salt", resolver
    )
    assert cooked == pytest.approx(315.0, abs=1)
    # 349 kcal + 90 kcal over 315 g -> ~139 kcal/100 g
    assert nut.calories == pytest.approx(139, abs=3)
    assert nut.sodium_mg > 500
    assert len(pretty) == 4


def test_unknown_ingredients_are_ignored_not_fatal():
    resolver = IngredientResolver(load_ingredients())
    nut, cooked, pretty = compute_nutrition(
        "100g rice raw; 50g unobtainium", resolver
    )
    assert nut.calories > 0
    assert cooked == pytest.approx(100.0, abs=0.1)
    assert "50g unobtainium" in pretty


def test_piece_quantities_use_per_item_weights():
    resolver = IngredientResolver(load_ingredients())
    nut, cooked, _ = compute_nutrition("2 piece egg", resolver)
    assert cooked == pytest.approx(100.0, abs=0.1)
    assert nut.calories == pytest.approx(155, abs=2)


def test_recipe_source_produces_records_with_steps():
    records = RecipeSource().run()
    assert len(records) > 50
    with_steps = [r for r in records if r.steps]
    assert len(with_steps) > 50
    assert all(r.food_type == "recipe" for r in records)


# --------------------------------------------------------------------------- #
# validation
# --------------------------------------------------------------------------- #
def _rec(**nutrition) -> FoodRecord:
    return FoodRecord(
        slug="t", name="T", category="North Indian",
        nutrition=Nutrition(**nutrition),
        servings=[ServingSize("100g", "100 g", 100, True, 0)],
    )


def test_validate_clamps_out_of_range_values():
    rec = _rec(calories=200, protein_g=5, carbs_g=20, fat_g=10, sodium_mg=99999)
    kept, report = validate_mod.validate([rec])
    assert kept[0].nutrition.sodium_mg == NUTRIENT_BOUNDS["sodium_mg"][1]
    assert report.clamped == 1


def test_validate_recomputes_calories_that_disagree_with_macros():
    rec = _rec(calories=1, protein_g=10, carbs_g=30, fat_g=10)
    kept, report = validate_mod.validate([rec])
    assert kept[0].nutrition.calories == pytest.approx(250, abs=1)
    assert report.recomputed_calories == 1


def test_validate_drops_rows_with_no_energy_signal():
    kept, report = validate_mod.validate([_rec(calories=0)])
    assert kept == []
    assert report.dropped == 1


def test_validate_caps_saturated_fat_at_total_fat_and_sugar_at_carbs():
    rec = _rec(calories=300, protein_g=5, carbs_g=10, fat_g=5,
               saturated_fat_g=40, sugar_g=90)
    kept, _ = validate_mod.validate([rec])
    assert kept[0].nutrition.saturated_fat_g <= kept[0].nutrition.fat_g
    assert kept[0].nutrition.sugar_g <= kept[0].nutrition.carbs_g


def test_validate_rescales_macro_mass_over_100g():
    rec = _rec(calories=800, protein_g=60, carbs_g=60, fat_g=40)
    kept, report = validate_mod.validate([rec])
    n = kept[0].nutrition
    assert n.protein_g + n.carbs_g + n.fat_g == pytest.approx(100, abs=0.1)
    assert report.macro_mass_fixed == 1


# --------------------------------------------------------------------------- #
# micronutrients
# --------------------------------------------------------------------------- #
def test_micros_fill_only_missing_fields_and_flag_the_row():
    rec = _rec(calories=150, protein_g=5, carbs_g=20, fat_g=5, iron_mg=9.9)
    rec.tags = ["legume"]
    out = micros_mod.complete([rec])[0]
    assert out.nutrition.iron_mg == 9.9, "measured value must survive"
    assert out.nutrition.calcium_mg is not None
    assert "micros-estimated" in out.tags


def test_vegan_rows_carry_no_cholesterol_or_b12():
    rec = _rec(calories=150, protein_g=5, carbs_g=20, fat_g=5)
    rec.diet = "vegan"
    rec.tags = ["legume"]
    out = micros_mod.complete([rec])[0]
    assert out.nutrition.cholesterol_mg == 0
    assert out.nutrition.vitamin_b12_mcg <= 0.1


def test_completeness_reaches_1_after_micro_completion():
    rec = _rec(calories=150, protein_g=5, carbs_g=20, fat_g=5)
    rec.tags = ["mixed"]
    out = micros_mod.complete([rec])[0]
    assert micros_mod.completeness(out) == 1.0


# --------------------------------------------------------------------------- #
# dedupe
# --------------------------------------------------------------------------- #
def test_dedupe_merges_by_barcode_and_backfills_nulls():
    a = _rec(calories=100, protein_g=1, carbs_g=1, fat_g=1)
    a.barcode = "8901234567890"
    a.confidence = 0.9
    b = _rec(calories=100, protein_g=1, carbs_g=1, fat_g=1, iron_mg=3)
    b.barcode = "8901234567890"
    b.confidence = 0.5
    b.hindi_name = "टेस्ट"
    out, stats = dedupe_mod.dedupe([a, b])
    assert len(out) == 1
    assert stats["by_barcode"] == 1
    assert out[0].nutrition.iron_mg == 3
    assert out[0].hindi_name == "टेस्ट"


def test_dedupe_keeps_variants_distinct():
    base = CuratedIndianSource().run()[0]
    variants = VariantExpander().expand(base)
    out, _ = dedupe_mod.dedupe([base, *variants])
    assert len(out) == len(variants) + 1


def test_dedupe_collapses_reordered_names():
    a = _rec(calories=120, protein_g=6, carbs_g=14, fat_g=4)
    a.name, a.slug = "Chana Masala", "chana_masala"
    b = _rec(calories=118, protein_g=6, carbs_g=14, fat_g=4)
    b.name, b.slug = "Masala Chana", "masala_chana"
    out, _ = dedupe_mod.dedupe([a, b])
    assert len(out) == 1


# --------------------------------------------------------------------------- #
# hosting config
# --------------------------------------------------------------------------- #
def test_hosting_urls_render_for_every_provider():
    cfg = HostingConfig.load()
    for name in cfg.providers:
        cfg.active = name
        url = cfg.url_for("butter_chicken", "medium")
        assert url.startswith("https://")
        assert url.endswith("butter_chicken.webp")


# --------------------------------------------------------------------------- #
# database build (end to end, small)
# --------------------------------------------------------------------------- #
@pytest.fixture()
def built_db(tmp_path):
    records = normalize_mod.normalize(CuratedIndianSource(limit=60).run())
    records = micros_mod.complete(records)
    records, _ = validate_mod.validate(records)
    path = tmp_path / "test.db"
    DatabaseBuilder(path).build(records)
    return path


def test_database_has_expected_tables_and_rows(built_db):
    conn = sqlite3.connect(str(built_db))
    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
    for expected in ("foods", "categories", "servings", "foods_fts",
                     "food_categories", "alternatives", "meta"):
        assert expected in tables
    assert conn.execute("SELECT COUNT(*) FROM foods").fetchone()[0] == 60
    conn.close()


def test_database_fts_search_works(built_db):
    conn = sqlite3.connect(str(built_db))
    rows = conn.execute(
        "SELECT f.name FROM foods_fts JOIN foods f ON f.id = foods_fts.rowid "
        "WHERE foods_fts MATCH ? LIMIT 5", ('"rot"*',)).fetchall()
    assert rows
    conn.close()


def test_database_nutrient_columns_all_present(built_db):
    conn = sqlite3.connect(str(built_db))
    cols = {r[1] for r in conn.execute("PRAGMA table_info(foods)")}
    for field in NUTRIENT_FIELDS:
        assert field in cols
    conn.close()


def test_database_is_a_single_file_without_wal(built_db):
    # The shipped artifact must not need companion -wal/-shm files.
    assert not (built_db.parent / f"{built_db.name}-wal").exists()
    conn = sqlite3.connect(str(built_db))
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode.lower() in ("delete", "truncate")
    conn.close()
