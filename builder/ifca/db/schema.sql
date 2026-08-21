-- ---------------------------------------------------------------------------
-- Indian Food Calories — shipped SQLite schema
-- Read-only on device. The app keeps user data in a separate user.db so that a
-- weekly database swap never touches the user's diary.
-- ---------------------------------------------------------------------------

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS categories (
    id          INTEGER PRIMARY KEY,
    slug        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL DEFAULT 'cuisine',   -- cuisine | diet | course | source
    icon        TEXT NOT NULL DEFAULT '',
    sort_order  INTEGER NOT NULL DEFAULT 0,
    food_count  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS foods (
    id               INTEGER PRIMARY KEY,
    slug             TEXT NOT NULL UNIQUE,
    name             TEXT NOT NULL,
    hindi_name       TEXT NOT NULL DEFAULT '',
    regional_names   TEXT NOT NULL DEFAULT '{}',   -- JSON {lang: name}
    synonyms         TEXT NOT NULL DEFAULT '[]',   -- JSON [str]
    description      TEXT NOT NULL DEFAULT '',
    category_id      INTEGER NOT NULL REFERENCES categories(id),
    food_type        TEXT NOT NULL DEFAULT 'food', -- food | recipe | packaged | restaurant
    diet             TEXT NOT NULL DEFAULT 'veg',  -- veg | vegan | egg | nonveg
    is_vegan         INTEGER NOT NULL DEFAULT 0,
    is_jain          INTEGER NOT NULL DEFAULT 0,
    barcode          TEXT NOT NULL DEFAULT '',
    brand            TEXT NOT NULL DEFAULT '',
    restaurant       TEXT NOT NULL DEFAULT '',
    region           TEXT NOT NULL DEFAULT '',
    food_class       TEXT NOT NULL DEFAULT 'mixed',-- grain|legume|dairy|meat|sweet|...
    tags             TEXT NOT NULL DEFAULT '',     -- comma separated, lowercase

    -- nutrition per 100 g / 100 ml -----------------------------------------
    calories         REAL NOT NULL DEFAULT 0,
    protein_g        REAL NOT NULL DEFAULT 0,
    carbs_g          REAL NOT NULL DEFAULT 0,
    fat_g            REAL NOT NULL DEFAULT 0,
    saturated_fat_g  REAL,
    fiber_g          REAL,
    sugar_g          REAL,
    sodium_mg        REAL,
    potassium_mg     REAL,
    calcium_mg       REAL,
    iron_mg          REAL,
    magnesium_mg     REAL,
    vitamin_a_mcg    REAL,
    vitamin_c_mg     REAL,
    vitamin_d_mcg    REAL,
    vitamin_b12_mcg  REAL,
    cholesterol_mg   REAL,

    -- images: URLs only, never bytes ---------------------------------------
    thumbnail_url    TEXT NOT NULL DEFAULT '',
    image_url        TEXT NOT NULL DEFAULT '',
    large_url        TEXT NOT NULL DEFAULT '',
    image_source     TEXT NOT NULL DEFAULT '',
    image_credit     TEXT NOT NULL DEFAULT '',
    license          TEXT NOT NULL DEFAULT '',
    license_url      TEXT NOT NULL DEFAULT '',

    -- provenance ------------------------------------------------------------
    source           TEXT NOT NULL DEFAULT '',
    source_url       TEXT NOT NULL DEFAULT '',
    confidence       REAL NOT NULL DEFAULT 0.8,
    micros_estimated INTEGER NOT NULL DEFAULT 0,
    completeness     REAL NOT NULL DEFAULT 0,
    popularity       INTEGER NOT NULL DEFAULT 0,
    last_updated     TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS food_categories (
    food_id     INTEGER NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    PRIMARY KEY (food_id, category_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS servings (
    id          INTEGER PRIMARY KEY,
    food_id     INTEGER NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
    unit        TEXT NOT NULL,
    label       TEXT NOT NULL,
    grams       REAL NOT NULL,
    is_default  INTEGER NOT NULL DEFAULT 0,
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS recipes (
    food_id       INTEGER PRIMARY KEY REFERENCES foods(id) ON DELETE CASCADE,
    ingredients   TEXT NOT NULL DEFAULT '[]',  -- JSON [str]
    steps         TEXT NOT NULL DEFAULT '[]',  -- JSON [str]
    prep_minutes  INTEGER NOT NULL DEFAULT 0,
    cook_minutes  INTEGER NOT NULL DEFAULT 0
);

-- Healthier swaps, precomputed at build time so the app never scans at runtime.
CREATE TABLE IF NOT EXISTS alternatives (
    food_id      INTEGER NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
    alt_food_id  INTEGER NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
    reason       TEXT NOT NULL DEFAULT '',
    kcal_delta   REAL NOT NULL DEFAULT 0,
    rank         INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (food_id, alt_food_id)
) WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- Full text search. Standalone (not external-content) because the searchable
-- blob mixes columns and transliterations that do not exist on `foods`.
-- rowid is kept equal to foods.id so the join is a direct rowid lookup.
-- ---------------------------------------------------------------------------
CREATE VIRTUAL TABLE IF NOT EXISTS foods_fts USING fts5(
    name,
    hindi_name,
    regional,
    synonyms,
    tags,
    brand,
    tokenize = "unicode61 remove_diacritics 2",
    prefix = "2 3 4"
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_foods_category   ON foods(category_id);
CREATE INDEX IF NOT EXISTS idx_foods_type       ON foods(food_type);
CREATE INDEX IF NOT EXISTS idx_foods_diet       ON foods(diet);
CREATE INDEX IF NOT EXISTS idx_foods_class      ON foods(food_class, calories);
CREATE INDEX IF NOT EXISTS idx_foods_calories   ON foods(calories);
CREATE INDEX IF NOT EXISTS idx_foods_protein    ON foods(protein_g DESC);
CREATE INDEX IF NOT EXISTS idx_foods_popularity ON foods(popularity DESC, id);
CREATE INDEX IF NOT EXISTS idx_foods_name_nocase ON foods(name COLLATE NOCASE);
CREATE UNIQUE INDEX IF NOT EXISTS idx_foods_barcode
    ON foods(barcode) WHERE barcode <> '';
CREATE INDEX IF NOT EXISTS idx_servings_food    ON servings(food_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_foodcat_category ON food_categories(category_id, food_id);
CREATE INDEX IF NOT EXISTS idx_alt_food         ON alternatives(food_id, rank);

-- Covering index for the "browse a category" list screen.
CREATE INDEX IF NOT EXISTS idx_foods_browse
    ON foods(category_id, popularity DESC, id, name, calories, thumbnail_url);
