"""Slugs, name cleaning, Devanagari handling and fuzzy keys for dedupe."""
from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable

_WS = re.compile(r"\s+")
_NON_SLUG = re.compile(r"[^a-z0-9]+")
_PARENS = re.compile(r"\([^)]*\)")
_DEVANAGARI = re.compile(r"[ऀ-ॿ]")

# Tokens that carry no discriminating meaning when matching two food names.
STOPWORDS = {
    "indian", "recipe", "recipes", "homemade", "style", "traditional", "authentic",
    "fresh", "raw", "cooked", "boiled", "plain", "the", "and", "with", "of", "a",
    "dish", "food", "curry", "gravy", "dry", "veg", "vegetarian",
}

# Common spelling variants seen across IFCT / USDA / Wikipedia / Open Food Facts.
SPELLING_MAP = {
    "chappati": "chapati", "chapathi": "chapati", "roti": "roti", "rotti": "roti",
    "dosai": "dosa", "dhosa": "dosa", "idly": "idli", "iddli": "idli",
    "sambhar": "sambar", "sambaar": "sambar", "rasam": "rasam",
    "paneer": "paneer", "panir": "paneer", "channa": "chana", "chhole": "chole",
    "chholay": "chole", "cholay": "chole", "rajmah": "rajma", "raajma": "rajma",
    "biriyani": "biryani", "biriani": "biryani", "briyani": "biryani",
    "parantha": "paratha", "parotta": "paratha", "porotta": "paratha",
    "curd": "dahi", "yoghurt": "yogurt", "brinjal": "eggplant", "aubergine": "eggplant",
    "ladyfinger": "okra", "bhindi": "okra", "capsicum": "bell pepper",
    "jeera": "cumin", "haldi": "turmeric", "dhania": "coriander",
    "gobi": "cauliflower", "gobhi": "cauliflower", "aloo": "potato",
    "khichdi": "khichdi", "khichadi": "khichdi", "kitchari": "khichdi",
    "lassi": "lassi", "laasi": "lassi", "halva": "halwa", "haleem": "haleem",
    "vada": "vada", "wada": "vada", "bada": "vada", "pakora": "pakora",
    "pakoda": "pakora", "bhajji": "pakora", "bajji": "pakora",
    "samosa": "samosa", "samoosa": "samosa", "jalebi": "jalebi", "jilebi": "jalebi",
    "kheer": "kheer", "payasam": "kheer", "phirni": "phirni",
    "dal": "dal", "daal": "dal", "dhal": "dal", "dahl": "dal",
    "poha": "poha", "pohe": "poha", "upma": "upma", "uppuma": "upma",
    "thali": "thali", "puri": "puri", "poori": "puri", "bhatura": "bhatura",
    "bhature": "bhatura", "naan": "naan", "nan": "naan", "kulcha": "kulcha",
}


def strip_accents(value: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", value) if not unicodedata.combining(c)
    )


def has_devanagari(value: str) -> bool:
    return bool(_DEVANAGARI.search(value or ""))


def clean_name(value: str, *, strip_parens: bool = True) -> str:
    """Human-facing title case name with noise removed.

    ``strip_parens`` removes parenthesised source noise (``"Rice, white (raw)"``).
    Turn it off for names where the parenthesis is meaningful — our own variant
    labels such as ``"Paneer Paratha (Low Oil)"``.
    """
    value = (value or "").replace("_", " ")
    if strip_parens:
        value = _PARENS.sub(" ", value)
    value = value.replace("—", "-").replace("–", "-")
    value = _WS.sub(" ", value).strip(" -,;:")
    if not value:
        return ""
    # Preserve existing capitalisation if the author already used mixed case.
    if value.isupper() or value.islower():
        value = " ".join(w.capitalize() if len(w) > 2 else w.lower() for w in value.split())
        value = value[0].upper() + value[1:]
    return value


def slugify(value: str, *, max_len: int = 64) -> str:
    value = strip_accents(value or "").lower()
    value = _NON_SLUG.sub("_", value).strip("_")
    if len(value) > max_len:
        value = value[:max_len].rstrip("_")
    return value or "item"


def canonical_tokens(value: str) -> list[str]:
    """Normalised, spelling-folded, stopword-free tokens for match keys."""
    value = strip_accents((value or "").lower())
    value = _PARENS.sub(" ", value)
    raw = [t for t in _NON_SLUG.split(value) if t]
    out: list[str] = []
    for tok in raw:
        tok = SPELLING_MAP.get(tok, tok)
        if tok in STOPWORDS or len(tok) < 2:
            continue
        out.append(tok)
    return out


def match_key(value: str) -> str:
    """Order-insensitive key: 'Chana Masala' and 'masala chana' collide."""
    return " ".join(sorted(set(canonical_tokens(value))))


def jaccard(a: Iterable[str], b: Iterable[str]) -> float:
    sa, sb = set(a), set(b)
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def truncate(value: str, limit: int) -> str:
    value = _WS.sub(" ", (value or "").strip())
    if len(value) <= limit:
        return value
    cut = value[:limit]
    if " " in cut:
        cut = cut[: cut.rfind(" ")]
    return cut.rstrip(" ,;:") + "…"


def search_blob(*parts: object) -> str:
    """Everything that should be findable by FTS for one row, space joined."""
    chunks: list[str] = []
    for p in parts:
        if p is None:
            continue
        if isinstance(p, (list, tuple, set)):
            chunks.extend(str(x) for x in p if x)
        elif isinstance(p, dict):
            chunks.extend(str(x) for x in p.values() if x)
        else:
            s = str(p)
            if s:
                chunks.append(s)
    return _WS.sub(" ", " ".join(chunks)).strip()
