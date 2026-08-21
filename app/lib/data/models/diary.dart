import 'food.dart';

enum MealSlot {
  breakfast('Breakfast', '🌅'),
  lunch('Lunch', '🍛'),
  snack('Snack', '🥨'),
  dinner('Dinner', '🌙');

  const MealSlot(this.label, this.emoji);

  final String label;
  final String emoji;

  static MealSlot fromName(String value) => MealSlot.values
      .firstWhere((m) => m.name == value, orElse: () => MealSlot.snack);

  /// Slot suggested for the current time of day.
  static MealSlot forHour(int hour) {
    if (hour < 11) return MealSlot.breakfast;
    if (hour < 16) return MealSlot.lunch;
    if (hour < 19) return MealSlot.snack;
    return MealSlot.dinner;
  }
}

class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.date,
    required this.slot,
    required this.foodId,
    required this.foodName,
    required this.grams,
    required this.servingLabel,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.thumbnailUrl,
    required this.createdAt,
  });

  final int id;
  final String date; // yyyy-MM-dd
  final MealSlot slot;
  final int foodId;
  final String foodName;
  final double grams;
  final String servingLabel;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final String thumbnailUrl;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
        if (id > 0) 'id': id,
        'date': date,
        'slot': slot.name,
        'food_id': foodId,
        'food_name': foodName,
        'grams': grams,
        'serving_label': servingLabel,
        'calories': calories,
        'protein_g': protein,
        'carbs_g': carbs,
        'fat_g': fat,
        'thumbnail_url': thumbnailUrl,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory DiaryEntry.fromRow(Map<String, Object?> row) => DiaryEntry(
        id: row['id'] as int,
        date: row['date'] as String,
        slot: MealSlot.fromName(row['slot'] as String? ?? 'snack'),
        foodId: row['food_id'] as int? ?? 0,
        foodName: row['food_name'] as String? ?? '',
        grams: (row['grams'] as num?)?.toDouble() ?? 0,
        servingLabel: row['serving_label'] as String? ?? '',
        calories: (row['calories'] as num?)?.toDouble() ?? 0,
        protein: (row['protein_g'] as num?)?.toDouble() ?? 0,
        carbs: (row['carbs_g'] as num?)?.toDouble() ?? 0,
        fat: (row['fat_g'] as num?)?.toDouble() ?? 0,
        thumbnailUrl: row['thumbnail_url'] as String? ?? '',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int? ?? 0),
      );

  factory DiaryEntry.fromFood(
    Food food, {
    required String date,
    required MealSlot slot,
    required double grams,
    required String servingLabel,
  }) =>
      DiaryEntry(
        id: 0,
        date: date,
        slot: slot,
        foodId: food.id,
        foodName: food.name,
        grams: grams,
        servingLabel: servingLabel,
        calories: food.valueFor(Nutrient.calories, grams) ?? 0,
        protein: food.valueFor(Nutrient.protein, grams) ?? 0,
        carbs: food.valueFor(Nutrient.carbs, grams) ?? 0,
        fat: food.valueFor(Nutrient.fat, grams) ?? 0,
        thumbnailUrl: food.thumbnailUrl,
        createdAt: DateTime.now(),
      );
}

class DayTotals {
  const DayTotals({
    this.calories = 0,
    this.protein = 0,
    this.carbs = 0,
    this.fat = 0,
    this.entries = 0,
  });

  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final int entries;

  DayTotals operator +(DiaryEntry e) => DayTotals(
        calories: calories + e.calories,
        protein: protein + e.protein,
        carbs: carbs + e.carbs,
        fat: fat + e.fat,
        entries: entries + 1,
      );

  static DayTotals of(Iterable<DiaryEntry> entries) =>
      entries.fold(const DayTotals(), (acc, e) => acc + e);
}

class WeightEntry {
  const WeightEntry({required this.date, required this.kg, this.note = ''});

  final String date;
  final double kg;
  final String note;

  Map<String, Object?> toRow() => {'date': date, 'kg': kg, 'note': note};

  factory WeightEntry.fromRow(Map<String, Object?> row) => WeightEntry(
        date: row['date'] as String,
        kg: (row['kg'] as num).toDouble(),
        note: row['note'] as String? ?? '',
      );
}

class WaterLog {
  const WaterLog({required this.date, required this.ml, required this.goalMl});

  final String date;
  final int ml;
  final int goalMl;

  double get progress => goalMl <= 0 ? 0 : (ml / goalMl).clamp(0.0, 1.0);

  factory WaterLog.fromRow(Map<String, Object?> row, int goal) => WaterLog(
        date: row['date'] as String,
        ml: row['ml'] as int? ?? 0,
        goalMl: goal,
      );
}

class PlannedMeal {
  const PlannedMeal({
    required this.id,
    required this.planId,
    required this.dayIndex,
    required this.slot,
    required this.foodId,
    required this.foodName,
    required this.grams,
    required this.calories,
  });

  final int id;
  final int planId;
  final int dayIndex; // 0..6
  final MealSlot slot;
  final int foodId;
  final String foodName;
  final double grams;
  final double calories;

  Map<String, Object?> toRow() => {
        if (id > 0) 'id': id,
        'plan_id': planId,
        'day_index': dayIndex,
        'slot': slot.name,
        'food_id': foodId,
        'food_name': foodName,
        'grams': grams,
        'calories': calories,
      };

  factory PlannedMeal.fromRow(Map<String, Object?> row) => PlannedMeal(
        id: row['id'] as int,
        planId: row['plan_id'] as int,
        dayIndex: row['day_index'] as int,
        slot: MealSlot.fromName(row['slot'] as String? ?? 'lunch'),
        foodId: row['food_id'] as int? ?? 0,
        foodName: row['food_name'] as String? ?? '',
        grams: (row['grams'] as num?)?.toDouble() ?? 0,
        calories: (row['calories'] as num?)?.toDouble() ?? 0,
      );
}

class MealPlan {
  const MealPlan({
    required this.id,
    required this.name,
    required this.targetCalories,
    required this.createdAt,
    this.meals = const [],
  });

  final int id;
  final String name;
  final int targetCalories;
  final DateTime createdAt;
  final List<PlannedMeal> meals;

  factory MealPlan.fromRow(Map<String, Object?> row,
          {List<PlannedMeal> meals = const []}) =>
      MealPlan(
        id: row['id'] as int,
        name: row['name'] as String? ?? 'Plan',
        targetCalories: row['target_calories'] as int? ?? 2000,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int? ?? 0),
        meals: meals,
      );
}
