import 'package:flutter_test/flutter_test.dart';
import 'package:indian_food_calories/data/models/diary.dart';
import 'package:indian_food_calories/data/models/food.dart';
import 'package:indian_food_calories/data/repositories/food_repository.dart';

Food _sampleFood({double calories = 200}) => Food.fromRow(
      {
        'id': 1,
        'slug': 'test_food',
        'name': 'Test Food',
        'hindi_name': 'टेस्ट',
        'regional_names': '{"tamil":"சோதனை"}',
        'synonyms': '["alias one","alias two"]',
        'description': 'A dish used in tests.',
        'category_name': 'North Indian',
        'food_type': 'food',
        'diet': 'veg',
        'food_class': 'grain',
        'is_vegan': 0,
        'is_jain': 1,
        'barcode': '',
        'brand': '',
        'restaurant': '',
        'region': 'North India',
        'tags': 'staple,everyday',
        'calories': calories,
        'protein_g': 10.0,
        'carbs_g': 30.0,
        'fat_g': 5.0,
        'saturated_fat_g': null,
        'fiber_g': 4.0,
        'sugar_g': 2.0,
        'sodium_mg': 300.0,
        'potassium_mg': null,
        'calcium_mg': null,
        'iron_mg': null,
        'magnesium_mg': null,
        'vitamin_a_mcg': null,
        'vitamin_c_mg': null,
        'vitamin_d_mcg': null,
        'vitamin_b12_mcg': null,
        'cholesterol_mg': null,
        'thumbnail_url': '',
        'image_url': '',
        'large_url': '',
        'image_source': '',
        'image_credit': '',
        'license': '',
        'license_url': '',
        'source': 'test',
        'source_url': '',
        'micros_estimated': 1,
      },
      servings: const [
        ServingSize(unit: '100g', label: '100 g', grams: 100),
        ServingSize(unit: 'roti', label: '1 roti', grams: 40, isDefault: true),
        ServingSize(unit: 'custom', label: 'Custom grams', grams: 1),
      ],
    );

void main() {
  group('Food', () {
    test('parses JSON columns', () {
      final food = _sampleFood();
      expect(food.regionalNames['tamil'], 'சோதனை');
      expect(food.synonyms, ['alias one', 'alias two']);
      expect(food.tags, ['staple', 'everyday']);
      expect(food.isJain, isTrue);
      expect(food.isVeg, isTrue);
      expect(food.microsEstimated, isTrue);
    });

    test('scales nutrients by grams and keeps nulls null', () {
      final food = _sampleFood();
      expect(food.valueFor(Nutrient.calories, 40), closeTo(80, 0.001));
      expect(food.valueFor(Nutrient.protein, 250), closeTo(25, 0.001));
      expect(food.valueFor(Nutrient.calcium, 100), isNull);

      final scaled = food.scaled(50);
      expect(scaled[Nutrient.carbs], closeTo(15, 0.001));
      expect(scaled[Nutrient.vitaminC], isNull);
    });

    test('default serving falls back sensibly', () {
      expect(_sampleFood().defaultServing.unit, 'roti');
      final noServings = _sampleFood().copyWithServings(const []);
      expect(noServings.defaultServing.grams, 100);
    });

    test('malformed JSON does not throw', () {
      final row = <String, Object?>{
        'id': 2,
        'name': 'Broken',
        'regional_names': 'not json',
        'synonyms': '{oops',
        'calories': 100.0,
      };
      final food = Food.fromRow(row);
      expect(food.regionalNames, isEmpty);
      expect(food.synonyms, isEmpty);
    });
  });

  group('FTS match expression', () {
    test('quotes tokens and prefixes the last one', () {
      expect(
        FoodRepository.buildMatchExpression('paneer butter'),
        '"paneer" AND "butter"*',
      );
    });

    test('neutralises FTS operators and stray quotes', () {
      final expr = FoodRepository.buildMatchExpression('dal" OR NEAR(a b) *');
      expect(expr, isNotNull);
      expect(expr, isNot(contains('OR "')));
      // Everything is quoted, so no bare operator survives.
      expect(expr!.split(' AND ').every((t) => t.startsWith('"')), isTrue);
    });

    test('keeps Devanagari tokens', () {
      final expr = FoodRepository.buildMatchExpression('दाल');
      expect(expr, '"दाल"*');
    });

    test('returns null for punctuation-only input', () {
      expect(FoodRepository.buildMatchExpression('   '), isNull);
      expect(FoodRepository.buildMatchExpression('!!! ???'), isNull);
    });

    test('single short token is not prefixed', () {
      expect(FoodRepository.buildMatchExpression('a'), '"a"');
    });
  });

  group('Diary', () {
    test('DiaryEntry.fromFood scales macros to the portion', () {
      final entry = DiaryEntry.fromFood(
        _sampleFood(calories: 300),
        date: '2026-01-01',
        slot: MealSlot.lunch,
        grams: 200,
        servingLabel: '2 × 1 roti',
      );
      expect(entry.calories, closeTo(600, 0.01));
      expect(entry.protein, closeTo(20, 0.01));
      expect(entry.slot, MealSlot.lunch);
    });

    test('DayTotals sums entries', () {
      final food = _sampleFood();
      final entries = [
        DiaryEntry.fromFood(food,
            date: '2026-01-01',
            slot: MealSlot.breakfast,
            grams: 100,
            servingLabel: '100 g'),
        DiaryEntry.fromFood(food,
            date: '2026-01-01',
            slot: MealSlot.dinner,
            grams: 50,
            servingLabel: '50 g'),
      ];
      final totals = DayTotals.of(entries);
      expect(totals.entries, 2);
      expect(totals.calories, closeTo(300, 0.01));
      expect(totals.protein, closeTo(15, 0.01));
    });

    test('meal slot follows the clock', () {
      expect(MealSlot.forHour(8), MealSlot.breakfast);
      expect(MealSlot.forHour(13), MealSlot.lunch);
      expect(MealSlot.forHour(17), MealSlot.snack);
      expect(MealSlot.forHour(21), MealSlot.dinner);
    });

    test('unknown slot names degrade to snack', () {
      expect(MealSlot.fromName('brunch'), MealSlot.snack);
    });
  });
}
