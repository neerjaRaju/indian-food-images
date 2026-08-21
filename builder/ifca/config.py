"""Central configuration for the Indian Food Calories database builder.

Every tunable lives here or in ``hosting.yaml`` so that switching an image
host, a dataset mirror, or a size target never requires touching pipeline code.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
BUILDER_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = BUILDER_ROOT.parent

WORK_DIR = Path(os.environ.get("IFCA_WORK_DIR", BUILDER_ROOT / "build"))
RAW_DIR = WORK_DIR / "raw"            # downloaded datasets, untouched
INTERIM_DIR = WORK_DIR / "interim"    # normalized json/parquet
IMAGE_SRC_DIR = WORK_DIR / "images_src"
IMAGE_OUT_DIR = WORK_DIR / "images"
DIST_DIR = WORK_DIR / "dist"          # release-ready assets
CACHE_DIR = WORK_DIR / "cache"

for _d in (RAW_DIR, INTERIM_DIR, IMAGE_SRC_DIR, IMAGE_OUT_DIR, DIST_DIR, CACHE_DIR):
    _d.mkdir(parents=True, exist_ok=True)

DB_NAME = "indian_food.db"
DB_PATH = DIST_DIR / DB_NAME
MANIFEST_PATH = DIST_DIR / "image_manifest.json"
METADATA_PATH = DIST_DIR / "metadata.json"

SEED_DIR = BUILDER_ROOT / "data"

# --------------------------------------------------------------------------- #
# Database schema version — bump when schema.sql changes shape
# --------------------------------------------------------------------------- #
SCHEMA_VERSION = 3

# --------------------------------------------------------------------------- #
# Image rendition targets
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Rendition:
    name: str
    size: int
    quality: int
    max_bytes: int          # soft ceiling; quality is stepped down to hit it
    folder: str


RENDITIONS: tuple[Rendition, ...] = (
    Rendition("thumbnail", 200, 78, 20 * 1024, "thumbnails"),
    Rendition("medium", 512, 80, 50 * 1024, "medium"),
    Rendition("large", 1024, 82, 120 * 1024, "large"),
)

PHASH_DISTANCE_THRESHOLD = 6      # <= this Hamming distance == duplicate image
MIN_SOURCE_EDGE = 300             # reject source images smaller than this

# --------------------------------------------------------------------------- #
# Nutrition validation envelopes (per 100 g). Values outside are rejected or
# clamped — see pipeline/validate.py.
# --------------------------------------------------------------------------- #
NUTRIENT_BOUNDS: dict[str, tuple[float, float]] = {
    "calories": (0, 900),
    "protein_g": (0, 90),
    "carbs_g": (0, 100),
    "fat_g": (0, 100),
    "saturated_fat_g": (0, 100),
    "fiber_g": (0, 80),
    "sugar_g": (0, 100),
    "sodium_mg": (0, 40000),
    "potassium_mg": (0, 5000),
    "calcium_mg": (0, 3000),
    "iron_mg": (0, 60),
    "magnesium_mg": (0, 800),
    "vitamin_a_mcg": (0, 30000),
    "vitamin_c_mg": (0, 2000),
    "vitamin_d_mcg": (0, 250),
    "vitamin_b12_mcg": (0, 100),
    "cholesterol_mg": (0, 3500),
}

# Atwater factors used to cross-check declared calories.
ATWATER = {"protein_g": 4.0, "carbs_g": 4.0, "fat_g": 9.0, "fiber_g": -0.0}
ATWATER_TOLERANCE = 0.35          # 35 % drift allowed before we recompute

# --------------------------------------------------------------------------- #
# Hosting providers
# --------------------------------------------------------------------------- #
DEFAULT_HOSTING: dict[str, Any] = {
    "active": "jsdelivr",
    "providers": {
        "jsdelivr": {
            "type": "jsdelivr",
            "owner": "CHANGE_ME",
            "repo": "indian-food-images",
            "ref": "latest",
            "base_path": "images/foods",
            "template": "https://cdn.jsdelivr.net/gh/{owner}/{repo}@{ref}/{base_path}/{folder}/{slug}.webp",
        },
        "github_releases": {
            "type": "github_releases",
            "owner": "CHANGE_ME",
            "repo": "indian-food-images",
            "tag": "images-latest",
            "template": "https://github.com/{owner}/{repo}/releases/download/{tag}/{folder}_{slug}.webp",
        },
        "github_pages": {
            "type": "static",
            "template": "https://{owner}.github.io/{repo}/images/foods/{folder}/{slug}.webp",
            "owner": "CHANGE_ME",
            "repo": "indian-food-images",
        },
        "cloudflare_r2": {
            "type": "static",
            "template": "https://{account}.r2.dev/images/foods/{folder}/{slug}.webp",
            "account": "CHANGE_ME",
        },
        "cloudflare_cdn": {
            "type": "static",
            "template": "https://{domain}/images/foods/{folder}/{slug}.webp",
            "domain": "cdn.example.com",
        },
        "netlify": {
            "type": "static",
            "template": "https://{site}.netlify.app/images/foods/{folder}/{slug}.webp",
            "site": "CHANGE_ME",
        },
        "vercel": {
            "type": "static",
            "template": "https://{site}.vercel.app/images/foods/{folder}/{slug}.webp",
            "site": "CHANGE_ME",
        },
        "firebase": {
            "type": "static",
            "template": "https://{project}.web.app/images/foods/{folder}/{slug}.webp",
            "project": "CHANGE_ME",
        },
        "custom_https": {
            "type": "static",
            "template": "https://{host}/{base_path}/{folder}/{slug}.webp",
            "host": "example.com",
            "base_path": "images/foods",
        },
    },
}

HOSTING_FILE = BUILDER_ROOT / "hosting.yaml"


@dataclass
class HostingConfig:
    active: str
    providers: dict[str, dict[str, Any]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path | None = None) -> HostingConfig:
        path = path or HOSTING_FILE
        if path.exists():
            data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        else:
            data = DEFAULT_HOSTING
        merged = {**DEFAULT_HOSTING, **data}
        merged["providers"] = {**DEFAULT_HOSTING["providers"], **(data.get("providers") or {})}
        active = os.environ.get("IFCA_HOSTING_PROVIDER", merged.get("active", "jsdelivr"))
        return cls(active=active, providers=merged["providers"])

    @property
    def provider(self) -> dict[str, Any]:
        if self.active not in self.providers:
            raise KeyError(
                f"Unknown hosting provider {self.active!r}. "
                f"Known: {sorted(self.providers)}"
            )
        return self.providers[self.active]

    def url_for(self, slug: str, folder: str) -> str:
        p = dict(self.provider)
        template = p.pop("template")
        p.pop("type", None)
        # env overrides let CI inject the real owner/repo without editing yaml
        p["owner"] = os.environ.get("IFCA_IMAGE_OWNER", p.get("owner", ""))
        p["repo"] = os.environ.get("IFCA_IMAGE_REPO", p.get("repo", ""))
        return template.format(slug=slug, folder=folder, **p)


def write_default_hosting(path: Path | None = None) -> Path:
    path = path or HOSTING_FILE
    if not path.exists():
        path.write_text(yaml.safe_dump(DEFAULT_HOSTING, sort_keys=False), encoding="utf-8")
    return path


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
USER_AGENT = (
    "IndianFoodCaloriesBuilder/1.0 "
    "(+https://github.com/indian-food-calories/app; offline nutrition database builder)"
)
HTTP_TIMEOUT = 45
HTTP_RETRIES = 4
HTTP_CONCURRENCY = int(os.environ.get("IFCA_HTTP_CONCURRENCY", "12"))
