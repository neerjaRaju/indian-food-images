import 'package:sqflite/sqflite.dart';

import '../db/food_database.dart';
import '../models/food.dart';

/// Filters the search screen can apply on top of a text query.
class FoodFilter {
  const FoodFilter({
    this.categoryId,
    this.diet,
    this.foodType,
    this.maxCalories,
    this.minProtein,
    this.veganOnly = false,
    this.jainOnly = false,
    this.withImageOnly = false,
    this.sort = FoodSort.relevance,
  });

  final int? categoryId;
  final String? diet;
  final String? foodType;
  final double? maxCalories;
  final double? minProtein;
  final bool veganOnly;
  final bool jainOnly;
  final bool withImageOnly;
  final FoodSort sort;

  bool get isEmpty =>
      categoryId == null &&
      diet == null &&
      foodType == null &&
      maxCalories == null &&
      minProtein == null &&
      !veganOnly &&
      !jainOnly &&
      !withImageOnly;

  /// Advanced filters (calorie ceiling / protein floor) are the premium ones.
  bool get usesAdvanced => maxCalories != null || minProtein != null;

  FoodFilter copyWith({
    int? categoryId,
    String? diet,
    String? foodType,
    double? maxCalories,
    double? minProtein,
    bool? veganOnly,
    bool? jainOnly,
    bool? withImageOnly,
    FoodSort? sort,
    bool clearCategory = false,
    bool clearDiet = false,
    bool clearType = false,
    bool clearCalories = false,
    bool clearProtein = false,
  }) =>
      FoodFilter(
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        diet: clearDiet ? null : (diet ?? this.diet),
        foodType: clearType ? null : (foodType ?? this.foodType),
        maxCalories: clearCalories ? null : (maxCalories ?? this.maxCalories),
        minProtein: clearProtein ? null : (minProtein ?? this.minProtein),
        veganOnly: veganOnly ?? this.veganOnly,
        jainOnly: jainOnly ?? this.jainOnly,
        withImageOnly: withImageOnly ?? this.withImageOnly,
        sort: sort ?? this.sort,
      );
}

enum FoodSort {
  relevance('Best match'),
  caloriesAsc('Lowest calories'),
  caloriesDesc('Highest calories'),
  proteinDesc('Most protein'),
  nameAsc('A–Z');

  const FoodSort(this.label);

  final String label;
}

const _foodColumns = '''
  f.id, f.slug, f.name, f.hindi_name, f.regional_names, f.synonyms,
  f.description, f.food_type, f.diet, f.food_class, f.is_vegan, f.is_jain,
  f.barcode, f.brand, f.restaurant, f.region, f.tags,
  f.calories, f.protein_g, f.carbs_g, f.fat_g, f.saturated_fat_g, f.fiber_g,
  f.sugar_g, f.sodium_mg, f.potassium_mg, f.calcium_mg, f.iron_mg,
  f.magnesium_mg, f.vitamin_a_mcg, f.vitamin_c_mg, f.vitamin_d_mcg,
  f.vitamin_b12_mcg, f.cholesterol_mg,
  f.thumbnail_url, f.image_url, f.large_url, f.image_source, f.image_credit,
  f.license, f.license_url, f.source, f.source_url, f.micros_estimated,
  f.popularity, c.name AS category_name
''';

class FoodRepository {
  FoodRepository(this._database);

  final FoodDatabase _database;

  Database get _db => _database.db;

  // ------------------------------------------------------------------ //
  // Search
  // ------------------------------------------------------------------ //

  /// Turns raw user input into a safe FTS5 MATCH expression.
  ///
  /// Every token is double-quoted (which neutralises FTS operators such as
  /// `NEAR`, `*`, `-` and unbalanced quotes) and the final token gets a prefix
  /// star so results appear while the user is still typing.
  static String? buildMatchExpression(String input) {
    final tokens = input
        .toLowerCase()
        // \p{M} keeps Devanagari matras attached: without it "दाल" would be
        // split into "द" and "ल" and never match.
        .split(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;
    final quoted = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final safe = tokens[i].replaceAll('"', '');
      if (safe.isEmpty) continue;
      final isLast = i == tokens.length - 1;
      quoted.add(isLast && safe.length >= 2 ? '"$safe"*' : '"$safe"');
    }
    if (quoted.isEmpty) return null;
    return quoted.join(' AND ');
  }

