import 'dart:convert';

/// Every nutrient the database carries, in display order.
enum Nutrient {
  calories('Calories', 'kcal', 0),
  protein('Protein', 'g', 1),
  carbs('Carbs', 'g', 1),
  fat('Fat', 'g', 1),
  saturatedFat('Saturated fat', 'g', 1),
  fiber('Fibre', 'g', 1),
  sugar('Sugar', 'g', 1),
  sodium('Sodium', 'mg', 0),
  potassium('Potassium', 'mg', 0),
  calcium('Calcium', 'mg', 0),
  iron('Iron', 'mg', 1),
  magnesium('Magnesium', 'mg', 0),
  vitaminA('Vitamin A', 'µg', 0),
  vitaminC('Vitamin C', 'mg', 1),
  vitaminD('Vitamin D', 'µg', 1),
  vitaminB12('Vitamin B12', 'µg', 1),
  cholesterol('Cholesterol', 'mg', 0);

  const Nutrient(this.label, this.unit, this.decimals);

  final String label;
  final String unit;
  final int decimals;

  String get column => switch (this) {
        Nutrient.calories => 'calories',
        Nutrient.protein => 'protein_g',
        Nutrient.carbs => 'carbs_g',
        Nutrient.fat => 'fat_g',
        Nutrient.saturatedFat => 'saturated_fat_g',
        Nutrient.fiber => 'fiber_g',
        Nutrient.sugar => 'sugar_g',
        Nutrient.sodium => 'sodium_mg',
        Nutrient.potassium => 'potassium_mg',
        Nutrient.calcium => 'calcium_mg',
        Nutrient.iron => 'iron_mg',
        Nutrient.magnesium => 'magnesium_mg',
        Nutrient.vitaminA => 'vitamin_a_mcg',
        Nutrient.vitaminC => 'vitamin_c_mg',
        Nutrient.vitaminD => 'vitamin_d_mcg',
        Nutrient.vitaminB12 => 'vitamin_b12_mcg',
        Nutrient.cholesterol => 'cholesterol_mg',
      };

  /// Indian ICMR-RDA reference intake for an adult, used for the "% of daily
  /// value" bars. Null where a single number would be misleading.
  double? get rda => switch (this) {
        Nutrient.protein => 54,
        Nutrient.carbs => 300,
        Nutrient.fat => 60,
        Nutrient.saturatedFat => 22,
        Nutrient.fiber => 30,
        Nutrient.sugar => 50,
        Nutrient.sodium => 2000,
        Nutrient.potassium => 3500,
        Nutrient.calcium => 1000,
        Nutrient.iron => 19,
        Nutrient.magnesium => 370,
        Nutrient.vitaminA => 900,
        Nutrient.vitaminC => 80,
        Nutrient.vitaminD => 15,
        Nutrient.vitaminB12 => 2.2,
        Nutrient.cholesterol => 300,
        Nutrient.calories => null,
      };

  bool get isMacro =>
      this == Nutrient.protein ||
      this == Nutrient.carbs ||
      this == Nutrient.fat;
}

class ServingSize {
  const ServingSize({
    required this.unit,
    required this.label,
    required this.grams,
    this.isDefault = false,
  });

  final String unit;
  final String label;
  final double grams;
  final bool isDefault;

  bool get isCustom => unit == 'custom';

  factory ServingSize.fromRow(Map<String, Object?> row) => ServingSize(
        unit: row['unit'] as String,
        label: row['label'] as String,
        grams: (row['grams'] as num).toDouble(),
        isDefault: (row['is_default'] as int? ?? 0) == 1,
      );

  static const grams100 = ServingSize(unit: '100g', label: '100 g', grams: 100);
}

/// A food row. Nutrition values are stored per 100 g; use [scaled] to get the
/// numbers for an actual portion.
class Food {
  Food({
    required this.id,
    required this.slug,
    required this.name,
    required this.hindiName,
    required this.categoryName,
    required this.foodType,
    required this.diet,
    required this.foodClass,
    required this.isVegan,
    required this.isJain,
    required this.description,
    required this.region,
    required this.brand,
    required this.barcode,
    required this.tags,
    required this.nutrients,
    required this.thumbnailUrl,
    required this.imageUrl,
    required this.largeUrl,
    required this.imageCredit,
    required this.license,
    required this.licenseUrl,
    required this.source,
    required this.sourceUrl,
    required this.microsEstimated,
    required this.regionalNames,
    required this.synonyms,
    this.servings = const [],
  });

  final int id;
  final String slug;
  final String name;
  final String hindiName;
  final String categoryName;
  final String foodType;
  final String diet;
  final String foodClass;
  final bool isVegan;
  final bool isJain;
  final String description;
  final String region;
  final String brand;
  final String barcode;
  final List<String> tags;
  final Map<Nutrient, double?> nutrients;
  final String thumbnailUrl;
  final String imageUrl;
  final String largeUrl;
  final String imageCredit;
  final String license;
  final String licenseUrl;
  final String source;
  final String sourceUrl;
  final bool microsEstimated;
  final Map<String, String> regionalNames;
  final List<String> synonyms;
  final List<ServingSize> servings;

  bool get isVeg => diet == 'veg' || diet == 'vegan';
  bool get isRecipe => foodType == 'recipe';
  bool get isPackaged => foodType == 'packaged';
  bool get hasImage => thumbnailUrl.isNotEmpty;

