import 'dart:math' as math;

import '../data/services/preferences_service.dart';

/// Pure functions — no I/O, no Flutter. Everything here is unit-tested.
class BodyMetrics {
  const BodyMetrics._();

  /// Body Mass Index, kg/m².
  static double bmi({required double weightKg, required double heightCm}) {
    if (heightCm <= 0) return 0;
    final m = heightCm / 100.0;
    return weightKg / (m * m);
  }

  /// WHO categories, with the lower Asian-Indian cut-offs the ICMR recommends
  /// (overweight from 23, obese from 25) because the app's audience is Indian.
  static String bmiCategory(double bmi) {
    if (bmi <= 0) return 'Unknown';
    if (bmi < 18.5) return 'Underweight';
    if (bmi < 23) return 'Normal';
    if (bmi < 25) return 'Overweight';
    if (bmi < 30) return 'Obese I';
    return 'Obese II';
  }

  /// Healthy weight range for a height, using the 18.5–22.9 Indian band.
  static (double, double) healthyWeightRange(double heightCm) {
    final m = heightCm / 100.0;
    return (18.5 * m * m, 22.9 * m * m);
  }

  /// Mifflin-St Jeor basal metabolic rate — the modern default, more accurate
  /// than Harris-Benedict for most adults.
  static double bmr({
    required Sex sex,
    required double weightKg,
    required double heightCm,
    required int age,
  }) {
    final base = 10 * weightKg + 6.25 * heightCm - 5 * age;
    return sex == Sex.male ? base + 5 : base - 161;
  }

  /// Total daily energy expenditure.
  static double tdee({
    required double bmr,
    required ActivityLevel activity,
  }) =>
      bmr * activity.multiplier;

  /// Calorie target for a goal, floored at a safe minimum so the app never
  /// recommends a dangerous deficit.
  static int calorieTarget({
    required double tdee,
    required GoalType goal,
    required Sex sex,
  }) {
    final floor = sex == Sex.male ? 1500.0 : 1200.0;
    return math.max(floor, tdee + goal.calorieDelta).round();
  }

  /// Protein need in grams. Higher multipliers when losing weight (muscle
  /// sparing) or training hard.
  static double proteinTarget({
    required double weightKg,
    required ActivityLevel activity,
    required GoalType goal,
  }) {
    var perKg = switch (activity) {
      ActivityLevel.sedentary => 0.9,
      ActivityLevel.light => 1.1,
      ActivityLevel.moderate => 1.4,
      ActivityLevel.active => 1.7,
      ActivityLevel.athlete => 2.0,
    };
    if (goal == GoalType.lose) perKg += 0.2;
    if (goal == GoalType.gain) perKg += 0.1;
    return weightKg * perKg;
  }

  /// Water target: 35 ml/kg, plus 500 ml for active lifestyles, rounded to the
  /// nearest 100 ml.
  static int waterTargetMl({
    required double weightKg,
    required ActivityLevel activity,
  }) {
    var ml = weightKg * 35;
    if (activity.multiplier >= 1.55) ml += 500;
    return ((ml / 100).round() * 100).clamp(1200, 6000).toInt();
  }
}

class MacroSplit {
  const MacroSplit({
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.calories,
  });

  final double proteinG;
  final double carbsG;
  final double fatG;
  final int calories;

  double get proteinKcal => proteinG * 4;
  double get carbsKcal => carbsG * 4;
  double get fatKcal => fatG * 9;

  double get proteinPercent => calories == 0 ? 0 : proteinKcal / calories;
  double get carbsPercent => calories == 0 ? 0 : carbsKcal / calories;
  double get fatPercent => calories == 0 ? 0 : fatKcal / calories;

  /// Splits a calorie budget into grams. Protein is pinned to body weight
  /// first, fat gets a fixed share of the remainder, carbs take the rest —
  /// which is how a dietitian would actually build the plan.
  static MacroSplit forTarget({
    required int calories,
    required double weightKg,
    required ActivityLevel activity,
    required GoalType goal,
    double fatShare = 0.27,
  }) {
    final protein = BodyMetrics.proteinTarget(
      weightKg: weightKg,
      activity: activity,
      goal: goal,
    );
    final proteinKcal = math.min(protein * 4, calories * 0.4);
    final fatKcal = calories * fatShare;
    final carbsKcal = math.max(0.0, calories - proteinKcal - fatKcal);
    return MacroSplit(
      proteinG: proteinKcal / 4,
      carbsG: carbsKcal / 4,
      fatG: fatKcal / 9,
      calories: calories,
    );
  }

  static MacroSplit ratio({
    required int calories,
    required int proteinPct,
    required int carbsPct,
    required int fatPct,
  }) {
    final total = math.max(1, proteinPct + carbsPct + fatPct);
    return MacroSplit(
      proteinG: calories * proteinPct / total / 4,
      carbsG: calories * carbsPct / total / 4,
      fatG: calories * fatPct / total / 9,
      calories: calories,
    );
  }
}

/// Weight change projection used by the loss/gain planners.
class WeightPlan {
  const WeightPlan({
    required this.currentKg,
    required this.targetKg,
    required this.weeklyRateKg,
    required this.dailyCalories,
    required this.weeks,
    required this.projectedDate,
    required this.warning,
  });

  final double currentKg;
  final double targetKg;
  final double weeklyRateKg;
  final int dailyCalories;
  final int weeks;
  final DateTime projectedDate;
  final String warning;

  bool get isLoss => targetKg < currentKg;

  /// ~7700 kcal per kg of body fat.
  static const kcalPerKg = 7700.0;

  static WeightPlan build({
    required double currentKg,
    required double targetKg,
    required double weeklyRateKg,
    required double tdee,
    required Sex sex,
    DateTime? from,
  }) {
    final start = from ?? DateTime.now();
    final delta = targetKg - currentKg;
    final rate = weeklyRateKg.abs().clamp(0.1, 1.0);
    final direction = delta < 0 ? -1 : 1;
    final dailyDelta = direction * rate * kcalPerKg / 7.0;
    final floor = sex == Sex.male ? 1500.0 : 1200.0;
    var daily = tdee + dailyDelta;
    var warning = '';
    if (daily < floor) {
      daily = floor;
      warning =
          'Target rate would push you below a safe intake — the plan uses '
          '${floor.round()} kcal/day instead, so it will take longer.';
    }
    final achievableDaily = (daily - tdee).abs();
    final weeklyAchievable =
        achievableDaily <= 0 ? rate : achievableDaily * 7 / kcalPerKg;
    final weeks = delta.abs() < 0.05
        ? 0
        : (delta.abs() / math.max(weeklyAchievable, 0.05)).ceil();
    return WeightPlan(
      currentKg: currentKg,
      targetKg: targetKg,
      weeklyRateKg: rate,
      dailyCalories: daily.round(),
      weeks: weeks,
      projectedDate: start.add(Duration(days: weeks * 7)),
      warning: warning,
    );
  }
}