  Future<List<Food>> search(
    String query, {
    FoodFilter filter = const FoodFilter(),
    int limit = 60,
    int offset = 0,
  }) async {
    final match = buildMatchExpression(query);
    if (match == null) {
      return browse(filter: filter, limit: limit, offset: offset);
    }
    final where = <String>[];
    final args = <Object?>[match];
    _applyFilter(filter, where, args);

    final orderBy = switch (filter.sort) {
      FoodSort.relevance =>
        'bm25(foods_fts, 10.0, 8.0, 6.0, 4.0, 1.0, 3.0) - (f.popularity / 20.0)',
      FoodSort.caloriesAsc => 'f.calories ASC',
      FoodSort.caloriesDesc => 'f.calories DESC',
      FoodSort.proteinDesc => 'f.protein_g DESC',
      FoodSort.nameAsc => 'f.name COLLATE NOCASE ASC',
    };

    final sql = '''
      SELECT $_foodColumns
      FROM foods_fts
      JOIN foods f ON f.id = foods_fts.rowid
      JOIN categories c ON c.id = f.category_id
      WHERE foods_fts MATCH ?
      ${where.isEmpty ? '' : 'AND ${where.join(' AND ')}'}
      ORDER BY $orderBy
      LIMIT ? OFFSET ?
    ''';
    final rows = await _db.rawQuery(sql, [...args, limit, offset]);
    return rows.map(Food.fromRow).toList(growable: false);
  }