  double get calories => nutrients[Nutrient.calories] ?? 0;
  double get protein => nutrients[Nutrient.protein] ?? 0;
  double get carbs => nutrients[Nutrient.carbs] ?? 0;
  double get fat => nutrients[Nutrient.fat] ?? 0;

  String get displaySubtitle {
    if (brand.isNotEmpty) return brand;
    if (hindiName.isNotEmpty) return hindiName;
    return categoryName;
  }

  ServingSize get defaultServing => servings.firstWhere(
        (s) => s.isDefault,
        orElse: () => servings.isEmpty ? ServingSize.grams100 : servings.first,
      );

  /// Nutrient value for [grams] of this food.
  double? valueFor(Nutrient n, double grams) {
    final per100 = nutrients[n];
    if (per100 == null) return null;
    return per100 * grams / 100.0;
  }

  Map<Nutrient, double?> scaled(double grams) => {
        for (final entry in nutrients.entries)
          entry.key: entry.value == null ? null : entry.value! * grams / 100.0,
      };

  factory Food.fromRow(Map<String, Object?> row,
      {List<ServingSize> servings = const []}) {
    double? num_(String key) => (row[key] as num?)?.toDouble();
    return Food(
      id: row['id'] as int,
      slug: row['slug'] as String? ?? '',
      name: row['name'] as String? ?? '',
      hindiName: row['hindi_name'] as String? ?? '',
      categoryName: row['category_name'] as String? ?? '',
      foodType: row['food_type'] as String? ?? 'food',
      diet: row['diet'] as String? ?? 'veg',
      foodClass: row['food_class'] as String? ?? 'mixed',
      isVegan: (row['is_vegan'] as int? ?? 0) == 1,
      isJain: (row['is_jain'] as int? ?? 0) == 1,
      description: row['description'] as String? ?? '',
      region: row['region'] as String? ?? '',
      brand: row['brand'] as String? ?? '',
      barcode: row['barcode'] as String? ?? '',
      tags: (row['tags'] as String? ?? '')
          .split(',')
          .where((t) => t.isNotEmpty)
          .toList(growable: false),
      nutrients: {
        for (final n in Nutrient.values) n: num_(n.column),
      },
      thumbnailUrl: row['thumbnail_url'] as String? ?? '',
      imageUrl: row['image_url'] as String? ?? '',
      largeUrl: row['large_url'] as String? ?? '',
      imageCredit: row['image_credit'] as String? ?? '',
      license: row['license'] as String? ?? '',
      licenseUrl: row['license_url'] as String? ?? '',
      source: row['source'] as String? ?? '',
      sourceUrl: row['source_url'] as String? ?? '',
      microsEstimated: (row['micros_estimated'] as int? ?? 0) == 1,
      regionalNames: _decodeMap(row['regional_names'] as String?),
      synonyms: _decodeList(row['synonyms'] as String?),
      servings: servings,
    );
  }

  Food copyWithServings(List<ServingSize> s) => Food(
        id: id,
        slug: slug,
        name: name,
        hindiName: hindiName,
        categoryName: categoryName,
        foodType: foodType,
        diet: diet,
        foodClass: foodClass,
        isVegan: isVegan,
        isJain: isJain,
        description: description,
        region: region,
        brand: brand,
        barcode: barcode,
        tags: tags,
        nutrients: nutrients,
        thumbnailUrl: thumbnailUrl,
        imageUrl: imageUrl,
        largeUrl: largeUrl,
        imageCredit: imageCredit,
        license: license,
        licenseUrl: licenseUrl,
        source: source,
        sourceUrl: sourceUrl,
        microsEstimated: microsEstimated,
        regionalNames: regionalNames,
        synonyms: synonyms,
        servings: s,
      );

  static Map<String, String> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
    return const {};
  }

  static List<String> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => '$e').toList();
    } catch (_) {}
    return const [];
  }
}

class FoodCategory {
  const FoodCategory({
    required this.id,
    required this.slug,
    required this.name,
    required this.kind,
    required this.icon,
    required this.foodCount,
  });

  final int id;
  final String slug;
  final String name;
  final String kind;
  final String icon;
  final int foodCount;

  factory FoodCategory.fromRow(Map<String, Object?> row) => FoodCategory(
        id: row['id'] as int,
        slug: row['slug'] as String,
        name: row['name'] as String,
        kind: row['kind'] as String? ?? 'cuisine',
        icon: row['icon'] as String? ?? '🍽️',
        foodCount: row['food_count'] as int? ?? 0,
      );
}

class Recipe {
  const Recipe({
    required this.ingredients,
    required this.steps,
    required this.prepMinutes,
    required this.cookMinutes,
  });

  final List<String> ingredients;
  final List<String> steps;
  final int prepMinutes;
  final int cookMinutes;

  int get totalMinutes => prepMinutes + cookMinutes;

  factory Recipe.fromRow(Map<String, Object?> row) => Recipe(
        ingredients: Food._decodeList(row['ingredients'] as String?),
        steps: Food._decodeList(row['steps'] as String?),
        prepMinutes: row['prep_minutes'] as int? ?? 0,
        cookMinutes: row['cook_minutes'] as int? ?? 0,
      );
}

class FoodAlternative {
  const FoodAlternative({
    required this.food,
    required this.reason,
    required this.kcalDelta,
  });

  final Food food;
  final String reason;
  final double kcalDelta;
}
