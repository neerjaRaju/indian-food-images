import 'package:flutter_test/flutter_test.dart';
import 'package:indian_food_calories/data/services/preferences_service.dart';
import 'package:indian_food_calories/domain/calculators.dart';

void main() {
  group('BMI', () {
    test('computes kg/m²', () {
      expect(
        BodyMetrics.bmi(weightKg: 70, heightCm: 175),
        closeTo(22.86, 0.01),
      );
    });

    test('returns 0 rather than dividing by zero', () {
      expect(BodyMetrics.bmi(weightKg: 70, heightCm: 0), 0);
    });

    test('uses the lower Indian overweight cut-off of 23', () {
      expect(BodyMetrics.bmiCategory(22.9), 'Normal');
      expect(BodyMetrics.bmiCategory(23.1), 'Overweight');
      expect(BodyMetrics.bmiCategory(25.1), 'Obese I');
      expect(BodyMetrics.bmiCategory(18.4), 'Underweight');
    });

    test('healthy weight range brackets the normal band', () {
      final (lo, hi) = BodyMetrics.healthyWeightRange(170);
      expect(lo, closeTo(53.5, 0.5));
      expect(hi, closeTo(66.2, 0.5));
      expect(
          BodyMetrics.bmiCategory(BodyMetrics.bmi(weightKg: lo, heightCm: 170)),
          'Normal');
      expect(
          BodyMetrics.bmiCategory(BodyMetrics.bmi(weightKg: hi, heightCm: 170)),
          'Normal');
    });
  });

  group('BMR / TDEE', () {
    test('Mifflin-St Jeor for a male', () {
      // 10*80 + 6.25*180 - 5*30 + 5 = 1780
      expect(
        BodyMetrics.bmr(sex: Sex.male, weightKg: 80, heightCm: 180, age: 30),
        closeTo(1780, 0.5),
      );
    });

    test('Mifflin-St Jeor for a female', () {
      // 10*60 + 6.25*165 - 5*30 - 161 = 1320.25
      expect(
        BodyMetrics.bmr(sex: Sex.female, weightKg: 60, heightCm: 165, age: 30),
        closeTo(1320.25, 0.5),
      );
    });

    test('activity multiplier scales TDEE', () {
      const bmr = 1500.0;
      expect(
        BodyMetrics.tdee(bmr: bmr, activity: ActivityLevel.sedentary),
        closeTo(1800, 0.1),
      );
      expect(
        BodyMetrics.tdee(bmr: bmr, activity: ActivityLevel.athlete),
        closeTo(2850, 0.1),
      );
    });

    test('calorie target never drops below a safe floor', () {
      final target = BodyMetrics.calorieTarget(
        tdee: 1400,
        goal: GoalType.lose,
        sex: Sex.female,
      );
      expect(target, 1200, reason: '1400 - 500 would be unsafe');

      final male = BodyMetrics.calorieTarget(
        tdee: 1600,
        goal: GoalType.lose,
        sex: Sex.male,
      );
      expect(male, 1500);
    });
  });

  group('protein and water targets', () {
    test('protein rises with activity and with a fat-loss goal', () {
      final sedentary = BodyMetrics.proteinTarget(
        weightKg: 70,
        activity: ActivityLevel.sedentary,
        goal: GoalType.maintain,
      );
      final athleteCutting = BodyMetrics.proteinTarget(
        weightKg: 70,
        activity: ActivityLevel.athlete,
        goal: GoalType.lose,
      );
      expect(sedentary, closeTo(63, 0.1));
      expect(athleteCutting, greaterThan(sedentary));
      expect(athleteCutting, closeTo(154, 0.1));
    });

    test('water target rounds to 100 ml and adds for high activity', () {
      expect(
        BodyMetrics.waterTargetMl(
            weightKg: 70, activity: ActivityLevel.sedentary),
        2500,
      );
      expect(
        BodyMetrics.waterTargetMl(weightKg: 70, activity: ActivityLevel.active),
        3000,
      );
    });
  });

  group('MacroSplit', () {
    test('grams reconstruct the calorie budget', () {
      final split = MacroSplit.forTarget(
        calories: 2000,
        weightKg: 70,
        activity: ActivityLevel.moderate,
        goal: GoalType.maintain,
      );
      final kcal = split.proteinKcal + split.carbsKcal + split.fatKcal;
      expect(kcal, closeTo(2000, 1));
    });

    test('protein is capped at 40 % of calories', () {
      final split = MacroSplit.forTarget(
        calories: 1200,
        weightKg: 120,
        activity: ActivityLevel.athlete,
        goal: GoalType.lose,
      );
      expect(split.proteinPercent, lessThanOrEqualTo(0.401));
    });

    test('ratio split normalises percentages that do not sum to 100', () {
      final split = MacroSplit.ratio(
        calories: 2000,
        proteinPct: 30,
        carbsPct: 30,
        fatPct: 30,
      );
      final kcal = split.proteinKcal + split.carbsKcal + split.fatKcal;
      expect(kcal, closeTo(2000, 1));
    });
  });

  group('WeightPlan', () {
    test('projects a realistic timeline for a deficit', () {
      final plan = WeightPlan.build(
        currentKg: 80,
        targetKg: 75,
        weeklyRateKg: 0.5,
        tdee: 2400,
        sex: Sex.male,
        from: DateTime(2026, 1, 1),
      );
      expect(plan.isLoss, isTrue);
      expect(plan.dailyCalories, closeTo(2400 - 550, 2));
      expect(plan.weeks, 10);
      expect(plan.projectedDate, DateTime(2026, 3, 12));
      expect(plan.warning, isEmpty);
    });

    test('clamps to the safe floor and warns when the rate is too aggressive',
        () {
      final plan = WeightPlan.build(
        currentKg: 60,
        targetKg: 55,
        weeklyRateKg: 1.0,
        tdee: 1600,
        sex: Sex.female,
      );
      expect(plan.dailyCalories, 1200);
      expect(plan.warning, isNotEmpty);
      // Slower than the requested rate, so it must take longer than 5 weeks.
      expect(plan.weeks, greaterThan(5));
    });

    test('handles a gain goal', () {
      final plan = WeightPlan.build(
        currentKg: 55,
        targetKg: 60,
        weeklyRateKg: 0.25,
        tdee: 2200,
        sex: Sex.male,
      );
      expect(plan.isLoss, isFalse);
      expect(plan.dailyCalories, greaterThan(2200));
      expect(plan.weeks, 20);
    });

    test('already-at-target produces a zero-week plan', () {
      final plan = WeightPlan.build(
        currentKg: 70,
        targetKg: 70,
        weeklyRateKg: 0.5,
        tdee: 2000,
        sex: Sex.male,
      );
      expect(plan.weeks, 0);
    });
  });
}