  Future<List<Food>> browse({
    FoodFilter filter = const FoodFilter(),
    int limit = 60,
    int offset = 0,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    _applyFilter(filter, where, args);
    final orderBy = switch (filter.sort) {
      FoodSort.relevance => 'f.popularity DESC, f.name COLLATE NOCASE ASC',
      FoodSort.caloriesAsc => 'f.calories ASC',
      FoodSort.caloriesDesc => 'f.calories DESC',
      FoodSort.proteinDesc => 'f.protein_g DESC',
      FoodSort.nameAsc => 'f.name COLLATE NOCASE ASC',
    };
    final sql = '''
      SELECT $_foodColumns
      FROM foods f
      JOIN categories c ON c.id = f.category_id
      ${filter.categoryId != null ? 'JOIN food_categories fc ON fc.food_id = f.id' : ''}
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY $orderBy
      LIMIT ? OFFSET ?
    ''';
    final rows = await _db.rawQuery(sql, [...args, limit, offset]);
    return rows.map(Food.fromRow).toList(growable: false);
  }

  void _applyFilter(FoodFilter filter, List<String> where, List<Object?> args) {
    if (filter.categoryId != null) {
      where.add('fc.category_id = ?');
      args.add(filter.categoryId);
    }
    if (filter.diet != null) {
      where.add('f.diet = ?');
      args.add(filter.diet);
    }
    if (filter.foodType != null) {
      where.add('f.food_type = ?');
      args.add(filter.foodType);
    }
    if (filter.veganOnly) where.add('f.is_vegan = 1');
    if (filter.jainOnly) where.add('f.is_jain = 1');
    if (filter.withImageOnly) where.add("f.thumbnail_url <> ''");
    if (filter.maxCalories != null) {
      where.add('f.calories <= ?');
      args.add(filter.maxCalories);
    }
    if (filter.minProtein != null) {
      where.add('f.protein_g >= ?');
      args.add(filter.minProtein);
    }
  }

  /// Fast suggestion list for the search-as-you-type dropdown.
  Future<List<String>> suggest(String query, {int limit = 8}) async {
    final match = buildMatchExpression(query);
    if (match == null) return const [];
    final rows = await _db.rawQuery('''
      SELECT f.name
      FROM foods_fts
      JOIN foods f ON f.id = foods_fts.rowid
      WHERE foods_fts MATCH ?
      ORDER BY f.popularity DESC, length(f.name) ASC
      LIMIT ?
    ''', [match, limit]);
    return rows.map((r) => r['name'] as String).toList(growable: false);
  }

  // ------------------------------------------------------------------ //
  // Single food
  // ------------------------------------------------------------------ //
  Future<Food?> byId(int id) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.id = ?
    ''', [id]);
    if (rows.isEmpty) return null;
    return Food.fromRow(rows.first, servings: await servingsFor(id));
  }

  Future<Food?> bySlug(String slug) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.slug = ?
    ''', [slug]);
    if (rows.isEmpty) return null;
    final food = Food.fromRow(rows.first);
    return food.copyWithServings(await servingsFor(food.id));
  }

  Future<Food?> byBarcode(String barcode) async {
    final clean = barcode.trim();
    if (clean.isEmpty) return null;
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.barcode = ?
      LIMIT 1
    ''', [clean]);
    if (rows.isEmpty) return null;
    final food = Food.fromRow(rows.first);
    return food.copyWithServings(await servingsFor(food.id));
  }

  Future<List<Food>> byIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.id IN ($placeholders)
    ''', ids);
    final byId = {for (final r in rows) r['id'] as int: Food.fromRow(r)};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<List<ServingSize>> servingsFor(int foodId) async {
    final rows = await _db.query(
      'servings',
      where: 'food_id = ?',
      whereArgs: [foodId],
      orderBy: 'sort_order ASC',
    );
    if (rows.isEmpty) return const [ServingSize.grams100];
    return rows.map(ServingSize.fromRow).toList(growable: false);
  }

  Future<Recipe?> recipeFor(int foodId) async {
    final rows = await _db.query('recipes',
        where: 'food_id = ?', whereArgs: [foodId], limit: 1);
    if (rows.isEmpty) return null;
    return Recipe.fromRow(rows.first);
  }

  Future<List<FoodAlternative>> alternativesFor(int foodId,
      {int limit = 4}) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns, a.reason AS reason, a.kcal_delta AS kcal_delta
      FROM alternatives a
      JOIN foods f ON f.id = a.alt_food_id
      JOIN categories c ON c.id = f.category_id
      WHERE a.food_id = ?
      ORDER BY a.rank ASC
      LIMIT ?
    ''', [foodId, limit]);
    return rows
        .map((r) => FoodAlternative(
              food: Food.fromRow(r),
              reason: r['reason'] as String? ?? '',
              kcalDelta: (r['kcal_delta'] as num?)?.toDouble() ?? 0,
            ))
        .toList(growable: false);
  }

  // ------------------------------------------------------------------ //
  // Browse helpers
  // ------------------------------------------------------------------ //
  Future<List<FoodCategory>> categories({String? kind}) async {
    final rows = await _db.query(
      'categories',
      where: kind == null ? 'food_count > 0' : 'kind = ? AND food_count > 0',
      whereArgs: kind == null ? null : [kind],
      orderBy: 'sort_order ASC',
    );
    return rows.map(FoodCategory.fromRow).toList(growable: false);
  }

  Future<List<Food>> popular({int limit = 20}) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.popularity > 0
      ORDER BY f.popularity DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(Food.fromRow).toList(growable: false);
  }

  Future<List<Food>> highProtein(
      {double minProtein = 10, int limit = 20}) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.protein_g >= ? AND f.food_type <> 'packaged'
      ORDER BY f.protein_g DESC, f.popularity DESC
      LIMIT ?
    ''', [minProtein, limit]);
    return rows.map(Food.fromRow).toList(growable: false);
  }

  Future<List<Food>> lowCalorie(
      {double maxCalories = 120, int limit = 20}) async {
    final rows = await _db.rawQuery('''
      SELECT $_foodColumns
      FROM foods f JOIN categories c ON c.id = f.category_id
      WHERE f.calories <= ? AND f.calories > 0
      ORDER BY f.popularity DESC, f.calories ASC
      LIMIT ?
    ''', [maxCalories, limit]);
    return rows.map(Food.fromRow).toList(growable: false);
  }

  Future<int> countMatching(FoodFilter filter) async {
    final where = <String>[];
    final args = <Object?>[];
    _applyFilter(filter, where, args);
    final sql = '''
      SELECT COUNT(*) FROM foods f
      ${filter.categoryId != null ? 'JOIN food_categories fc ON fc.food_id = f.id' : ''}
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
    ''';
    return Sqflite.firstIntValue(await _db.rawQuery(sql, args)) ?? 0;
  }

  Future<Map<String, String>> databaseMeta() => _database.meta();
}
