import 'package:sqflite/sqflite.dart';

import '../db/user_database.dart';
import '../models/diary.dart';
import '../models/food.dart';

String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class UserRepository {
  UserRepository(this._database);

  final UserDatabase _database;

  Database get _db => _database.db;

  // ------------------------------------------------------------------ //
  // Diary
  // ------------------------------------------------------------------ //
  Future<int> addDiaryEntry(DiaryEntry entry) =>
      _db.insert('diary', entry.toRow());

  Future<void> deleteDiaryEntry(int id) =>
      _db.delete('diary', where: 'id = ?', whereArgs: [id]);

  Future<void> updateDiaryGrams(int id, double grams, DiaryEntry base) async {
    final factor = base.grams == 0 ? 0 : grams / base.grams;
    await _db.update(
      'diary',
      {
        'grams': grams,
        'calories': base.calories * factor,
        'protein_g': base.protein * factor,
        'carbs_g': base.carbs * factor,
        'fat_g': base.fat * factor,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<DiaryEntry>> diaryFor(String date) async {
    final rows = await _db.query('diary',
        where: 'date = ?', whereArgs: [date], orderBy: 'created_at ASC');
    return rows.map(DiaryEntry.fromRow).toList(growable: false);
  }

  Future<Map<String, DayTotals>> diaryTotalsRange(
      String fromDate, String toDate) async {
    final rows = await _db.rawQuery('''
      SELECT date,
             SUM(calories)  AS calories,
             SUM(protein_g) AS protein_g,
             SUM(carbs_g)   AS carbs_g,
             SUM(fat_g)     AS fat_g,
             COUNT(*)       AS n
      FROM diary
      WHERE date BETWEEN ? AND ?
      GROUP BY date
      ORDER BY date ASC
    ''', [fromDate, toDate]);
    return {
      for (final r in rows)
        r['date'] as String: DayTotals(
          calories: (r['calories'] as num?)?.toDouble() ?? 0,
          protein: (r['protein_g'] as num?)?.toDouble() ?? 0,
          carbs: (r['carbs_g'] as num?)?.toDouble() ?? 0,
          fat: (r['fat_g'] as num?)?.toDouble() ?? 0,
          entries: r['n'] as int? ?? 0,
        ),
    };
  }

  /// The foods a user logs most — powers "quick add" on the diary screen.
  Future<List<int>> frequentFoodIds({int limit = 12}) async {
    final rows = await _db.rawQuery('''
      SELECT food_id, COUNT(*) AS n FROM diary
      GROUP BY food_id ORDER BY n DESC, MAX(created_at) DESC LIMIT ?
    ''', [limit]);
    return rows.map((r) => r['food_id'] as int).toList(growable: false);
  }

  // ------------------------------------------------------------------ //
  // Favourites & history
  // ------------------------------------------------------------------ //
  Future<void> toggleFavorite(Food food) async {
    final existing = await _db.query('favorites',
        where: 'food_id = ?', whereArgs: [food.id], limit: 1);
    if (existing.isEmpty) {
      await _db.insert('favorites', {
        'food_id': food.id,
        'food_name': food.name,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await _db.delete('favorites', where: 'food_id = ?', whereArgs: [food.id]);
    }
  }

  Future<Set<int>> favoriteIds() async {
    final rows = await _db.query('favorites', columns: ['food_id']);
    return rows.map((r) => r['food_id'] as int).toSet();
  }

  Future<List<int>> favoriteIdsOrdered() async {
    final rows = await _db.query('favorites',
        columns: ['food_id'], orderBy: 'added_at DESC');
    return rows.map((r) => r['food_id'] as int).toList(growable: false);
  }

  Future<void> recordSearch(String term, int hits) async {
    final clean = term.trim();
    if (clean.length < 2) return;
    await _db.insert(
      'recent_searches',
      {
        'term': clean,
        'searched_at': DateTime.now().millisecondsSinceEpoch,
        'hits': hits,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _db.rawDelete('''
      DELETE FROM recent_searches WHERE term NOT IN (
        SELECT term FROM recent_searches ORDER BY searched_at DESC LIMIT 20
      )
    ''');
  }

  Future<List<String>> recentSearches({int limit = 10}) async {
    final rows = await _db.query('recent_searches',
        orderBy: 'searched_at DESC', limit: limit);
    return rows.map((r) => r['term'] as String).toList(growable: false);
  }

  Future<void> clearRecentSearches() => _db.delete('recent_searches');

  Future<void> recordView(Food food) => _db.insert(
        'recently_viewed',
        {
          'food_id': food.id,
          'food_name': food.name,
          'viewed_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<int>> recentlyViewedIds({int limit = 15}) async {
    final rows = await _db.query('recently_viewed',
        columns: ['food_id'], orderBy: 'viewed_at DESC', limit: limit);
    return rows.map((r) => r['food_id'] as int).toList(growable: false);
  }

  // ------------------------------------------------------------------ //
  // Water
  // ------------------------------------------------------------------ //
  Future<int> waterFor(String date) async {
    final rows = await _db.query('water',
        where: 'date = ?', whereArgs: [date], limit: 1);
    return rows.isEmpty ? 0 : rows.first['ml'] as int;
  }

  Future<int> addWater(String date, int ml) async {
    final current = await waterFor(date);
    final next = (current + ml).clamp(0, 20000);
    await _db.insert('water', {'date': date, 'ml': next},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return next;
  }

  Future<Map<String, int>> waterRange(String from, String to) async {
    final rows = await _db.query('water',
        where: 'date BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'date');
    return {for (final r in rows) r['date'] as String: r['ml'] as int};
  }

  // ------------------------------------------------------------------ //
  // Weight
  // ------------------------------------------------------------------ //
  Future<void> logWeight(WeightEntry entry) =>
      _db.insert('weight', entry.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<WeightEntry>> weightHistory({int limit = 180}) async {
    final rows = await _db.query('weight', orderBy: 'date DESC', limit: limit);
    return rows.reversed.map(WeightEntry.fromRow).toList(growable: false);
  }

  Future<WeightEntry?> latestWeight() async {
    final rows = await _db.query('weight', orderBy: 'date DESC', limit: 1);
    return rows.isEmpty ? null : WeightEntry.fromRow(rows.first);
  }

  Future<void> deleteWeight(String date) =>
      _db.delete('weight', where: 'date = ?', whereArgs: [date]);

  // ------------------------------------------------------------------ //
  // Meal plans
  // ------------------------------------------------------------------ //
  Future<int> createPlan(String name, int targetCalories) => _db.insert(
        'meal_plans',
        {
          'name': name,
          'target_calories': targetCalories,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
      );

  Future<int> planCount() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM meal_plans')) ??
      0;

  Future<List<MealPlan>> plans() async {
    final planRows = await _db.query('meal_plans', orderBy: 'created_at DESC');
    if (planRows.isEmpty) return const [];
    final mealRows = await _db.query('planned_meals', orderBy: 'day_index ASC');
    final byPlan = <int, List<PlannedMeal>>{};
    for (final row in mealRows) {
      final meal = PlannedMeal.fromRow(row);
      byPlan.putIfAbsent(meal.planId, () => []).add(meal);
    }
    return planRows
        .map((r) =>
            MealPlan.fromRow(r, meals: byPlan[r['id'] as int] ?? const []))
        .toList(growable: false);
  }

  Future<void> deletePlan(int id) =>
      _db.delete('meal_plans', where: 'id = ?', whereArgs: [id]);

  Future<void> addPlannedMeals(List<PlannedMeal> meals) async {
    final batch = _db.batch();
    for (final m in meals) {
      batch.insert('planned_meals', m.toRow());
    }
    await batch.commit(noResult: true);
  }

  Future<void> deletePlannedMeal(int id) =>
      _db.delete('planned_meals', where: 'id = ?', whereArgs: [id]);

  // ------------------------------------------------------------------ //
  // Rewards (rewarded-ad unlocks)
  // ------------------------------------------------------------------ //
  Future<void> grantReward(String feature, Duration duration) async {
    final expires = DateTime.now().add(duration).millisecondsSinceEpoch;
    await _db.rawInsert('''
      INSERT INTO rewards(feature, expires_at, grants) VALUES (?, ?, 1)
      ON CONFLICT(feature) DO UPDATE SET
        expires_at = MAX(excluded.expires_at, rewards.expires_at),
        grants = rewards.grants + 1
    ''', [feature, expires]);
  }

  Future<Map<String, DateTime>> activeRewards() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows =
        await _db.query('rewards', where: 'expires_at > ?', whereArgs: [now]);
    return {
      for (final r in rows)
        r['feature'] as String:
            DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int),
    };
  }

  Future<void> clearExpiredRewards() => _db.delete('rewards',
      where: 'expires_at <= ?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch]);

  Future<void> wipe() => _database.wipe();
}
