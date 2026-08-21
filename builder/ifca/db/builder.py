"""Write the shipped SQLite database."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import sqlite3
from collections.abc import Sequence
from pathlib import Path

from ..config import DB_PATH, SCHEMA_VERSION
from ..models import NUTRIENT_FIELDS, FoodRecord
from ..pipeline import micros as micros_mod
from ..pipeline.micros import completeness
from ..pipeline.normalize import CANONICAL_CATEGORIES, derived_categories
from ..util import log
from ..util.text import slugify

_log = log.get("ifca.db")

SCHEMA_FILE = Path(__file__).with_name("schema.sql")

CATEGORY_ICONS = {
    "North Indian": "🍛", "South Indian": "🥞", "Gujarati": "🥗", "Punjabi": "🧈",
    "Bengali": "🐟", "Maharashtrian": "🌶️", "Rajasthani": "🏜️", "Kashmiri": "🍲",
    "Assamese": "🌿", "Odia": "🛕", "Bihari": "🔥", "Goan": "🥥",
    "Vegetarian": "🥬", "Vegan": "🌱", "Jain": "🙏", "Seafood": "🦐",
    "Chicken": "🍗", "Mutton": "🍖", "Eggs": "🥚", "Fast Food": "🍔",
    "Healthy Foods": "💪", "Snacks": "🥨", "Sweets": "🍬", "Drinks": "🥤",
    "Fruits": "🥭", "Vegetables": "🥕", "Dairy": "🥛", "Street Food": "🛺",
    "Recipes": "👩‍🍳", "Packaged": "📦", "Restaurant": "🍽️",
}

CATEGORY_KIND = {
    "Vegetarian": "diet", "Vegan": "diet", "Jain": "diet", "Eggs": "diet",
    "Healthy Foods": "diet", "Recipes": "source", "Packaged": "source",
    "Restaurant": "source", "Snacks": "course", "Sweets": "course",
    "Drinks": "course", "Fruits": "course", "Vegetables": "course",
    "Dairy": "course", "Street Food": "course", "Fast Food": "course",
    "Seafood": "course", "Chicken": "course", "Mutton": "course",
}

# Popularity seeds — dishes users search for constantly float to the top of
# ambiguous matches. Everything else is scored by data completeness.
POPULAR = {
    "roti": 100, "chapati": 98, "rice": 97, "dal_tadka": 96, "paneer": 95,
    "idli": 94, "dosa": 93, "chicken_biryani": 92, "masala_dosa": 91,
    "butter_chicken": 90, "poha": 89, "upma": 88, "samosa": 87, "chai": 86,
    "masala_chai": 86, "curd_dahi": 85, "boiled_egg": 84, "paratha": 83,
    "aloo_paratha": 82, "rajma": 81, "chole": 80, "sambar": 79, "khichdi": 78,
    "pav_bhaji": 77, "vada_pav": 76, "banana": 75, "apple": 74, "mango": 73,
    "milk": 72, "cow_milk": 72, "palak_paneer": 71, "paneer_butter_masala": 70,
}


def _connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    for suffix in ("-wal", "-shm"):
        p = Path(str(path) + suffix)
        if p.exists():
            p.unlink()
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA page_size = 4096")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = OFF")
    conn.execute("PRAGMA temp_store = MEMORY")
    conn.execute("PRAGMA cache_size = -80000")
    return conn


def _popularity(rec: FoodRecord) -> int:
    base = POPULAR.get(rec.slug, 0)
    if base:
        return base
    score = int(completeness(rec) * 40)
    if rec.image:
        score += 12
    if "variant" in rec.tags:
        score -= 8
    if rec.food_type == "packaged":
        score -= 4
    if rec.hindi_name:
        score += 4
    return max(0, min(69, score))


def _regional_blob(rec: FoodRecord) -> str:
    return " ".join(v for v in rec.regional_names.values() if v)


class DatabaseBuilder:
    def __init__(self, path: Path = DB_PATH) -> None:
        self.path = path

    # ------------------------------------------------------------------ #
    def build(self, records: Sequence[FoodRecord], *, stats: dict | None = None) -> Path:
        conn = _connect(self.path)
        try:
            conn.executescript(SCHEMA_FILE.read_text(encoding="utf-8"))
            cat_ids = self._write_categories(conn)
            self._write_foods(conn, records, cat_ids)
            self._write_alternatives(conn)
            self._update_counts(conn)
            self._write_meta(conn, records, stats or {})
            conn.commit()
        finally:
            conn.close()
        self.optimize()
        _log.info("Database written: %s (%.1f MB)", self.path, self.path.stat().st_size / 1e6)
        return self.path

    # ------------------------------------------------------------------ #
    def _write_categories(self, conn: sqlite3.Connection) -> dict[str, int]:
        rows = []
        for i, name in enumerate(CANONICAL_CATEGORIES):
            rows.append((i + 1, slugify(name), name, CATEGORY_KIND.get(name, "cuisine"),
                         CATEGORY_ICONS.get(name, "🍽️"), i))
        conn.executemany(
            "INSERT INTO categories(id, slug, name, kind, icon, sort_order) VALUES (?,?,?,?,?,?)",
            rows,
        )
        return {r[2]: r[0] for r in rows}

    def _write_foods(self, conn: sqlite3.Connection, records: Sequence[FoodRecord],
                     cat_ids: dict[str, int]) -> None:
        nutrition_cols = ", ".join(NUTRIENT_FIELDS)
        placeholders = ", ".join("?" * len(NUTRIENT_FIELDS))
        insert_food = f"""
            INSERT INTO foods (
                id, slug, name, hindi_name, regional_names, synonyms, description,
                category_id, food_type, diet, is_vegan, is_jain, barcode, brand,
                restaurant, region, food_class, tags, {nutrition_cols},
                thumbnail_url, image_url, large_url, image_source, image_credit,
                license, license_url, source, source_url, confidence,
                micros_estimated, completeness, popularity, last_updated
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,{placeholders},
                      ?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        food_rows: list[tuple] = []
        fts_rows: list[tuple] = []
        serving_rows: list[tuple] = []
        recipe_rows: list[tuple] = []
        link_rows: list[tuple] = []
        seen_barcodes: set[str] = set()

        for fid, rec in enumerate(records, start=1):
            img = rec.image
            barcode = rec.barcode if rec.barcode and rec.barcode not in seen_barcodes else ""
            if barcode:
                seen_barcodes.add(barcode)
            nutrition = tuple(getattr(rec.nutrition, f) for f in NUTRIENT_FIELDS)
            food_rows.append((
                fid, rec.slug, rec.name, rec.hindi_name,
                json.dumps(rec.regional_names, ensure_ascii=False),
                json.dumps(rec.synonyms, ensure_ascii=False),
                rec.description,
                cat_ids.get(rec.category, cat_ids["North Indian"]),
                rec.food_type, rec.diet, int(rec.is_vegan), int(rec.is_jain),
                barcode, rec.brand, rec.restaurant, rec.region,
                micros_mod.food_class(rec), ",".join(rec.tags),
                *nutrition,
                img.thumbnail_url if img else "",
                img.medium_url if img else "",
                img.large_url if img else "",
                img.source_name if img else "",
                img.credit if img else "",
                img.license if img else "",
                img.license_url if img else "",
                rec.source, rec.source_url, rec.confidence,
                int("micros-estimated" in rec.tags),
                completeness(rec), _popularity(rec), rec.last_updated,
            ))
            fts_rows.append((fid, rec.name, rec.hindi_name, _regional_blob(rec),
                             " ".join(rec.synonyms), " ".join(rec.tags), rec.brand))
            for s in rec.servings:
                serving_rows.append((fid, s.unit, s.label, s.grams, int(s.is_default), s.sort_order))
            if rec.food_type == "recipe" or rec.ingredients:
                recipe_rows.append((fid,
                                    json.dumps(rec.ingredients, ensure_ascii=False),
                                    json.dumps(rec.steps, ensure_ascii=False),
                                    rec.prep_minutes, rec.cook_minutes))
            for cat in derived_categories(rec):
                cid = cat_ids.get(cat)
                if cid:
                    link_rows.append((fid, cid))

        conn.executemany(insert_food, food_rows)
        conn.executemany(
            "INSERT INTO foods_fts(rowid, name, hindi_name, regional, synonyms, tags, brand)"
            " VALUES (?,?,?,?,?,?,?)", fts_rows)
        conn.executemany(
            "INSERT INTO servings(food_id, unit, label, grams, is_default, sort_order)"
            " VALUES (?,?,?,?,?,?)", serving_rows)
        conn.executemany(
            "INSERT INTO recipes(food_id, ingredients, steps, prep_minutes, cook_minutes)"
            " VALUES (?,?,?,?,?)", recipe_rows)
        conn.executemany(
            "INSERT OR IGNORE INTO food_categories(food_id, category_id) VALUES (?,?)", link_rows)
        _log.info("Inserted %d foods, %d servings, %d recipes, %d category links",
                  len(food_rows), len(serving_rows), len(recipe_rows), len(link_rows))

    def _write_alternatives(self, conn: sqlite3.Connection, per_food: int = 4) -> None:
        """For each food, precompute lower-calorie swaps from the same category."""
        conn.execute("""
            CREATE TEMP TABLE alt_src AS
            SELECT id, category_id, food_class, calories, protein_g, fiber_g,
                   name, popularity
            FROM foods
            WHERE food_type IN ('food', 'recipe')
              AND instr(tags, 'variant') = 0
        """)
        conn.execute("CREATE INDEX temp.idx_alt_src ON alt_src(food_class, calories)")
        rows = conn.execute("""
            SELECT a.id, b.id,
                   ROUND(b.calories - a.calories, 1) AS delta,
                   ROW_NUMBER() OVER (
                       PARTITION BY a.id
                       ORDER BY (a.calories - b.calories) DESC, b.popularity DESC
                   ) AS rnk
            FROM alt_src a
            JOIN alt_src b
              ON b.food_class = a.food_class
             AND b.id <> a.id
             AND b.calories <= a.calories * 0.78
             AND b.protein_g >= a.protein_g * 0.7
            WHERE a.calories > 90
        """).fetchall()
        payload = [(fid, alt, f"{abs(delta):.0f} kcal less per 100 g, same kind of dish",
                    delta, rnk)
                   for fid, alt, delta, rnk in rows if rnk <= per_food]
        conn.executemany(
            "INSERT OR IGNORE INTO alternatives(food_id, alt_food_id, reason, kcal_delta, rank)"
            " VALUES (?,?,?,?,?)", payload)
        conn.execute("DROP TABLE alt_src")
        _log.info("Precomputed %d healthy alternatives", len(payload))

    def _update_counts(self, conn: sqlite3.Connection) -> None:
        conn.execute("""
            UPDATE categories SET food_count = (
                SELECT COUNT(*) FROM food_categories fc WHERE fc.category_id = categories.id
            )
        """)

    def _write_meta(self, conn: sqlite3.Connection, records: Sequence[FoodRecord],
                    stats: dict) -> None:
        now = dt.datetime.now(dt.UTC).isoformat(timespec="seconds")
        counts = {
            "foods": len(records),
            "recipes": sum(1 for r in records if r.food_type == "recipe"),
            "packaged": sum(1 for r in records if r.food_type == "packaged"),
            "with_images": sum(1 for r in records if r.image),
            "with_hindi": sum(1 for r in records if r.hindi_name),
            "with_barcode": sum(1 for r in records if r.barcode),
        }
        meta = {
            "schema_version": str(SCHEMA_VERSION),
            "generated_at": now,
            "database_date": dt.date.today().isoformat(),
            "counts": json.dumps(counts),
            "pipeline_stats": json.dumps(stats),
            "attribution": json.dumps({
                "nutrition": ["IFCT 2017 (NIN/ICMR)", "USDA FoodData Central (public domain)",
                              "Open Food Facts (ODbL 1.0)"],
                "text": ["Wikipedia (CC BY-SA 4.0)"],
                "images": ["Wikimedia Commons", "Open Food Facts"],
            }),
        }
        conn.executemany("INSERT OR REPLACE INTO meta(key, value) VALUES (?,?)",
                         list(meta.items()))

    # ------------------------------------------------------------------ #
    def optimize(self) -> None:
        conn = sqlite3.connect(str(self.path))
        try:
            conn.execute("INSERT INTO foods_fts(foods_fts) VALUES('optimize')")
            conn.commit()
            conn.execute("PRAGMA journal_mode = DELETE")   # single-file artifact
            conn.execute("ANALYZE")
            conn.commit()
            conn.execute("VACUUM")
            conn.commit()
        finally:
            conn.close()

    def checksum(self) -> str:
        h = hashlib.sha256()
        with self.path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
