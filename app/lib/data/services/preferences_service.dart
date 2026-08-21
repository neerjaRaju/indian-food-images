import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum Sex { male, female }

enum ActivityLevel {
  sedentary('Sedentary', 'Desk job, little exercise', 1.2),
  light('Lightly active', 'Light exercise 1–3 days/week', 1.375),
  moderate('Moderately active', 'Exercise 3–5 days/week', 1.55),
  active('Very active', 'Hard exercise 6–7 days/week', 1.725),
  athlete('Extra active', 'Physical job or twice-daily training', 1.9);

  const ActivityLevel(this.label, this.description, this.multiplier);

  final String label;
  final String description;
  final double multiplier;
}

enum GoalType {
  lose('Lose weight', -500),
  maintain('Maintain', 0),
  gain('Gain weight', 400);

  const GoalType(this.label, this.calorieDelta);

  final String label;
  final int calorieDelta;
}

/// Wraps SharedPreferences with typed getters. Values are cached in memory, so
/// reads from build methods are cheap.
class PreferencesService extends ChangeNotifier {
  PreferencesService(this._prefs);

  final SharedPreferences _prefs;

  static Future<PreferencesService> create() async =>
      PreferencesService(await SharedPreferences.getInstance());

  static const _kThemeMode = 'theme_mode';
  static const _kOnboarded = 'onboarded';
  static const _kSex = 'profile_sex';
  static const _kAge = 'profile_age';
  static const _kHeight = 'profile_height_cm';
  static const _kWeight = 'profile_weight_kg';
  static const _kActivity = 'profile_activity';
  static const _kGoal = 'profile_goal';
  static const _kCalorieGoal = 'calorie_goal';
  static const _kProteinGoal = 'protein_goal';
  static const _kWaterGoal = 'water_goal_ml';
  static const _kLanguage = 'search_language';
  static const _kLastUpdateCheck = 'last_update_check';
  static const _kInstalledDbDate = 'installed_db_date';
  static const _kAutoUpdate = 'auto_update_db';
  static const _kWifiOnlyImages = 'wifi_only_images';

  ThemeMode get themeMode =>
      ThemeMode.values[_prefs.getInt(_kThemeMode) ?? ThemeMode.system.index];
  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setInt(_kThemeMode, mode.index);
    notifyListeners();
  }

  bool get onboarded => _prefs.getBool(_kOnboarded) ?? false;
  Future<void> setOnboarded(bool value) async {
    await _prefs.setBool(_kOnboarded, value);
    notifyListeners();
  }

  Sex get sex => Sex.values[_prefs.getInt(_kSex) ?? 0];
  int get age => _prefs.getInt(_kAge) ?? 30;
  double get heightCm => _prefs.getDouble(_kHeight) ?? 170;
  double get weightKg => _prefs.getDouble(_kWeight) ?? 70;
  ActivityLevel get activity =>
      ActivityLevel.values[_prefs.getInt(_kActivity) ?? 1];
  GoalType get goal => GoalType.values[_prefs.getInt(_kGoal) ?? 1];

  Future<void> saveProfile({
    Sex? sex,
    int? age,
    double? heightCm,
    double? weightKg,
    ActivityLevel? activity,
    GoalType? goal,
  }) async {
    if (sex != null) await _prefs.setInt(_kSex, sex.index);
    if (age != null) await _prefs.setInt(_kAge, age);
    if (heightCm != null) await _prefs.setDouble(_kHeight, heightCm);
    if (weightKg != null) await _prefs.setDouble(_kWeight, weightKg);
    if (activity != null) await _prefs.setInt(_kActivity, activity.index);
    if (goal != null) await _prefs.setInt(_kGoal, goal.index);
    notifyListeners();
  }

  int get calorieGoal => _prefs.getInt(_kCalorieGoal) ?? 2000;
  Future<void> setCalorieGoal(int value) async {
    await _prefs.setInt(_kCalorieGoal, value.clamp(800, 6000));
    notifyListeners();
  }

  int get proteinGoal => _prefs.getInt(_kProteinGoal) ?? 60;
  Future<void> setProteinGoal(int value) async {
    await _prefs.setInt(_kProteinGoal, value.clamp(20, 400));
    notifyListeners();
  }

  int get waterGoalMl => _prefs.getInt(_kWaterGoal) ?? 2500;
  Future<void> setWaterGoal(int value) async {
    await _prefs.setInt(_kWaterGoal, value.clamp(500, 8000));
    notifyListeners();
  }

  /// 'auto' | 'en' | 'hi' — controls which name the food tiles lead with.
  String get searchLanguage => _prefs.getString(_kLanguage) ?? 'auto';
  Future<void> setSearchLanguage(String value) async {
    await _prefs.setString(_kLanguage, value);
    notifyListeners();
  }

  bool get autoUpdateDatabase => _prefs.getBool(_kAutoUpdate) ?? true;
  Future<void> setAutoUpdateDatabase(bool value) async {
    await _prefs.setBool(_kAutoUpdate, value);
    notifyListeners();
  }

  bool get wifiOnlyImages => _prefs.getBool(_kWifiOnlyImages) ?? false;
  Future<void> setWifiOnlyImages(bool value) async {
    await _prefs.setBool(_kWifiOnlyImages, value);
    notifyListeners();
  }

  DateTime? get lastUpdateCheck {
    final v = _prefs.getInt(_kLastUpdateCheck);
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<void> markUpdateChecked() =>
      _prefs.setInt(_kLastUpdateCheck, DateTime.now().millisecondsSinceEpoch);

  String get installedDbDate => _prefs.getString(_kInstalledDbDate) ?? '';
  Future<void> setInstalledDbDate(String value) =>
      _prefs.setString(_kInstalledDbDate, value);
}
